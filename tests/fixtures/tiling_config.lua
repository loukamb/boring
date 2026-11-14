-- Tiling layout with workspaces and every default plugin, for smoke tests.
monitor.new({ name = "*" })
local tiling = plugin("@boring/layout-tiling"):mount({ gaps = { inner = 6, outer = 6, smart = false } })
local ws = plugin("@boring/workspaces"):mount({ count = 4 })
local shortcuts = {
    ["Alt+Return"] = actions.execute("foot"),
    ["Alt+v"] = tiling.actions.split_vertical,
    ["Alt+b"] = tiling.actions.split_horizontal,
    ["Alt+f"] = actions.fullscreen,
}
for i = 1, 4 do
    shortcuts["Alt+" .. i] = ws.actions.switch(i)
    shortcuts["Alt+Shift+" .. i] = ws.actions.send(i)
end
input.keyboard.new({ name = "*", shortcuts = shortcuts })
plugin("@boring/borders"):mount({ colors = { normal = "#737373", focused = "#f59e0b" } })
plugin("@boring/wallpaper"):mount({ ["*"] = "#1e293b" })
plugin("@boring/xwayland"):mount()
run_once(actions.execute("xeyes"))
