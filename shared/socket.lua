-- Unix stream sockets, for the ipc plugin and its client (clients/ipc.lua).
--
--   local fd = socket.listen(path)        -- 0600, stale socket replaced
--   local client = socket.accept(fd)      -- non-blocking, nil if none
--   local fd = socket.connect(path)
--   socket.write_all(fd, data); local data = socket.read_all(fd)

local bit = require("bit")
local ffi = require("ffi")
require("shared.ffi.libc")

local C = ffi.C

local socket = {}

-- glibc declares the address arguments as transparent unions, which LuaJIT
-- can't pass; the ABI is a plain pointer.
local c_bind = ffi.cast("int (*)(int, const void *, uint32_t)", C.bind)
local c_connect = ffi.cast("int (*)(int, const void *, uint32_t)", C.connect)
local c_accept4 = ffi.cast("int (*)(int, void *, void *, int)", C.accept4)

local function address(path)
    local addr = ffi.new("struct sockaddr_un")
    if #path >= ffi.sizeof(addr.sun_path) then return nil end
    addr.sun_family = C.AF_UNIX
    ffi.copy(addr.sun_path, path)
    return addr, ffi.sizeof(addr)
end

local function errstr()
    return "errno " .. ffi.errno()
end

--- The default socket path for a Wayland display.
function socket.path(display)
    local dir = os.getenv("XDG_RUNTIME_DIR")
    display = display or os.getenv("WAYLAND_DISPLAY")
    if not dir or not display then return nil end
    return dir .. "/boring-" .. display
end

--- Listen on `path` (mode 0600). Returns the fd (non-blocking) or nil, err.
function socket.listen(path)
    local addr, len = address(path)
    if not addr then return nil, "path too long" end
    local fd = C.socket(C.AF_UNIX, C.SOCK_STREAM + C.SOCK_CLOEXEC + C.SOCK_NONBLOCK, 0)
    if fd < 0 then return nil, errstr() end
    C.unlink(path)
    if c_bind(fd, addr, len) < 0 or C.chmod(path, tonumber("600", 8)) < 0 or C.listen(fd, 16) < 0 then
        local err = errstr()
        C.close(fd)
        return nil, err
    end
    return fd
end

--- A pending connection (non-blocking), or nil.
function socket.accept(fd)
    local client = c_accept4(fd, nil, nil, C.SOCK_CLOEXEC + C.SOCK_NONBLOCK)
    if client < 0 then return nil end
    return client
end

--- Connect to `path`. Returns a blocking fd or nil, err.
function socket.connect(path)
    local addr, len = address(path)
    if not addr then return nil, "path too long" end
    local fd = C.socket(C.AF_UNIX, C.SOCK_STREAM + C.SOCK_CLOEXEC, 0)
    if fd < 0 then return nil, errstr() end
    if c_connect(fd, addr, len) < 0 then
        local err = errstr()
        C.close(fd)
        return nil, err
    end
    return fd
end

--- Make an fd blocking again.
function socket.set_blocking(fd)
    local flags = C.fcntl(fd, C.F_GETFL)
    C.fcntl(fd, C.F_SETFL, ffi.cast("int", bit.band(flags, bit.bnot(C.O_NONBLOCK))))
end

local buf = ffi.new("char[65536]")

--- Read what's available into `chunks`. Returns "eof", "again" or "error".
function socket.read_some(fd, chunks)
    while true do
        local n = tonumber(C.read(fd, buf, 65536))
        if n > 0 then
            chunks[#chunks + 1] = ffi.string(buf, n)
        elseif n == 0 then
            return "eof"
        else
            local e = ffi.errno()
            if e == C.EAGAIN then return "again" end
            if e ~= C.EINTR then return "error" end
        end
    end
end

--- Read until the other end closes (blocking fd).
function socket.read_all(fd)
    local chunks = {}
    socket.read_some(fd, chunks)
    return table.concat(chunks)
end

--- Write everything (blocking fd). Returns true, or nil if the peer went away.
function socket.write_all(fd, data)
    local p, left = ffi.cast("const char *", data), #data
    while left > 0 do
        local n = tonumber(C.write(fd, p, left))
        if n < 0 then
            if ffi.errno() ~= C.EINTR then return nil end
        else
            p, left = p + n, left - n
        end
    end
    return true
end

function socket.shutdown_write(fd) C.shutdown(fd, C.SHUT_WR) end
function socket.close(fd) C.close(fd) end
function socket.unlink(path) C.unlink(path) end

return socket
