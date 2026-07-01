-- plugins/layout-kiosk.lua
-- Kiosk layout plugin - single maximized window


local kiosk = {
    name = "kiosk",
}

function kiosk:init(monitor_state)
    monitor_state.kiosk = {
        current_window = nil,
    }
end

function kiosk:shutdown(monitor_state)
    monitor_state.kiosk = nil
end

function kiosk:on_window_add(monitor_state, surface)
    -- Hide previous window if any
    if monitor_state.kiosk.current_window then
        local prev = monitor_state.kiosk.current_window
        if prev.set_enabled then
            prev:set_enabled(false)
        end
    end
    
    -- Show and maximize new window
    monitor_state.kiosk.current_window = surface
    self:position_window(monitor_state, surface)
end

function kiosk:on_window_remove(monitor_state, surface)
    if monitor_state.kiosk.current_window == surface then
        monitor_state.kiosk.current_window = nil
        
        -- Show the most recently active remaining window.
        for i = #monitor_state.windows, 1, -1 do
            local w = monitor_state.windows[i]
            if w ~= surface and w.set_enabled then
                w:set_enabled(true)
                monitor_state.kiosk.current_window = w
                self:position_window(monitor_state, w)
                break
            end
        end
    end
end

function kiosk:position_window(monitor_state, surface)
    if not surface or not surface.scene_node or not surface:scene_node() then return end
    
    local output_service = require("compositor.services.output")
    local width, height = output_service:get_output_dimensions(monitor_state.output)
    
    -- Position at origin
    surface:set_position(0, 0)
    
    -- Resize to fill
    surface:set_size(width, height)
end

function kiosk:get_window_at(monitor_state, x, y)
    return monitor_state.kiosk.current_window
end

-- No-op for kiosk (no moves)
function kiosk:begin_move() return false end
function kiosk:update_move() end
function kiosk:end_move() end

-- No-op for kiosk (no resize)
function kiosk:begin_resize() return false end
function kiosk:update_resize() end
function kiosk:end_resize() end

--------------------------------------------------------------------------------
-- Plugin wrapper
--------------------------------------------------------------------------------

local plugin = {
    name = "layout-kiosk",
}

function plugin:mount(config)
    local layout_service = require("compositor.services.layout")
    layout_service:register("kiosk", kiosk)
    return { layout = kiosk }
end

function plugin:unmount()
    local layout_service = require("compositor.services.layout")
    layout_service:unregister("kiosk")
end

return plugin
