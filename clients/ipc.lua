-- The ipc client: send Lua to the running compositor (plugins/ipc.lua).
--
--   ./boring.lua -e '<lua>'      run it, print what it returns
--   ./boring.lua -e -            read the code from stdin
--   ./boring.lua -i              a REPL
--
-- --socket=path picks the socket (default $XDG_RUNTIME_DIR/boring-$WAYLAND_DISPLAY).
-- Exits 1 if the code fails, 2 if the compositor can't be reached.

local socket = require("shared.socket")

local function send(path, code)
    local fd, err = socket.connect(path)
    if not fd then
        io.stderr:write(string.format("boring: can't reach %s (%s); is the ipc plugin mounted?\n", path, err))
        os.exit(2)
    end
    socket.write_all(fd, code)
    socket.shutdown_write(fd)
    local reply = socket.read_all(fd)
    socket.close(fd)
    local status, text = reply:match("^(%d)\n(.*)$")
    if not status then return false, "boring: no reply" end
    return status == "0", text
end

-- Is this chunk unfinished (more lines to come)?
local function incomplete(code)
    local fn, err = loadstring(code)
    if fn then return false end
    local ok = loadstring("return " .. code)
    return not ok and err:find("<eof>", 1, true) ~= nil
end

local function repl(path)
    local buffer = nil
    while true do
        io.stdout:write(buffer and ">> " or "boring> ")
        io.stdout:flush()
        local line = io.read("*l")
        if not line then
            io.stdout:write("\n")
            return
        end
        buffer = buffer and (buffer .. "\n" .. line) or line
        if not incomplete(buffer) then
            local ok, text = send(path, buffer)
            buffer = nil
            if text ~= "" then (ok and io.stdout or io.stderr):write(text, "\n") end
        end
    end
end

return function(mode, code, args)
    local path = args.socket or socket.path()
    if not path then
        io.stderr:write("boring: XDG_RUNTIME_DIR and WAYLAND_DISPLAY must be set (or pass --socket=)\n")
        os.exit(2)
    end
    if mode == "repl" then return repl(path) end
    if code == "-" then code = io.read("*a") end
    local ok, text = send(path, code)
    if text ~= "" then (ok and io.stdout or io.stderr):write(text, "\n") end
    os.exit(ok and 0 or 1)
end
