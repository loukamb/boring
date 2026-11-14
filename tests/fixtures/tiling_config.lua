-- Tiling layout with every default plugin, for smoke tests.
monitor.new({ name = "*", layout = { mode = "tiling", gaps = { inner = 6, outer = 6, smart = false } } })
input.keyboard.new({ name = "*", shortcuts = { ["Alt+Return"] = actions.execute("foot") } })
plugin("@boring/layout-tiling"):mount()
plugin("@boring/borders"):mount({ colors = { normal = "#737373", focused = "#f59e0b" } })
plugin("@boring/wallpaper"):mount({ ["*"] = "#1e293b" })
plugin("@boring/xwayland"):mount()
run_once(actions.execute("xeyes"))
