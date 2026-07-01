return function(t)
    local runtime = require("compositor.config.init")
    local output = require("compositor.services.output")

    t.test("monitor preferred mode clears explicit dimensions", function()
        local instance = runtime.new()
        local ok, err = runtime.execute(instance, function()
            monitor.new({ name = "HDMI-A-1", mode = "preferred", width = 1, height = 1, refresh_rate = 60 })
        end)
        t.ok(ok, err)
        local rule = instance.registry.monitors.rules[1]
        t.eq(rule.width, nil)
        t.eq(rule.height, nil)
        t.eq(rule.refresh_rate, nil)
    end)

    t.test("monitor parses well-formed modes and leaves malformed modes unset", function()
        local instance = runtime.new()
        local ok, err = runtime.execute(instance, function()
            monitor.new({ name = "DP-1", mode = "2560x1440@60", x = 1920 })
            monitor.new({ name = "DP-2", mode = "bad" })
        end)
        t.ok(ok, err)

        local dp1 = instance.registry.monitors.rules[1]
        t.eq(dp1.width, 2560)
        t.eq(dp1.height, 1440)
        t.eq(dp1.refresh_rate, 60)
        t.eq(dp1.x, 1920)

        local dp2 = instance.registry.monitors.rules[2]
        t.eq(dp2.width, nil)
        t.eq(dp2.height, nil)
        t.eq(dp2.refresh_rate, nil)
    end)

    t.test("degrees to transform handles rotation and flip", function()
        local transform = output._private.degrees_to_transform
        t.eq(transform(90, false), 1)
        t.eq(transform(270, true), 7)
        t.eq(transform(45, false), 0)
    end)
end
