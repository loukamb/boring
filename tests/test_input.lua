return function(t)
    local input = require("compositor.services.input")
    local private = input._private

    t.test("mouse shortcut classification uses whole tokens", function()
        t.eq(private.is_mouse_shortcut("Super+Scroll_Lock"), false)
        t.eq(private.is_mouse_shortcut("Shift+Scroll"), true)
    end)

    t.test("mouse shortcut parser returns modifier, event, and button", function()
        local mods, event, button = private.parse_mouse_shortcut("Ctrl+LeftMouseDrag")
        t.eq(mods, private.MOD_MAP.Ctrl)
        t.eq(event, "drag")
        t.eq(button, 0x110)
    end)

    t.test("lock modifiers are ignored for shortcut matching", function()
        local mods = private.normalize_modifiers(private.MOD_MAP.Mod4 + private.MOD_MAP.Mod2 + private.MOD_MAP.Caps)
        t.eq(mods, private.MOD_MAP.Mod4)
    end)

    t.test("third rapid click does not count as a second double-click", function()
        private.reset_double_click()
        t.eq(private.is_double_click(10, 10, 0x110, 1000), false)
        t.eq(private.is_double_click(10, 10, 0x110, 1100), true)
        t.eq(private.is_double_click(10, 10, 0x110, 1200), false)
    end)

    t.test("resize edge cursor names cover all directions", function()
        local edge = private.resize_edges_to_cursor_name
        t.eq(edge(0), "default")
        t.eq(edge(1), "n-resize")
        t.eq(edge(2), "s-resize")
        t.eq(edge(4), "w-resize")
        t.eq(edge(8), "e-resize")
        t.eq(edge(1 + 4), "nw-resize")
        t.eq(edge(1 + 8), "ne-resize")
        t.eq(edge(2 + 4), "sw-resize")
        t.eq(edge(2 + 8), "se-resize")
    end)
end
