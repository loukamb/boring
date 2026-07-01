return function(t)
    local Scope = require("shared.scope")
    local emitter_module = require("shared.emitter")
    local wl = require("shared.wayland.server")

    t.test("scope close is idempotent and runs defers in LIFO order", function()
        local scope = Scope.new("test")
        local calls = {}

        scope:defer(function() table.insert(calls, "first") end)
        scope:defer(function() table.insert(calls, "second") end)

        scope:close()
        scope:close()

        t.eq(#calls, 2)
        t.eq(calls[1], "second")
        t.eq(calls[2], "first")
    end)

    t.test("scope subscribes and releases emitter handles", function()
        local emitter = emitter_module.new()
        local scope = Scope.new("test")
        local calls = 0

        scope:subscribe(emitter, "event", function()
            calls = calls + 1
        end)

        emitter:emit("event")
        scope:close()
        emitter:emit("event")

        t.eq(calls, 1)
    end)

    t.test("scope listen releases listener callback roots", function()
        local signal = wl._ffi.new("struct wl_signal")
        wl.list_init(signal.listener_list)

        local before = #wl._prevent_gc
        local scope = Scope.new("test")
        scope:listen(signal, function() end)
        t.ok(#wl._prevent_gc > before)

        scope:close()
        t.eq(#wl._prevent_gc, before)
    end)
end
