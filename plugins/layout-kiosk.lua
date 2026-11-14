-- plugins/layout-kiosk.lua
-- Kiosk layout: one window at a time, filling the output.
--
--   plugin("@boring/layout-kiosk"):mount()
--   monitor.new({ name = "*", layout = { mode = "kiosk" } })

local plugin = { name = "layout-kiosk" }

local kiosk = {}

local function fill(monitor, w)
    local area = monitor.output.usable
    w:set_position(area.x, area.y)
    w:set_size(area.width, area.height)
end

function kiosk:on_window_add(monitor, w)
    local current = monitor.kiosk_current
    if current and current ~= w then current:set_enabled(false) end
    monitor.kiosk_current = w
    w:set_enabled(true)
    fill(monitor, w)
end

function kiosk:on_window_remove(monitor, w)
    if monitor.kiosk_current ~= w then return end
    monitor.kiosk_current = nil
    local previous = monitor.windows[#monitor.windows]
    if previous then self:on_window_add(monitor, previous) end
end

function kiosk:on_usable_area(monitor)
    if monitor.kiosk_current then fill(monitor, monitor.kiosk_current) end
end

function kiosk:enter_fullscreen(monitor, w)
    fill(monitor, w)
    return true
end

function kiosk:exit_fullscreen(monitor)
    if monitor.kiosk_current then fill(monitor, monitor.kiosk_current) end
end

-- Claim move/resize grabs and ignore them: kiosk windows stay put.
function kiosk:begin_move() return true end
function kiosk:begin_resize() return true end

function plugin:mount(_, ctx)
    boring.layout.register("kiosk", kiosk)
    ctx.scope:defer(function() boring.layout.unregister("kiosk") end)
    return { layout = kiosk }
end

return plugin
