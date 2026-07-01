monitor.new({
    name = "*",
    mode = "preferred",
    scale = 1,
    rotate = 0,
})

input.keyboard.new({
    name = "*",
    ["repeat"] = {
        delay = 300,
        rate = 30,
    },
    xkb = {
        layout = "us",
    },
    shortcuts = {
        ["Alt+Return"] = actions.execute("xeyes"),
        ["Ctrl+Alt+Return"] = actions.execute("xeyes"),
        ["Alt+q"] = actions.close,
        ["Alt+Shift+q"] = actions.exit,
        ["Ctrl+Alt+q"] = actions.exit,
    },
})

input.mouse.new({
    name = "*",
    handedness = "right",
    acceleration = 0.5,
    scroll = {
        natural = false,
        speed = 10,
    },
})

plugin("@boring/xwayland"):mount()

plugin("@boring/borders"):mount({
    colors = {
        normal = "#737373",
        focused = "#f59e0b",
        urgent = "#ef4444",
    },
})

plugin("@boring/layout-stacking"):mount()

plugin("@boring/wallpaper"):mount({
    ["*"] = "#fef3c7",
})

run_once(actions.execute("xeyes"), "nested-wayland-demo-xeyes")
