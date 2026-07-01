-- plugins/layout-stacking.lua
-- Traditional stacking window layout plugin
-- Windows are freely positioned and can overlap, with focus-based z-ordering

local wl = require("shared.wayland.server")
local ffi = wl._ffi
local bit = wl.bit

--------------------------------------------------------------------------------
-- Stacking Layout Implementation
--------------------------------------------------------------------------------

local stacking = {}

function stacking:init(monitor_state)
    monitor_state.stacking = {
        grabbed_surface = nil,
        grab_x = 0,
        grab_y = 0,
        grab_geobox = nil,
        resize_edges = 0,
        mode = "none", -- "none", "move", "resize"
    }
end

function stacking:shutdown(monitor_state)
    monitor_state.stacking = nil
end

--------------------------------------------------------------------------------
-- Window Lifecycle
--------------------------------------------------------------------------------

function stacking:on_window_add(monitor_state, surface)

end

function stacking:on_window_remove(monitor_state, surface)
    if monitor_state.stacking.grabbed_surface == surface then
        monitor_state.stacking.grabbed_surface = nil
        monitor_state.stacking.mode = "none"
    end
end

function stacking:on_window_resize(monitor_state, surface, width, height)
    -- No special handling needed
end

function stacking:position_window(monitor_state, surface)
    -- Stacking doesn't enforce positions - windows stay where placed
end

--------------------------------------------------------------------------------
-- Hit Testing
--------------------------------------------------------------------------------

function stacking:get_window_at(monitor_state, x, y)
    local surface_service = require("compositor.services.surface")
    local surface, _, _, _ = surface_service:surface_at(x, y)
    return surface
end

--------------------------------------------------------------------------------
-- Interactive Move
--------------------------------------------------------------------------------

function stacking:begin_move(monitor_state, surface, cursor_x, cursor_y)
    if not surface or not surface.scene_tree then
        return false
    end

    local st = monitor_state.stacking
    st.grabbed_surface = surface
    st.mode = "move"
    st.grab_x = cursor_x - surface.scene_tree.node.x
    st.grab_y = cursor_y - surface.scene_tree.node.y

    return true
end

function stacking:update_move(monitor_state, cursor_x, cursor_y)
    local st = monitor_state.stacking
    if st.mode ~= "move" or not st.grabbed_surface then
        return
    end

    local surface = st.grabbed_surface
    if not surface.scene_tree then return end

    local new_x = cursor_x - st.grab_x
    local new_y = cursor_y - st.grab_y

    wl.roots.scene_node_set_position(surface.scene_tree.node, new_x, new_y)
end

function stacking:end_move(monitor_state)
    local st = monitor_state.stacking
    st.grabbed_surface = nil
    st.mode = "none"
end

--------------------------------------------------------------------------------
-- Interactive Resize
--------------------------------------------------------------------------------

function stacking:begin_resize(monitor_state, surface, cursor_x, cursor_y, edges)
    if not surface or not surface.scene_tree or not surface.role_obj then
        return false
    end

    local st = monitor_state.stacking
    st.grabbed_surface = surface
    st.mode = "resize"
    st.resize_edges = edges

    local geo_box = surface.role_obj.base.geometry

    local border_x = surface.scene_tree.node.x + geo_box.x
    if bit.band(edges, wl.WLR_EDGE_RIGHT) ~= 0 then
        border_x = border_x + geo_box.width
    end

    local border_y = surface.scene_tree.node.y + geo_box.y
    if bit.band(edges, wl.WLR_EDGE_BOTTOM) ~= 0 then
        border_y = border_y + geo_box.height
    end

    st.grab_x = cursor_x - border_x
    st.grab_y = cursor_y - border_y

    st.grab_geobox = ffi.new("struct wlr_box")
    st.grab_geobox.x = geo_box.x + surface.scene_tree.node.x
    st.grab_geobox.y = geo_box.y + surface.scene_tree.node.y
    st.grab_geobox.width = geo_box.width
    st.grab_geobox.height = geo_box.height

    return true
end

