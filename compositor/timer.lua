-- Timers on the server's event loop.
--
--   local cancel = timer.after(server, 500, function() ... end)
--
-- The callback may return a number of milliseconds to run again after that
-- delay; anything else ends the timer. Every timer goes through one C
-- callback (the timer's id is its `data` pointer), so creating timers
-- doesn't create C callbacks.

local wl = require("shared.wl")
local log = require("shared.log")

local ffi, lib, C = wl.ffi, wl.lib, wl.C

local timer = {}

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
function timer.after(server, ms, fn)
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
function timer.now()
    C.clock_gettime(C.CLOCK_MONOTONIC, ts)
    return tonumber(ts.tv_sec) * 1000 + tonumber(ts.tv_nsec) / 1e6
end

--- Cancel every timer (the server is going away).
function timer.cancel_all()
    for id in pairs(callbacks) do remove(id) end
end

return timer
