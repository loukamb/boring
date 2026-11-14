-- Watch files with inotify on the server's event loop.
--
-- The directory is watched rather than the file, because editors usually
-- save by writing a new file and renaming it over the old one.

local ffi = require("ffi")
local wl = require("shared.wl")
local log = require("shared.log")
local loop = require("compositor.loop")

local C = wl.C

local watch = {}

local EVENT_SIZE = ffi.sizeof("struct inotify_event")
local event_ptr = ffi.typeof("struct inotify_event *")

--- Call fn() when `path` is written or replaced. Returns a function that
--- stops watching. Several events from one save cause one call.
function watch.file(server, path, fn)
    local dir, name = path:match("^(.*)/([^/]+)$")
    if not dir then dir, name = ".", path end

    local fd = C.inotify_init1(C.IN_NONBLOCK + C.IN_CLOEXEC)
    if fd < 0 then
        log.warn("can't watch %s: inotify unavailable", path)
        return function() end
    end
    -- IN_ATTRIB: file sync tools (e.g. Lima's virtiofs inotify forwarding)
    -- signal host-side edits by touching the file.
    local mask = C.IN_CLOSE_WRITE + C.IN_MOVED_TO + C.IN_CREATE + C.IN_ATTRIB
    if C.inotify_add_watch(fd, dir, mask) < 0 then
        log.warn("can't watch %s", dir)
        C.close(fd)
        return function() end
    end

    local buf = ffi.new("char[4096]")
    local remove = loop.readable(server, fd, function()
        local changed = false
        while true do
            local n = tonumber(C.read(fd, buf, 4096))
            if n <= 0 then break end
            local offset = 0
            while offset < n do
                local ev = ffi.cast(event_ptr, buf + offset)
                if ev.len > 0 and ffi.string(buf + offset + EVENT_SIZE) == name then
                    changed = true
                end
                offset = offset + EVENT_SIZE + ev.len
            end
        end
        if changed then
            local ok, err = xpcall(fn, debug.traceback)
            if not ok then log.error("watch %s: %s", path, tostring(err)) end
        end
    end)

    local stopped = false
    local function stop()
        if stopped then return end
        stopped = true
        remove()
        C.close(fd)
    end
    server.scope:defer(stop)
    return stop
end

return watch
