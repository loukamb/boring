-- Slow animations, for looking at them in screenshots.
local animate = require("@boring/library/animate")
plugin("@boring/layout-stacking"):mount({ controls = { { type = "title" } }, theme = {
    decorations = animate.pulse({ from = "#f59e0b", to = "#ef4444", period = 2000 }),
} })
plugin("@boring/borders"):mount({ width = 4, colors = { focused = "#22c55e" }, transition = 1000 })
plugin("@boring/animations"):mount({ open = { duration = 3000 }, close = { duration = 3000, scale = 0.6 } })
plugin("@boring/wallpaper"):mount({ ["*"] = animate.pulse({ from = "#1e293b", to = "#64748b", period = 3000 }) })
