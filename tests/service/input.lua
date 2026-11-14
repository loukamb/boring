return function(t)
    local shortcuts = require("compositor.shortcuts")
    local pointer = require("compositor.pointer")
    local M = shortcuts.MODIFIERS

    t.test("key shortcuts parse modifiers and any xkb keysym", function()
        local s = assert(shortcuts.parse("Mod4+Shift+Return"))
        t.eq(s.kind, "key")
        t.eq(s.mods, M.Mod4 + M.Shift)
        t.eq(s.sym, 0xff0d)
        -- Keys the old hand-written table didn't know.
        t.eq(assert(shortcuts.parse("XF86AudioRaiseVolume")).sym, 0x1008ff13)
        t.eq(assert(shortcuts.parse("PrintScreen")).sym, 0xff61)
        t.eq(assert(shortcuts.parse("Super+a")).sym, 0x61)
        t.eq(assert(shortcuts.parse("Super+A")).sym, 0x41)
    end)

    t.test("bad shortcuts report why", function()
        local s, err = shortcuts.parse("Super+NoSuchKey")
        t.eq(s, nil)
        t.ok(err:find("NoSuchKey", 1, true))
        t.eq((shortcuts.parse("Super+Shift")), nil)
        t.eq((shortcuts.parse("a+b")), nil)
    end)

    t.test("mouse shortcuts use whole tokens", function()
        t.eq(assert(shortcuts.parse("Super+Scroll_Lock")).kind, "key")
        local s = assert(shortcuts.parse("Ctrl+LeftMouseDrag"))
        t.eq(s.kind, "mouse")
        t.eq(s.mods, M.Ctrl)
        t.eq(s.event, "drag")
        t.eq(s.button, 0x110)
    end)

    t.test("lock modifiers are ignored for matching", function()
        local keys = shortcuts.compile({ ["Mod4+q"] = function() end })
        local q = 0x71
        t.ok(shortcuts.match_key(keys, M.Mod4 + M.Mod2 + M.Caps, q))
        t.eq(shortcuts.match_key(keys, M.Mod4 + M.Shift, q), nil)
    end)

    t.test("compile splits key and mouse shortcuts and collects errors", function()
        local keys, mice, errors = shortcuts.compile({
            ["Mod4+Return"] = function() end,
            ["Super+LeftMouseDrag"] = "move_window",
            ["Mod4+Bogus"] = function() end,
        })
        t.eq(#keys, 1)
        t.eq(#mice, 1)
        t.eq(#errors, 1)
    end)

    t.test("third rapid click does not count as a second double-click", function()
        local click = { time = 0, x = 0, y = 0, button = 0 }
        local is_double = pointer._private.is_double_click
        t.eq(is_double(click, 10, 10, 0x110, 1000), false)
        t.eq(is_double(click, 10, 10, 0x110, 1100), true)
        t.eq(is_double(click, 10, 10, 0x110, 1200), false)
    end)

    t.test("resize edge cursor names cover all directions", function()
        local edge = shortcuts.resize_cursor
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
