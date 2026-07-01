return function(t)
    local wl = require("shared.wayland.server")

    t.test("create_listener destroy releases callback roots", function()
        local before = #wl._prevent_gc
        local listeners = {}
        for i = 1, 10 do
            listeners[i] = wl.create_listener(function() end)
        end
        t.eq(#wl._prevent_gc, before + 20)
        for _, listener in ipairs(listeners) do
            wl.destroy_listener(listener)
        end
        t.eq(#wl._prevent_gc, before)
    end)
end
