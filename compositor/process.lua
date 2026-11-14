-- Child processes: fire-and-forget commands and tracked long-running ones.
--
-- Children are reaped from a SIGCHLD handler on the Wayland event loop
-- (process.setup), so launched programs never linger as zombies. libwayland
-- blocks SIGCHLD to read it from a signalfd; children reset their signal mask
-- before exec so they start with a clean one.

local ffi = require("ffi")
local log = require("shared.log")
require("shared.ffi.libc")
require("shared.ffi.server")

local C = ffi.C

local process = {}

local tracked = {} -- pid -> process record
local all = {}     -- every process record created, for stop_all

--- Current working directory (where boring.lua runs from).
function process.cwd()
    local buf = ffi.new("char[4096]")
    if C.getcwd(buf, 4096) ~= nil then
        return ffi.string(buf)
    end
    return "."
end

local empty_mask = ffi.new("sigset_t")
C.sigemptyset(empty_mask)

local function fork_exec(cmd)
    local pid = C.fork()
    if pid == 0 then
        C.sigprocmask(C.SIG_SETMASK, empty_mask, nil)
        C.setsid()
        C.execl("/bin/sh", "/bin/sh", "-c", cmd, nil)
        C._exit(127)
    end
    if pid < 0 then
        log.error("fork failed for: %s", cmd)
        return nil
    end
    return pid
end

local function shell_quote(s)
    if s:match("^[%w%-_./=:@%%+,]+$") then return s end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- Run a shell command and forget about it. Returns the pid or nil.
function process.spawn(cmd)
    return fork_exec(cmd)
end

local status = ffi.new("int[1]")

local function reap()
    while true do
        local pid = C.waitpid(-1, status, C.WNOHANG)
        if pid <= 0 then break end
        local p = tracked[pid]
        if p then
            tracked[pid] = nil
            p.pid = nil
        end
    end
end

-- Process record functions (shared, not per-record closures).
local function command(p)
    local parts
    if p.cmd then
        parts = { p.cmd }
    else
        -- A boring program, e.g. "clients.wallpaper", run from this checkout.
        parts = { "cd", shell_quote(process.cwd()), "&&", "exec", "luajit", "boring.lua", "run", p.program }
    end
    for _, a in ipairs(p.args) do parts[#parts + 1] = shell_quote(a) end
    return table.concat(parts, " ")
end

local function is_running(p)
    if p.pid == nil then return false end
    reap()
    return p.pid ~= nil
end

local function start(p)
    if is_running(p) then
        log.warn("process already running (pid %d)", p.pid)
        return false
    end
    local pid = fork_exec(command(p))
    if not pid then return false end
    p.pid = pid
    tracked[pid] = p
    return true
end

local function signal_and_wait(p, sig)
    if not is_running(p) then return true end
    local pid = p.pid
    if C.kill(pid, sig) ~= 0 then return false end
    C.waitpid(pid, status, 0)
    tracked[pid] = nil
    p.pid = nil
    return true
end

local function stop(p) return signal_and_wait(p, C.SIGTERM) end
local function kill(p) return signal_and_wait(p, C.SIGKILL) end
local function restart(p)
    stop(p)
    return start(p)
end
local function set_args(p, args) p.args = args or {} end

--- A restartable process.
---@param opts table { cmd = "shell command" } or { program = "clients.x" }, plus args = {...}
function process.new(opts)
    assert(opts.cmd or opts.program, "process.new needs cmd or program")
    local p = {
        cmd = opts.cmd,
        program = opts.program,
        args = opts.args or {},
        pid = nil,
        start = start,
        stop = stop,
        kill = kill,
        restart = restart,
        is_running = is_running,
        set_args = set_args,
    }
    all[#all + 1] = p
    return p
end

function process.stop_all()
    for _, p in ipairs(all) do
        stop(p)
    end
end

--- Reap children whenever SIGCHLD arrives on the server's event loop.
function process.setup(server)
    local lib = require("shared.wl").lib
    local handler = ffi.cast("wl_event_loop_signal_func_t", function()
        reap()
        return 0
    end)
    local source = lib.wl_event_loop_add_signal(server.event_loop, C.SIGCHLD, handler, nil)
    server.scope:defer(function()
        lib.wl_event_source_remove(source)
        handler:free()
    end)
end

return process
