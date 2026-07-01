-- Create a monitor. We use '*' to choose all monitors.
local monitor = monitor.new({
    name = "*",
    mode = "preferred",
    scale = 1,
    rotate = 0
})

-- Load screenshot plugin. This returns
-- a table of actions that can be used to
-- initialize the screenshot picker.
local screenshot = plugin("@boring/screenshot"):mount()

-- Create our keyboard input device. This will apply
-- to all keyboards.
input.keyboard.new({
    name = "*",
    ["repeat"] = {
        delay = 300,
        rate = 30
    },
    xkb = {
        layout = "us"
    },
    shortcuts = {
        -- Actions are callbacks managed by the compositor.
        -- To manually trigger an action, invoke :run(...).
        ["Mod4+Return"] = actions.execute("xeyes"),
        ["Mod4+q"] = actions.close,
        ["Mod4+Shift+q"] = actions.exit,
        ["Mod4+c"] = actions.reload,

        -- Screenshot-related binds.
        ["PrintScreen"] = screenshot.actions.area,
        ["Ctrl+PrintScreen"] = screenshot.actions.fullscreen,
        ["Alt+PrintScreen"] = screenshot.actions.window,
    }
})

-- Create our mouse input device. This will apply
-- to all mice.
input.mouse.new({
    name = "*",
    handedness = "right",

    -- Between -1 and 1. nil disables acceleration.
    acceleration = 0.5,

    -- Adjust scroll settings.
    scroll = {
        natural = false,
        speed = 10,
    }
})

-- Load xwayland.
plugin("@boring/xwayland"):mount()

-- The @boring/borders plugin adds pixel borders
-- to windows.
plugin("@boring/borders"):mount({
    colors = {
        normal = "#737373",
        focused = "#f59e0b",
        urgent = "#ef4444",
    }
})

-- The @boring/layout-stacking plugin provides
-- a very traditional stacking layout. Simple
-- server-side decorations are also rendered.
plugin("@boring/layout-stacking"):mount({
    theme = {
        -- Color of the title's text.
        title = "#0a0a0a",

        -- Color of the decoration (title bar).
        decorations = "#f59e0b",

        -- Colors of the buttons.
        button_background = "#f59e0b",
        button_foreground = "#0a0a0a",
    },

    controls = {
        { type = "title" },
        { type = "spacer" },
        {
            type = "button",
            icon = "close",
            on_click = function(surface)
                local wl = require("shared.wayland.server")
                surface:close()
            end
        },
    }
})

-- Wallpapers!
plugin("@boring/wallpaper"):mount({
    -- Keys are the monitors you want to apply wallpapers to.
    [monitor] = "#fef3c7",

    -- For an image, you can use the following.
    -- [monitor] = {
    --     image = "/path/to/wallpaper.jpg",
    --     scale = "fill",  -- fill, fit, stretch, center, tile
    -- }
})
