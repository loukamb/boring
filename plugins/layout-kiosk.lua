-- plugins/layout-kiosk.lua
-- Kiosk layout: one window at a time, filling the usable area.
--
--   plugin("@boring/layout-kiosk"):mount({
--       outputs = { "HDMI-A-1" },   -- default: every output
--   })

local spaces = require("@boring/library/spaces")

local plugin = { name = "layout-kiosk" }

local kiosk = {}

local function fill(space, w)
    local area = space.output.usable
    local g = w:geometry()
    w:set_position(area.x - g.x, area.y - g.y)
    w:set_size(area.width, area.height)
end

local function show(space, w)
    local current = space.data.current
    if current and current ~= w then current:set_enabled(false) end
    space.data.current = w
    w:set_enabled(space.shown)
    fill(space, w)
end

function kiosk:add(space, w) show(space, w) end

function kiosk:remove(space, w)
    if space.data.current ~= w then return end
    space.data.current = nil
    local arranged = spaces.arranged(space)
    local previous = arranged[#arranged]
    if previous then show(space, previous) end
end

function kiosk:arrange(space)
    if space.data.current then fill(space, space.data.current) end
end

function kiosk:shutdown(space)
    for _, w in ipairs(space.windows) do w:set_enabled(space.shown) end
end

-- Kiosk windows stay put.
function kiosk:move() end
function kiosk:resize() end

function plugin:mount(config, ctx)
    ctx.scope:defer(spaces.register("kiosk", kiosk, { outputs = config.outputs }))
    return { layout = kiosk }
end

return plugin
