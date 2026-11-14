return function(t)
    -- A fake `boring` with a clock we move by hand and timers we fire by hand.
    -- The library reads the global when called, so it stays for this file.
    local now, timers = 0, {}
    _G.boring = {
        now = function() return now end,
        after = function(ms, fn)
            local timer = { fn = fn }
            timers[#timers + 1] = timer
            return function() timer.fn = nil end
        end,
        log = { error = function(...) error(string.format(...)) end },
    }
    package.loaded["plugins.library.animate"] = nil
    local animate = require("plugins.library.animate")

    -- Advance time and run the frame timer (re-arming it as asked).
    local function advance(ms)
        now = now + ms
        local pending = timers
        timers = {}
        for _, timer in ipairs(pending) do
            local again = timer.fn and timer.fn()
            if type(again) == "number" then timers[#timers + 1] = timer end
        end
    end

    t.test("animate: a plain value is applied once, no frames", function()
        local seen = {}
        animate.bind(nil, 5, function(v) seen[#seen + 1] = v end)
        t.eq(#seen, 1)
        t.eq(seen[1], 5)
        t.eq(#timers, 0)
    end)

    t.test("animate: an ease runs to its end and stops", function()
        local last
        animate.bind(nil, animate.ease({ from = 0, to = 10, duration = 100, easing = "linear" }),
            function(v) last = v end)
        t.eq(last, 0)
        advance(50)
        t.eq(last, 5)
        advance(60)
        t.eq(last, 10)
        t.eq(#timers, 0) -- nothing moves: no more frames
    end)

    t.test("animate: to() blends from the current value", function()
        local last
        local b = animate.bind(nil, "#000000", function(v) last = v end)
        t.eq(last[1], 0)
        animate.to(b, "#ffffff", { duration = 100, easing = "linear" })
        advance(50)
        t.ok(math.abs(last[1] - 0.5) < 1e-9, tostring(last[1]))
        advance(60)
        t.eq(last[1], 1)
        t.eq(#timers, 0)
    end)

    t.test("animate: pulse goes there and back; run calls done", function()
        local p = animate.pulse({ from = 0, to = 1, period = 100, easing = "linear" })
        t.eq((animate.sample(p, 0)), 0)
        t.eq((animate.sample(p, 50)), 1)
        t.eq((animate.sample(p, 75)), 0.5)
        local finished = false
        animate.run(nil, animate.ease({ from = 0, to = 1, duration = 10 }), function() end,
            function() finished = true end)
        advance(20)
        t.ok(finished)
    end)
end
