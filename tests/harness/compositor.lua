local harness = {}

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_command(command)
    local pipe = io.popen(command)
    if not pipe then
        return nil, "failed to start command"
    end
    local output = pipe:read("*a")
    pipe:close()
    return output
end

local function tmpdir(prefix)
    prefix = tostring(prefix or "boring"):gsub("[^%w_.-]", "-")
    local output = read_command(string.format("mktemp -d ${TMPDIR:-/tmp}/%s.XXXXXX", prefix))
    local path = output and output:match("([^\n]+)")
    assert(path and path ~= "", "failed to create temporary directory")
    return path
end

local function normalize_status(status)
    status = tonumber(status)
    if not status then
        return nil
    end

    -- LuaJIT on POSIX commonly reports the raw wait status from system(3).
    if status > 255 and status % 256 == 0 then
        return status / 256
    end
    return status
end

function harness.run(opts)
    opts = opts or {}

    local runtime_dir = opts.runtime_dir or tmpdir("boring-runtime")
    local config = opts.config or "tests/fixtures/minimal_config.lua"
    local timeout = opts.timeout or "5s"
    local log_file = opts.log_file or (runtime_dir .. "/compositor.log")

    os.execute("chmod 700 " .. shell_quote(runtime_dir))

    local command = table.concat({
        "XDG_RUNTIME_DIR=" .. shell_quote(runtime_dir),
        "WLR_BACKENDS=headless",
        "WLR_LIBINPUT_NO_DEVICES=1",
        "BORING_TEST=1",
        "timeout " .. shell_quote(timeout),
        "luajit switch.lua compositor --config=" .. shell_quote(config),
        ">" .. shell_quote(log_file),
        "2>&1",
    }, " ")

    local status = os.execute(command)
    local log = ""
    local file = io.open(log_file, "r")
    if file then
        log = file:read("*a")
        file:close()
    end

    if not opts.keep_runtime_dir then
        os.execute("rm -rf " .. shell_quote(runtime_dir))
    end

    return {
        status = normalize_status(status),
        raw_status = status,
        log = log,
        runtime_dir = runtime_dir,
        command = command,
    }
end

--- Start a headless compositor in the background.
--- Returns a handle: { runtime_dir, env, log_file, exec(cmd) -> output, ok,
--- alive() -> bool, stop() -> log }.
function harness.start(opts)
    opts = opts or {}
    local runtime_dir = tmpdir("boring-runtime")
    os.execute("chmod 700 " .. shell_quote(runtime_dir))
    local log_file = runtime_dir .. "/compositor.log"
    local config = opts.config or "tests/fixtures/minimal_config.lua"
    if opts.copy_config then
        -- A private copy the test may edit.
        local copy = runtime_dir .. "/config.lua"
        os.execute("cp " .. shell_quote(config) .. " " .. shell_quote(copy))
        config = copy
    end
    local env = "XDG_RUNTIME_DIR=" .. shell_quote(runtime_dir) .. " WAYLAND_DISPLAY=wayland-0"

    local pid = read_command(table.concat({
        env, "WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 BORING_TEST=1",
        "luajit switch.lua compositor --config=" .. shell_quote(config),
        ">" .. shell_quote(log_file), "2>&1 & echo $!",
    }, " ")):match("%d+")

    local handle = { runtime_dir = runtime_dir, env = env, log_file = log_file, pid = pid, config = config }

    function handle.log()
        local f = io.open(log_file, "r")
        local log = f and f:read("*a") or ""
        if f then f:close() end
        return log
    end

    function handle.alive()
        return os.execute("kill -0 " .. pid .. " 2>/dev/null") == 0
    end

    --- Run a shell command as a client of this compositor.
    function handle.exec(cmd)
        local p = io.popen(env .. " sh -c " .. shell_quote(cmd) .. " 2>&1; echo \"__exit=$?\"")
        local out = p:read("*a")
        p:close()
        local body, code = out:match("^(.-)\n?__exit=(%d+)%s*$")
        return body or out, code == "0"
    end

    function handle.stop()
        os.execute("kill " .. pid .. " 2>/dev/null; sleep 0.3; kill -9 " .. pid .. " 2>/dev/null")
        local log = handle.log()
        os.execute("rm -rf " .. shell_quote(runtime_dir))
        return log
    end

    -- Wait for the socket.
    for _ = 1, 100 do
        if os.execute("test -S " .. shell_quote(runtime_dir .. "/wayland-0")) == 0 then
            os.execute("sleep 0.3")
            return handle
        end
        if not handle.alive() then break end
        os.execute("sleep 0.1")
    end
    return nil, handle.stop()
end

function harness.has_timeout()
    return os.execute("command -v timeout >/dev/null 2>&1") == 0
end

return harness