function stacking:update_resize(monitor_state, cursor_x, cursor_y)
    local st = monitor_state.stacking
    if st.mode ~= "resize" or not st.grabbed_surface then
        return
    end

    local surface = st.grabbed_surface
    if not surface.scene_tree or not surface.role_obj then return end

    local border_x = cursor_x - st.grab_x
    local border_y = cursor_y - st.grab_y
    local new_left = st.grab_geobox.x
    local new_right = st.grab_geobox.x + st.grab_geobox.width
    local new_top = st.grab_geobox.y
    local new_bottom = st.grab_geobox.y + st.grab_geobox.height

    if bit.band(st.resize_edges, wl.WLR_EDGE_TOP) ~= 0 then
        new_top = border_y
        if new_top >= new_bottom then new_top = new_bottom - 1 end
    elseif bit.band(st.resize_edges, wl.WLR_EDGE_BOTTOM) ~= 0 then
        new_bottom = border_y
        if new_bottom <= new_top then new_bottom = new_top + 1 end
    end

    if bit.band(st.resize_edges, wl.WLR_EDGE_LEFT) ~= 0 then
        new_left = border_x
        if new_left >= new_right then new_left = new_right - 1 end
    elseif bit.band(st.resize_edges, wl.WLR_EDGE_RIGHT) ~= 0 then
        new_right = border_x
        if new_right <= new_left then new_right = new_left + 1 end
    end

    local geo_box = surface.role_obj.base.geometry
    wl.roots.scene_node_set_position(surface.scene_tree.node,
        new_left - geo_box.x, new_top - geo_box.y)

    local new_width = new_right - new_left
    local new_height = new_bottom - new_top
    surface:set_size(new_width, new_height)
end

function stacking:end_resize(monitor_state)
    local st = monitor_state.stacking
    st.grabbed_surface = nil
    st.grab_geobox = nil
    st.mode = "none"
end

--------------------------------------------------------------------------------
-- Viewport Operations (No-op for stacking)
--------------------------------------------------------------------------------

function stacking:pan(monitor_state, dx, dy) end

function stacking:zoom(monitor_state, delta, center_x, center_y) end

--------------------------------------------------------------------------------
-- Fullscreen
--------------------------------------------------------------------------------

function stacking:enter_fullscreen(monitor_state, surface)
    if not surface or not surface.scene_tree then
        return false
    end

    if monitor_state.fullscreen_surface and monitor_state.fullscreen_surface ~= surface then
        self:exit_fullscreen(monitor_state)
    end

    local surface_service = require("compositor.services.surface")
    local current_width, current_height = surface_service:get_surface_dimensions(surface)
    surface._pre_fullscreen = {
        x = surface.scene_tree.node.x,
        y = surface.scene_tree.node.y,
        width = current_width,
        height = current_height,
    }

    local output_service = require("compositor.services.output")
    local width, height = output_service:get_output_dimensions(monitor_state.output.wlr_output)

    wl.roots.scene_node_set_position(surface.scene_tree.node, 0, 0)
    surface:set_size(width, height)

    monitor_state.fullscreen_surface = surface
    return true
end

function stacking:exit_fullscreen(monitor_state)
    local surface = monitor_state.fullscreen_surface
    if not surface then
        return false
    end

    if surface._pre_fullscreen and surface.scene_tree then
        wl.roots.scene_node_set_position(surface.scene_tree.node,
            surface._pre_fullscreen.x, surface._pre_fullscreen.y)
        if surface._pre_fullscreen.width > 0 and surface._pre_fullscreen.height > 0 then
            surface:set_size(surface._pre_fullscreen.width, surface._pre_fullscreen.height)
        end
    end

    surface._pre_fullscreen = nil
    monitor_state.fullscreen_surface = nil
    return true
end

--------------------------------------------------------------------------------
-- Plugin Wrapper
--------------------------------------------------------------------------------

local plugin = {
    name = "layout-stacking",
}

function plugin:mount(config)
    local layout_service = require("compositor.services.layout")
    layout_service:register("stacking", stacking)
    return { layout = stacking }
end

function plugin:unmount()
    local layout_service = require("compositor.services.layout")
    layout_service:unregister("stacking")
end

return plugin
