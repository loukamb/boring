-- The server's event loop: timers and file descriptors.
--
--   local cancel = loop.after(server, 500, function() ... end)
--   local remove = loop.readable(server, fd, function() ... end)
--
-- A timer callback may return a number of milliseconds to run again after
-- that delay; anything else ends the timer. All timers go through one C
-- callback and all fd watches through another (the id is the `data`
-- pointer), so adding either doesn't create C callbacks.

local wl = require("shared.wl")
local log = require("shared.log")

local ffi, lib, C = wl.ffi, wl.lib, wl.C

local loop = {}

local callbacks = {} -- id -> { source, fn }
local next_id = 0
local trampoline = nil

local function remove(id)
    local t = callbacks[id]
    if not t then return end
    callbacks[id] = nil
    lib.wl_event_source_remove(t.source)
end

local function dispatch(data)
    local id = tonumber(ffi.cast("intptr_t", data))
    local t = callbacks[id]
    if not t then return 0 end
    local ok, again = xpcall(t.fn, debug.traceback)
    if not ok then
        log.error("timer: %s", tostring(again))
        again = nil
    end
    if callbacks[id] ~= t then return 0 end -- cancelled from inside
    if type(again) == "number" then
        lib.wl_event_source_timer_update(t.source, math.max(1, math.floor(again)))
    else
        remove(id)
    end
    return 0
end

--- Run fn after `ms` milliseconds (0: on the next loop iteration). Returns
--- a function that cancels it. Timers end with the server.
function loop.after(server, ms, fn)
    if not trampoline then
        trampoline = ffi.cast("wl_event_loop_timer_func_t", dispatch)
    end
    next_id = next_id + 1
    local id = next_id
    local source = lib.wl_event_loop_add_timer(server.event_loop, trampoline, ffi.cast("void *", id))
    callbacks[id] = { source = source, fn = fn }
    -- A delay of 0 disarms a timer; the shortest real one is 1 ms.
    lib.wl_event_source_timer_update(source, math.max(1, math.floor(ms)))
    return function() remove(id) end
end

local ts = ffi.new("struct timespec")

--- Monotonic time in milliseconds (fractional).
function loop.now()
    C.clock_gettime(C.CLOCK_MONOTONIC, ts)
    return tonumber(ts.tv_sec) * 1000 + tonumber(ts.tv_nsec) / 1e6
end

-- File descriptors ----------------------------------------------------------

local watches = {} -- id -> { source, fn }
local fd_trampoline = nil

local function fd_dispatch(_, _, data)
    local id = tonumber(ffi.cast("intptr_t", data))
    local w = watches[id]
    if not w then return 0 end
    local ok, err = xpcall(w.fn, debug.traceback)
    if not ok then log.error("fd watch: %s", tostring(err)) end
    return 0
end

local function watch(server, fd, mask, fn)
    if not fd_trampoline then
        fd_trampoline = ffi.cast("wl_event_loop_fd_func_t", fd_dispatch)
    end
    next_id = next_id + 1
    local id = next_id
    local source = lib.wl_event_loop_add_fd(server.event_loop, fd, mask, fd_trampoline, ffi.cast("void *", id))
    watches[id] = { source = source, fn = fn }
    return function()
        local w = watches[id]
        if not w then return end
        watches[id] = nil
        lib.wl_event_source_remove(w.source)
    end
end

--- Call fn() whenever `fd` is readable (or hung up). Returns a function
--- that stops watching (it doesn't close the fd).
function loop.readable(server, fd, fn) return watch(server, fd, C.WL_EVENT_READABLE, fn) end

--- Call fn() whenever `fd` can be written to.
function loop.writable(server, fd, fn) return watch(server, fd, C.WL_EVENT_WRITABLE, fn) end

--- Remove every timer and fd watch (the server is going away).
function loop.cancel_all()
    for id in pairs(callbacks) do remove(id) end
    for id, w in pairs(watches) do
        watches[id] = nil
        lib.wl_event_source_remove(w.source)
    end
end

return loop
