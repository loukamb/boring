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
end
