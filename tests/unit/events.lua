return function(t)
    local emitter_module = require("shared.emitter")

    t.test("emitter listeners can be removed through returned handle", function()
        local emitter = emitter_module.new()
        local calls = 0
        local listener = emitter:on("event", function()
            calls = calls + 1
        end)

        emitter:emit("event")
        listener:off()
        emitter:emit("event")

        t.eq(calls, 1)
    end)

    t.test("emitter contains listener errors", function()
        local emitter = emitter_module.new()
        local log = require("shared.log")
        local old_error = log.error
        log.error = function() end
        t.cleanup(function()
            log.error = old_error
        end)

        local calls = 0

        emitter:on("event", function()
            error("boom")
        end)
        emitter:on("event", function()
            calls = calls + 1
        end)

        emitter:emit("event")
        t.eq(calls, 1)
    end)

    t.test("emitter can clear one event or all events", function()
        local emitter = emitter_module.new()
        local calls = 0
        emitter:on("a", function() calls = calls + 1 end)
        emitter:on("b", function() calls = calls + 10 end)

        emitter:clear("a")
        emitter:emit("a")
        emitter:emit("b")
        t.eq(calls, 10)

        emitter:clear()
        emitter:emit("b")
        t.eq(calls, 10)
    end)
end
