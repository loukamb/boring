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
    local wl = require("shared.wayland.server")
    
    -- Hide previous window if any
    if monitor_state.kiosk.current_window then
        local prev = monitor_state.kiosk.current_window
        if prev.scene_tree then
            wl.roots.scene_node_set_enabled(prev.scene_tree.node, false)
        end
    end
    
    -- Show and maximize new window
    monitor_state.kiosk.current_window = surface
    self:position_window(monitor_state, surface)
end

function kiosk:on_window_remove(monitor_state, surface)
    if monitor_state.kiosk.current_window == surface then
        monitor_state.kiosk.current_window = nil
        
        -- Show the next available window
        for _, w in ipairs(monitor_state.windows) do
            if w ~= surface then
                local wl = require("shared.wayland.server")
                wl.roots.scene_node_set_enabled(w.scene_tree.node, true)
                monitor_state.kiosk.current_window = w
                self:position_window(monitor_state, w)
                break
            end
        end
    end
end

function kiosk:position_window(monitor_state, surface)
    local wl = require("shared.wayland.server")
    
    if not surface.scene_tree then return end
    
    local output = monitor_state.output
    local width = output.wlr_output.width
    local height = output.wlr_output.height
    
    -- Position at origin
    wl.roots.scene_node_set_position(surface.scene_tree.node, 0, 0)
    
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
