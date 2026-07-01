return function(t)
    local runtime = require("compositor.config.init")
    local ConfigObject = require("compositor.config.object")

    t.test("run_once executes every verb in a list once", function()
        runtime.reset_run_once()

        local calls = {}
        local instance = runtime.new()
        instance.env.run_once({
            function() table.insert(calls, "a") end,
            function() table.insert(calls, "b") end,
        }, "list")

        runtime.execute_run_verbs(instance)
        t.eq(table.concat(calls, ","), "a,b")

        local second = runtime.new()
        second.env.run_once({
            function() table.insert(calls, "c") end,
            function() table.insert(calls, "d") end,
        }, "list")

        runtime.execute_run_verbs(second)
        t.eq(table.concat(calls, ","), "a,b")
    end)

    t.test("exact config rules override wildcard rules regardless of order", function()
        local rules = {
            ConfigObject.new("monitor", { name = "HDMI-A-1", wallpaper = "exact", nested = { value = "exact" } }),
            ConfigObject.new("monitor", { name = "*", wallpaper = "wildcard", nested = { other = "wildcard" } }),
        }

        local resolved = runtime.resolve_rules(rules, "HDMI-A-1")
        t.eq(resolved.wallpaper, "exact")
        t.eq(resolved.nested.value, "exact")
        t.eq(resolved.nested.other, "wildcard")
    end)
end
