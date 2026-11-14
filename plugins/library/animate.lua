-- plugins/library/animate.lua
-- Animated values. Anything that takes a value (a colour, a width, an
-- opacity) can take an animation instead, without telling them apart:
--
--   local animate = require("@boring/library/animate")
--   local glow = animate.pulse({ from = "#f59e0b", to = "#ef4444", period = 1200 })
--
--   -- In a plugin: apply(v) runs now, and every frame while it animates.
--   local b = animate.bind(scope, config.color, function(c) rect:set_color(color.float4(c)) end)
--   animate.to(b, other_value, { duration = 150 })   -- transition to something else
--
-- Animations are plain tables:
--   animate.ease({ from, to, duration = 200, easing = "out-cubic", delay = 0 })
--   animate.pulse({ from, to, period = 1000, easing = "in-out-sine" })  -- there and back, forever
--   animate.loop({ from, to, period = 1000, easing = "linear" })        -- from → to, again and again
--
-- Values are numbers, tables of numbers (colours: { r, g, b, a }) or hex
-- colour strings, which become colour tables. Frames run on a timer only
-- while something animates (`animate.fps`, default 60).

local color = require("shared.color")

local animate = {}

animate.fps = 60

--------------------------------------------------------------------------------
-- Easing
--------------------------------------------------------------------------------

local pi = math.pi
animate.easings = {
    linear = function(p) return p end,
    ["in-quad"] = function(p) return p * p end,
    ["out-quad"] = function(p) return 1 - (1 - p) * (1 - p) end,
    ["in-out-quad"] = function(p) return p < 0.5 and 2 * p * p or 1 - (-2 * p + 2) ^ 2 / 2 end,
    ["in-cubic"] = function(p) return p * p * p end,
    ["out-cubic"] = function(p) return 1 - (1 - p) ^ 3 end,
    ["in-out-cubic"] = function(p) return p < 0.5 and 4 * p * p * p or 1 - (-2 * p + 2) ^ 3 / 2 end,
    ["in-out-sine"] = function(p) return -(math.cos(pi * p) - 1) / 2 end,
    ["out-back"] = function(p)
        local c1 = 1.70158
        return 1 + (c1 + 1) * (p - 1) ^ 3 + c1 * (p - 1) ^ 2
    end,
}

local function easing(name)
    if type(name) == "function" then return name end
    return animate.easings[name or "out-cubic"] or animate.easings.linear
end

--------------------------------------------------------------------------------
-- Values
--------------------------------------------------------------------------------

--- A value ready to interpolate: hex colour strings become colour tables.
function animate.value(v)
    if type(v) == "string" and v:sub(1, 1) == "#" then return color.parse(v, v) end
    return v
end

--- Interpolate between two values (numbers or tables of numbers).
function animate.mix(a, b, t)
    if type(a) == "number" and type(b) == "number" then return a + (b - a) * t end
    if type(a) == "table" and type(b) == "table" then
        local out = {}
        for i = 1, math.max(#a, #b) do
            local x, y = a[i] or b[i], b[i] or a[i]
            out[i] = x + (y - x) * t
        end
        return out
    end
    return t < 1 and a or b
end

local function animation(kind, opts)
    return {
        animation = kind,
        from = animate.value(opts.from),
        to = animate.value(opts.to),
        duration = opts.duration or 200,
        period = opts.period or 1000,
        delay = opts.delay or 0,
        easing = opts.easing,
    }
end

function animate.ease(opts) return animation("ease", opts) end
function animate.pulse(opts)
    local a = animation("pulse", opts)
    a.easing = a.easing or "in-out-sine"
    return a
end
function animate.loop(opts)
    local a = animation("loop", opts)
    a.easing = a.easing or "linear"
    return a
end

--- Is this an animation (rather than a plain value)?
function animate.is(v)
    return type(v) == "table" and v.animation ~= nil
end

--- The value of `v` at `t` ms after it started, and whether it's done
--- changing. Plain values are done right away.
function animate.sample(v, t)
    if not animate.is(v) then return v, true end
    local kind = v.animation
    t = t - v.delay
    if kind == "ease" then
        if t <= 0 then return v.from, false end
        local p = math.min(1, t / math.max(1, v.duration))
        return animate.mix(v.from, v.to, easing(v.easing)(p)), p >= 1
    end
    local phase = (math.max(0, t) % v.period) / v.period
    if kind == "pulse" then
        phase = phase < 0.5 and phase * 2 or 2 - phase * 2
    end
    return animate.mix(v.from, v.to, easing(v.easing)(phase)), false
end

--------------------------------------------------------------------------------
-- Bindings and the frame driver
--------------------------------------------------------------------------------

local active = {}  -- binding -> true while it changes
local running = nil -- cancel function of the frame timer

local function evaluate(b, now)
    local t = now - b.started
    local v, done = animate.sample(b.target, t)
    if b.from ~= nil then
        local p = math.min(1, t / math.max(1, b.duration))
        if p < 1 then
            v = animate.mix(b.from, v, easing(b.easing)(p))
            done = false
        else
            b.from = nil
        end
    end
    return v, done
end

local function step(b, now)
    local v, done = evaluate(b, now)
    b.current = v
    local ok, err = xpcall(b.apply, debug.traceback, v)
    if not ok then
        boring.log.error("animate: %s", tostring(err))
        done = true
    end
    if done then
        active[b] = nil
        if b.done then
            local fn = b.done
            b.done = nil
            fn()
        end
    end
    return done
end

local function tick()
    local now = boring.now()
    for b in pairs(active) do step(b, now) end
    if next(active) then return 1000 / animate.fps end
    running = nil
end

local function start(b)
    active[b] = true
    if not running then running = boring.after(1000 / animate.fps, tick) end
end

--- Call apply(v) with `value` now, and every frame while it animates.
--- Returns a binding for animate.to/set/stop; the scope ends it.
function animate.bind(scope, value, apply)
    local b = { apply = apply, started = boring.now(), target = animate.value(value) }
    if not step(b, b.started) then start(b) end
    if scope then scope:defer(function() animate.stop(b) end) end
    return b
end

--- Move a binding to a new value or animation. With `opts.duration`, it
--- blends from where it is now (`opts.easing`, default out-cubic).
function animate.to(b, target, opts)
    local now = boring.now()
    if opts and opts.duration and opts.duration > 0 and b.current ~= nil then
        b.from = b.current
        b.duration = opts.duration
        b.easing = opts.easing
    else
        b.from = nil
    end
    b.target = animate.value(target)
    b.started = now
    if not step(b, now) then start(b) end
end

--- Jump to a value.
function animate.set(b, value) animate.to(b, value) end

--- Stop updating a binding (its value stays where it is).
function animate.stop(b)
    active[b] = nil
    b.done = nil
end

--- Run an animation once: apply(v) every frame, then done() when it ends.
--- Returns the binding (animate.stop cancels it, without calling done).
function animate.run(scope, value, apply, done)
    local b = { apply = apply, started = boring.now(), target = animate.value(value), done = done }
    if not step(b, b.started) then start(b) end
    if scope then scope:defer(function() animate.stop(b) end) end
    return b
end

return animate
