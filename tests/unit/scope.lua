return function(t)
    local ffi = require("ffi")
    local wl = require("shared.wl")
    local scope = wl.scope
    local listener = wl.listener
    local emitter_module = require("shared.emitter")

    local function new_signal()
        local signal = ffi.new("struct wl_signal")
        listener.signal_init(signal)
        return signal
    end

    t.test("scope close is idempotent and runs defers in LIFO order", function()
        local s = scope.new("test")
        local calls = {}

        s:defer(function() table.insert(calls, "first") end)
        s:defer(function() table.insert(calls, "second") end)

        s:close()
        s:close()

        t.eq(#calls, 2)
        t.eq(calls[1], "second")
        t.eq(calls[2], "first")
    end)

    t.test("scope subscribes and releases emitter handles", function()
        local emitter = emitter_module.new()
        local s = scope.new("test")
        local calls = 0

        s:subscribe(emitter, "event", function()
            calls = calls + 1
        end)

        emitter:emit("event")
        s:close()
        emitter:emit("event")

        t.eq(calls, 1)
    end)

    t.test("scope listen disconnects on close", function()
        local signal = new_signal()
        local before = listener.count()
        local s = scope.new("test")
        local calls = 0
        s:listen(signal, function() calls = calls + 1 end)
        t.eq(listener.count(), before + 1)

        listener.emit(signal, nil)
        s:close()
        listener.emit(signal, nil)

        t.eq(calls, 1)
        t.eq(listener.count(), before)
    end)

    t.test("child scopes close with their parent", function()
        local parent = scope.new("parent")
        local child = parent:child("child")
        local closed = false
        child:defer(function() closed = true end)
        parent:close()
        t.ok(closed)
        t.ok(child.closed)
    end)

    t.test("defer on a closed scope runs immediately", function()
        local s = scope.new("test")
        s:close()
        local ran = false
        s:defer(function() ran = true end)
        t.ok(ran)
    end)
end
