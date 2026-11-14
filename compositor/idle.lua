-- Idle: something happens when nobody has touched input for a while.
--
--   local cancel = idle.watch(server, 300000, {
--       idle = function() ... end,    -- after 5 minutes without input
--       resume = function() ... end,  -- input again
--   })
--
-- Idle inhibitors (a video playing) hold idleness off. Input only records a
-- timestamp; timers check it, so the input path stays cheap.

local loop = require("compositor.loop")
local log = require("shared.log")

local idle = {}

local function state(server)
    local s = server.idle
    if not s then
        s = { last = loop.now(), watchers = {}, idle_count = 0, inhibitors = 0 }
        server.idle = s
    end
    return s
end

local function call(fn)
    if not fn then return end
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then log.error("idle: %s", tostring(err)) end
end

local function arm(server, w, ms)
    w.cancel = loop.after(server, ms, function()
        local s = state(server)
        local remaining = s.last + w.ms - loop.now()
        if remaining > 0 then return remaining end
        if s.inhibitors > 0 then return w.ms end
        w.idle = true
        w.cancel = nil
        s.idle_count = s.idle_count + 1
        call(w.handlers.idle)
    end)
end

--- Input happened.
function idle.activity(server)
    local s = state(server)
    s.last = loop.now()
    if s.idle_count == 0 then return end
    for w in pairs(s.watchers) do
        if w.idle then
            w.idle = false
            s.idle_count = s.idle_count - 1
            call(w.handlers.resume)
            arm(server, w, w.ms)
        end
    end
end

--- Idle inhibitors appeared or went away (count is how many there are).
function idle.set_inhibitors(server, count)
    state(server).inhibitors = count
end

--- Call handlers.idle after `ms` without input, and handlers.resume when
--- input comes back. Returns a function that stops watching.
function idle.watch(server, ms, handlers)
    local s = state(server)
    local w = { ms = ms, handlers = handlers, idle = false }
    s.watchers[w] = true
    arm(server, w, ms)
    return function()
        if not s.watchers[w] then return end
        s.watchers[w] = nil
        if w.cancel then w.cancel() end
        if w.idle then s.idle_count = s.idle_count - 1 end
    end
end

return idle
