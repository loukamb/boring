-- services/surface_service.lua - The Surface Aggregator
-- Responsibility: wl_compositor, xdg_shell, scene graph, window management
-- Implements the "Upgrade" pattern for surface lifecycle

local wl = require("shared.wayland.server")
local proto = require("shared.wayland.registry")
local events_mod = require("shared.events")
local hooks_mod = require("shared.hook")
local log = require("shared.log")
local ffi = wl._ffi
local bit = wl.bit

local core_service = require("compositor.services.core")
local output_service = require("compositor.services.output")

-- Protocol enums from registry
local layer_shell_layer = proto.enum("zwlr_layer_shell_v1").layer
local layer_surface_anchor = proto.enum("zwlr_layer_surface_v1").anchor

local surface_service = {
    -- Scene graph
    scene = nil,
    scene_layout = nil,

    -- Layer trees (wlr-layer-shell standard z-ordering)
    layers = {
        background = nil,
        bottom = nil,
        windows = nil,
        top = nil,
        overlay = nil,
        unmanaged = nil, -- For override_redirect surfaces (popups, menus, etc)
    },

    -- XDG Shell
    xdg_shell = nil,

    -- Layer Shell
    layer_shell = nil,

    -- Foreign Toplevel Manager (for taskbar integration)
    foreign_toplevel_manager = nil,

    -- Fractional Scale Manager (for HiDPI support)
    fractional_scale_manager = nil,

    -- Surface registry: Maps C pointer (wl_surface) -> Lua Surface Object
    registry = {},
    layer_registry = {},

    -- Windows list: Surfaces that are currently "toplevels"
    windows = {},

    -- Scene tree registry for hit testing
    scene_tree_registry = wl.new_registry(),

    -- Listener registry for this service
    listener_registry = wl.new_registry(),

    -- Listeners
    listeners = {},

    -- State
    initialized = false,

    -- Event emitter for plugin notifications
    events = events_mod.new(),

    -- Hook system for plugin behavior overrides
    hooks = hooks_mod.new(),
}

local surface_at_sx = ffi.new("double[1]")
local surface_at_sy = ffi.new("double[1]")

local function is_null(value)
    return value == nil or value == ffi.NULL
end

local function cleanup_registered_listener(listener, current_listener)
    if not listener then
        return
    end

    local listener_ptr = ffi.cast("struct wl_listener*", listener)
    local current_ptr = current_listener and ffi.cast("struct wl_listener*", current_listener) or nil
    local is_current = current_ptr and wl.ptr_to_num(listener_ptr) == wl.ptr_to_num(current_ptr)

    if is_current then
        wl.list_remove(listener[0].link)
    else
        wl.destroy_listener(listener)
    end
    surface_service.listener_registry:remove(listener)
end

--------------------------------------------------------------------------------
-- Surface Lifecycle: The "Upgrade" Pattern
--------------------------------------------------------------------------------

-- Create a new generic surface
function surface_service:create_surface(wlr_surface)
    local ptr_key = wl.ptr_to_num(wlr_surface)

    local surface = {
        id = tostring(ptr_key),
        wlr_surface = wlr_surface,
        role = nil,     -- "toplevel", "popup", "cursor", "layer"
        role_obj = nil, -- The wlr_xdg_toplevel / wlr_layer_surface / etc

        -- State
        mapped = false,
        activated = false,

        -- Scene
        scene_tree = nil,
    }

    self.registry[ptr_key] = surface
    return surface
end

-- Upgrade a surface with a specific role
function surface_service:upgrade(wlr_surface, new_role, role_object, scene_tree)
    local ptr_key = wl.ptr_to_num(wlr_surface)
    local surface = self.registry[ptr_key]

    -- If surface doesn't exist yet, create it
    if not surface then
        surface = self:create_surface(wlr_surface)
    end

    surface.role = new_role
    surface.role_obj = role_object
    surface.scene_tree = scene_tree

    -- MIXIN: Inject role-specific methods dynamically
    if new_role == "toplevel" then
        surface.set_size = function(s, w, h)
            wl.roots.xdg_toplevel_set_size(s.role_obj, w, h)
        end
        surface.close = function(s)
            wl.roots.xdg_toplevel_send_close(s.role_obj)
        end
        surface.set_activated = function(s, activated)
            wl.roots.xdg_toplevel_set_activated(s.role_obj, activated)
            s.activated = activated
        end

        -- Store reference back to surface in scene tree for hit testing
        if scene_tree then
            self.scene_tree_registry:set(scene_tree, surface)
        end
    end

    return surface
end

-- Get a surface by its wlr_surface pointer
function surface_service:get_surface(wlr_surface)
    local ptr_key = wl.ptr_to_num(wlr_surface)
    return self.registry[ptr_key]
end

-- Remove a surface from the registry
function surface_service:remove_surface(wlr_surface)
    local ptr_key = wl.ptr_to_num(wlr_surface)
    local surface = self.registry[ptr_key]
    if surface and surface.scene_tree then
        self.scene_tree_registry:remove(surface.scene_tree)
    end
    self.registry[ptr_key] = nil
end

local function register_layer_surface(layer_data)
    local layer_surface = layer_data.layer_surface
    if is_null(layer_surface) or is_null(layer_surface.surface) then
        return
    end
    surface_service.layer_registry[wl.ptr_to_num(layer_surface.surface)] = layer_data
end

local function unregister_layer_surface(layer_data)
    local layer_surface = layer_data.layer_surface
    if is_null(layer_surface) or is_null(layer_surface.surface) then
        return
    end
    surface_service.layer_registry[wl.ptr_to_num(layer_surface.surface)] = nil
end

--------------------------------------------------------------------------------
-- Window Management
--------------------------------------------------------------------------------

-- Focus a window (surface with toplevel role)
function surface_service:focus_window(surface)
    if not surface or surface.role ~= "toplevel" then return end

    -- input_service is loaded after surface_service, require at runtime
    local input_service = require("compositor.services.input")
    local seat = input_service:get_seat()
    if not seat then return end

    local prev_surface = seat.keyboard_state.focused_surface
    local wlr_surface = surface.wlr_surface

    if prev_surface == wlr_surface then
        return -- Already focused
    end

    -- Deactivate previously focused surface
    if prev_surface ~= nil and prev_surface ~= ffi.NULL then
        local prev_toplevel = wl.roots.xdg_toplevel_try_from_wlr_surface(prev_surface)
        if prev_toplevel ~= nil and prev_toplevel ~= ffi.NULL then
            wl.roots.xdg_toplevel_set_activated(prev_toplevel, false)
        end
    end

    local keyboard = wl.roots.seat_get_keyboard(seat)

    -- Move to front in scene
    if surface.scene_tree then
        wl.roots.scene_node_raise_to_top(surface.scene_tree.node)
    end

    -- Move to front of windows list
    for i, w in ipairs(self.windows) do
        if w == surface then
            table.remove(self.windows, i)
            break
        end
    end
    table.insert(self.windows, 1, surface)

    -- Activate the new surface
    surface:set_activated(true)

    -- Have keyboard enter this surface
    if keyboard ~= nil and keyboard ~= ffi.NULL then
        wl.roots.seat_keyboard_notify_enter(seat, wlr_surface,
            keyboard.keycodes, keyboard.num_keycodes, keyboard.modifiers)
    end

    -- Emit focus events for plugins
    if prev_surface ~= nil and prev_surface ~= ffi.NULL then
        local prev = self:get_surface(prev_surface)
        if prev then
            self.events:emit("surface:blur", prev)
        end
    end
    self.events:emit("surface:focus", surface)
end

-- Cycle to next window (for Alt+F1)
function surface_service:cycle_windows()
    if #self.windows >= 2 then
        local next_window = self.windows[#self.windows]
        self:focus_window(next_window)
    end
end

-- Get the currently focused window
function surface_service:get_focused_window()
    local input_service = require("compositor.services.input")
    local seat = input_service:get_seat()
    if not seat then return nil end

    local focused_surface = seat.keyboard_state.focused_surface
    if focused_surface == nil or focused_surface == ffi.NULL then
        return nil
    end

    return self:get_surface(focused_surface)
end

-- Close the currently focused window
function surface_service:close_focused_window()
    local window = self:get_focused_window()
    if window and window.role == "toplevel" and window.close then
        window:close()
        return true
    end
    return false
end

-- Find surface at coordinates (hit testing)
function surface_service:surface_at(lx, ly)
    -- Use wlr_scene_node_at for hit testing
    -- Note: wlr_scene_node_at returns coordinates in DISPLAYED space (scaled)
    -- We must convert back to native buffer coordinates for the client

    local sx = surface_at_sx
    local sy = surface_at_sy

    local node = wl.roots.scene_node_at(self.scene.tree.node, lx, ly, sx, sy)

    if node == nil or node == ffi.NULL or node.type ~= wl.WLR_SCENE_NODE_BUFFER then
        return nil, nil, 0, 0
    end

    local scene_buffer = wl.roots.scene_buffer_from_node(node)
    local scene_surface = wl.roots.scene_surface_try_from_buffer(scene_buffer)

    if scene_surface == nil or scene_surface == ffi.NULL then
        return nil, nil, 0, 0
    end

    local wlr_surface = scene_surface.surface

    -- wlr_scene_node_at returns coordinates in buffer-local space
    -- (already transformed from output coords using dest_size)
    -- So we use the coordinates directly without additional scaling
    local final_sx = sx[0]
    local final_sy = sy[0]

    -- Find the toplevel this surface belongs to by walking up the tree
    local tree = node.parent
    while tree ~= nil and tree ~= ffi.NULL do
        local surface = self.scene_tree_registry:get(tree)
        if surface then
            return surface, wlr_surface, final_sx, final_sy
        end
        tree = tree.node.parent
    end

    return nil, wlr_surface, final_sx, final_sy
end

--------------------------------------------------------------------------------
-- XDG Toplevel Handlers
--------------------------------------------------------------------------------

-- Handle XDG toplevel map
local function xdg_toplevel_map(listener, data)
    local toplevel = surface_service.listener_registry:get(listener)
    if not toplevel then return end

    -- Get or create surface and mark as mapped
    local wlr_surface = toplevel.xdg_toplevel.base.surface
    local surface = surface_service:get_surface(wlr_surface)
    if surface then
        surface.mapped = true
        table.insert(surface_service.windows, 1, surface)

        -- Notify layout service of new window
        local layout_service = require("compositor.services.layout")
        layout_service:on_window_add(surface, nil) -- nil output = use primary

        -- Emit surface:map event for plugins (before focus so border exists)
        surface_service.events:emit("surface:map", surface)

        surface_service:focus_window(surface)

        -- Create foreign toplevel handle for taskbar integration
        if surface_service.foreign_toplevel_manager then
            local handle = wl.roots.foreign_toplevel_handle_v1_create(
                surface_service.foreign_toplevel_manager)
            if handle and handle ~= ffi.NULL then
                surface.foreign_toplevel_handle = handle
                -- Set initial title and app_id
                local title = toplevel.xdg_toplevel.title
                if title and title ~= ffi.NULL then
                    wl.roots.foreign_toplevel_handle_v1_set_title(handle, title)
                end
                local app_id = toplevel.xdg_toplevel.app_id
                if app_id and app_id ~= ffi.NULL then
                    wl.roots.foreign_toplevel_handle_v1_set_app_id(handle, app_id)
                end
            end
        end
    end
end

-- Handle XDG toplevel unmap
local function xdg_toplevel_unmap(listener, data)
    local toplevel = surface_service.listener_registry:get(listener)
    if not toplevel then return end

    local wlr_surface = toplevel.xdg_toplevel.base.surface
    local surface = surface_service:get_surface(wlr_surface)

    if surface then
        surface.mapped = false

        -- Destroy foreign toplevel handle
        if surface.foreign_toplevel_handle then
            wl.roots.foreign_toplevel_handle_v1_destroy(surface.foreign_toplevel_handle)
            surface.foreign_toplevel_handle = nil
        end

        -- Notify input_service to release grab if this was grabbed
        local input_service = require("compositor.services.input")
        input_service:on_surface_unmapped(surface)

        -- Notify layout service of window removal
        local layout_service = require("compositor.services.layout")
        layout_service:on_window_remove(surface)

        -- Emit surface:unmap event for plugins
        surface_service.events:emit("surface:unmap", surface)

        -- Remove from windows list
        for i, w in ipairs(surface_service.windows) do
            if w == surface then
                table.remove(surface_service.windows, i)
                break
            end
        end
    end
end

-- Handle XDG toplevel commit
local function xdg_toplevel_commit(listener, data)
    local toplevel = surface_service.listener_registry:get(listener)
    if not toplevel then return end

    if toplevel.xdg_toplevel.base.initial_commit then
        wl.roots.xdg_toplevel_set_size(toplevel.xdg_toplevel, 0, 0)
    else
        -- After commits (geometry may have changed), re-apply layout position
        -- This ensures tiling windows are positioned correctly after resize ack
        local wlr_surface = toplevel.xdg_toplevel.base.surface
        local surface = surface_service:get_surface(wlr_surface)
        if surface and surface.mapped and surface._monitor_state then
            local layout_service = require("compositor.services.layout")
            layout_service:position_window(surface)
        end

        -- Emit surface:commit event for plugins
        if surface then
            surface_service.events:emit("surface:commit", surface)
        end
    end
end

-- Handle XDG toplevel set_title
local function xdg_toplevel_set_title(listener, data)
    local toplevel = surface_service.listener_registry:get(listener)
    if not toplevel then return end

    local wlr_surface = toplevel.xdg_toplevel.base.surface
    local surface = surface_service:get_surface(wlr_surface)

    -- Update foreign toplevel handle
    if surface and surface.foreign_toplevel_handle then
        local title = toplevel.xdg_toplevel.title
        if title and title ~= ffi.NULL then
            wl.roots.foreign_toplevel_handle_v1_set_title(surface.foreign_toplevel_handle, title)
        end
    end
end

-- Handle XDG toplevel set_app_id
local function xdg_toplevel_set_app_id(listener, data)
    local toplevel = surface_service.listener_registry:get(listener)
    if not toplevel then return end

    local wlr_surface = toplevel.xdg_toplevel.base.surface
    local surface = surface_service:get_surface(wlr_surface)

    -- Update foreign toplevel handle
    if surface and surface.foreign_toplevel_handle then
        local app_id = toplevel.xdg_toplevel.app_id
        if app_id and app_id ~= ffi.NULL then
            wl.roots.foreign_toplevel_handle_v1_set_app_id(surface.foreign_toplevel_handle, app_id)
        end
    end
end

-- Handle XDG toplevel destruction
local function xdg_toplevel_destroy(listener, data)
    local toplevel = surface_service.listener_registry:get(listener)
    if not toplevel then return end

    -- Remove all listeners FIRST before wlroots destroys the toplevel
    cleanup_registered_listener(toplevel.map_listener, listener)
    cleanup_registered_listener(toplevel.unmap_listener, listener)
    cleanup_registered_listener(toplevel.commit_listener, listener)
    cleanup_registered_listener(toplevel.destroy_listener, listener)
    cleanup_registered_listener(toplevel.request_move_listener, listener)
    cleanup_registered_listener(toplevel.request_resize_listener, listener)
    cleanup_registered_listener(toplevel.request_maximize_listener, listener)
    cleanup_registered_listener(toplevel.request_fullscreen_listener, listener)
    cleanup_registered_listener(toplevel.set_title_listener, listener)
    cleanup_registered_listener(toplevel.set_app_id_listener, listener)
    local wlr_surface = toplevel.xdg_toplevel.base.surface
    local surface = surface_service:get_surface(wlr_surface)

    if surface then
        -- Destroy foreign toplevel handle if still present
        if surface.foreign_toplevel_handle then
            wl.roots.foreign_toplevel_handle_v1_destroy(surface.foreign_toplevel_handle)
            surface.foreign_toplevel_handle = nil
        end

        -- Remove from windows list
        for i, w in ipairs(surface_service.windows) do
            if w == surface then
                table.remove(surface_service.windows, i)
                break
            end
        end

        -- Remove from registry
        surface_service:remove_surface(wlr_surface)
    end
end

-- Handle XDG toplevel move request (CSD drag)
local function xdg_toplevel_request_move(listener, data)
    local toplevel = surface_service.listener_registry:get(listener)
    if not toplevel then return end

    local wlr_surface = toplevel.xdg_toplevel.base.surface
    local surface = surface_service:get_surface(wlr_surface)

    if surface then
        local layout_service = require("compositor.services.layout")
        local input_service = require("compositor.services.input")
        local cursor = input_service:get_cursor()

        -- Try layout service first
        if layout_service:begin_move(surface, cursor.x, cursor.y) then
            input_service.cursor_mode = 1 -- CURSOR_MOVE
            input_service.grabbed_surface = surface
            wl.roots.cursor_set_xcursor(cursor, input_service.cursor_mgr, "grabbing")
        else
            -- Fall back to direct move for stacking layout
            input_service:begin_interactive(surface, "move", 0)
        end
    end
end

-- Handle XDG toplevel resize request (CSD resize)
local function xdg_toplevel_request_resize(listener, data)
    local toplevel = surface_service.listener_registry:get(listener)
    if not toplevel then return end

    local event = ffi.cast("struct wlr_xdg_toplevel_resize_event*", data)
    local wlr_surface = toplevel.xdg_toplevel.base.surface
    local surface = surface_service:get_surface(wlr_surface)

    if surface then
        local layout_service = require("compositor.services.layout")
        local input_service = require("compositor.services.input")
        local cursor = input_service:get_cursor()

        -- Try layout service first
        if layout_service:begin_resize(surface, cursor.x, cursor.y, event.edges) then
            input_service.cursor_mode = 2 -- CURSOR_RESIZE
            input_service.grabbed_surface = surface
            input_service.resize_edges = event.edges

            wl.roots.cursor_set_xcursor(cursor, input_service.cursor_mgr,
                input_service._private.resize_edges_to_cursor_name(event.edges))
        else
            -- Fall back to direct resize for stacking layout
            input_service:begin_interactive(surface, "resize", event.edges)
        end
    end
end

-- Handle XDG toplevel maximize request
local function xdg_toplevel_request_maximize(listener, data)
    local toplevel = surface_service.listener_registry:get(listener)
    if not toplevel then return end

    if toplevel.xdg_toplevel.base.initialized then
        wl.roots.xdg_surface_schedule_configure(toplevel.xdg_toplevel.base)
    end
end

-- Handle XDG toplevel fullscreen request
local function xdg_toplevel_request_fullscreen(listener, data)
    local toplevel = surface_service.listener_registry:get(listener)
    if not toplevel then return end

    if toplevel.xdg_toplevel.base.initialized then
        wl.roots.xdg_surface_schedule_configure(toplevel.xdg_toplevel.base)
    end
end

-- Handle new XDG toplevel
local function server_new_xdg_toplevel(listener, data)
    local xdg_toplevel = ffi.cast("struct wlr_xdg_toplevel*", data)
    local wlr_surface = xdg_toplevel.base.surface


    -- Create scene tree for this toplevel in the windows layer
    local scene_tree = wl.roots.scene_xdg_surface_create(surface_service.layers.windows, xdg_toplevel.base)
    if is_null(scene_tree) then
        return
    end
    xdg_toplevel.base.data = scene_tree

    -- Upgrade the surface to a toplevel
    local surface = surface_service:upgrade(wlr_surface, "toplevel", xdg_toplevel, scene_tree)

    -- Create internal tracking object for listeners
    local toplevel = {
        xdg_toplevel = xdg_toplevel,
        surface = surface,
    }

    -- Set up listeners
    toplevel.map_listener = wl.create_listener(xdg_toplevel_map)
    surface_service.listener_registry:set(toplevel.map_listener, toplevel)
    wl.signal_add(xdg_toplevel.base.surface.events.map, toplevel.map_listener)

    toplevel.unmap_listener = wl.create_listener(xdg_toplevel_unmap)
    surface_service.listener_registry:set(toplevel.unmap_listener, toplevel)
    wl.signal_add(xdg_toplevel.base.surface.events.unmap, toplevel.unmap_listener)

    toplevel.commit_listener = wl.create_listener(xdg_toplevel_commit)
    surface_service.listener_registry:set(toplevel.commit_listener, toplevel)
    wl.signal_add(xdg_toplevel.base.surface.events.commit, toplevel.commit_listener)

    toplevel.destroy_listener = wl.create_listener(xdg_toplevel_destroy)
    surface_service.listener_registry:set(toplevel.destroy_listener, toplevel)
    wl.signal_add(xdg_toplevel.events.destroy, toplevel.destroy_listener)

    toplevel.request_move_listener = wl.create_listener(xdg_toplevel_request_move)
    surface_service.listener_registry:set(toplevel.request_move_listener, toplevel)
    wl.signal_add(xdg_toplevel.events.request_move, toplevel.request_move_listener)

    toplevel.request_resize_listener = wl.create_listener(xdg_toplevel_request_resize)
    surface_service.listener_registry:set(toplevel.request_resize_listener, toplevel)
    wl.signal_add(xdg_toplevel.events.request_resize, toplevel.request_resize_listener)

    toplevel.request_maximize_listener = wl.create_listener(xdg_toplevel_request_maximize)
    surface_service.listener_registry:set(toplevel.request_maximize_listener, toplevel)
    wl.signal_add(xdg_toplevel.events.request_maximize, toplevel.request_maximize_listener)

    toplevel.request_fullscreen_listener = wl.create_listener(xdg_toplevel_request_fullscreen)
    surface_service.listener_registry:set(toplevel.request_fullscreen_listener, toplevel)
    wl.signal_add(xdg_toplevel.events.request_fullscreen, toplevel.request_fullscreen_listener)

    -- Listen for title and app_id changes (for foreign toplevel protocol)
    toplevel.set_title_listener = wl.create_listener(xdg_toplevel_set_title)
    surface_service.listener_registry:set(toplevel.set_title_listener, toplevel)
    wl.signal_add(xdg_toplevel.events.set_title, toplevel.set_title_listener)

    toplevel.set_app_id_listener = wl.create_listener(xdg_toplevel_set_app_id)
    surface_service.listener_registry:set(toplevel.set_app_id_listener, toplevel)
    wl.signal_add(xdg_toplevel.events.set_app_id, toplevel.set_app_id_listener)
end

--------------------------------------------------------------------------------
-- XDG Popup Handlers
--------------------------------------------------------------------------------

-- Handle XDG popup commit
local function xdg_popup_commit(listener, data)
    local popup = surface_service.listener_registry:get(listener)
    if not popup then return end

    if popup.xdg_popup.base.initial_commit then
        wl.roots.xdg_surface_schedule_configure(popup.xdg_popup.base)
    end
end

-- Handle XDG popup destroy
local function xdg_popup_destroy(listener, data)
    local popup = surface_service.listener_registry:get(listener)
    if not popup then return end

    -- Remove listeners before wlroots destroys the popup
    cleanup_registered_listener(popup.commit_listener, listener)
    cleanup_registered_listener(popup.destroy_listener, listener)
end

local function get_popup_parent_tree(xdg_popup)
    local parent = wl.roots.xdg_surface_try_from_wlr_surface(xdg_popup.parent)
    if not is_null(parent) and not is_null(parent.data) then
        return ffi.cast("struct wlr_scene_tree*", parent.data)
    end

    local layer_data = surface_service.layer_registry[wl.ptr_to_num(xdg_popup.parent)]
    if layer_data and not is_null(layer_data.scene_layer) and not is_null(layer_data.scene_layer.tree) then
        return layer_data.scene_layer.tree
    end

    return nil
end

-- Handle new XDG popup
local function server_new_xdg_popup(listener, data)
    local xdg_popup = ffi.cast("struct wlr_xdg_popup*", data)

    local popup = {
        xdg_popup = xdg_popup,
    }

    local parent_tree = get_popup_parent_tree(xdg_popup)
    if is_null(parent_tree) then
        return
    end

    local popup_tree = wl.roots.scene_xdg_surface_create(parent_tree, xdg_popup.base)
    if is_null(popup_tree) then
        return
    end
    xdg_popup.base.data = popup_tree

    popup.commit_listener = wl.create_listener(xdg_popup_commit)
    surface_service.listener_registry:set(popup.commit_listener, popup)
    wl.signal_add(xdg_popup.base.surface.events.commit, popup.commit_listener)

    popup.destroy_listener = wl.create_listener(xdg_popup_destroy)
    surface_service.listener_registry:set(popup.destroy_listener, popup)
    wl.signal_add(xdg_popup.events.destroy, popup.destroy_listener)
end

local function server_new_toplevel_decoration(listener, data)
    local decoration = ffi.cast("struct wlr_xdg_toplevel_decoration_v1*", data)
    if decoration == nil or decoration == ffi.NULL then
        return
    end

    wl.roots.xdg_toplevel_decoration_v1_set_mode(
        decoration,
        wl.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE
    )
end

--------------------------------------------------------------------------------
-- Layer Shell Handlers
--------------------------------------------------------------------------------

local function get_layer_tree_for_layer(layer_value)
    if layer_value == layer_shell_layer.background then
        return surface_service.layers.background
    elseif layer_value == layer_shell_layer.bottom then
        return surface_service.layers.bottom
    elseif layer_value == layer_shell_layer.top then
        return surface_service.layers.top
    elseif layer_value == layer_shell_layer.overlay then
        return surface_service.layers.overlay
    end
    return surface_service.layers.background
end

local function layer_surface_map(listener, data)
    local layer_data = surface_service.listener_registry:get(listener)
    if not layer_data then return end

    local layer_surface = layer_data.layer_surface

    -- Configure positioning on MAP event (after surface is ready)
    -- This is when the layer surface state is fully populated and positioning works correctly
    local output = layer_surface.output
    if output == nil or output == ffi.NULL then
        local outputs = output_service:get_outputs()
        if #outputs > 0 then
            output = outputs[1].wlr_output
        end
    end

    if output ~= nil and output ~= ffi.NULL then
        local output_width, output_height = output_service:get_output_dimensions(output)
        output_width = output_width or output.width
        output_height = output_height or output.height

        local full_area = ffi.new("struct wlr_box", { 0, 0, output_width, output_height })
        local usable_area = ffi.new("struct wlr_box", { 0, 0, output_width, output_height })

        wl.roots.scene_layer_surface_v1_configure(layer_data.scene_layer, full_area, usable_area)
    end

    layer_data.mapped = true
end

local function layer_surface_unmap(listener, data)
    local layer_data = surface_service.listener_registry:get(listener)
    if not layer_data then return end

    layer_data.mapped = false
end

local function layer_surface_commit(listener, data)
    local layer_data = surface_service.listener_registry:get(listener)
    if not layer_data then return end

    local layer_surface = layer_data.layer_surface

    -- Only handle initial commit to set up the output assignment
    -- Actual positioning happens on the map event
    if not layer_surface.initial_commit then
        return
    end

    -- Assign output if not already set
    local output = layer_surface.output
    if output == nil or output == ffi.NULL then
        local outputs = output_service:get_outputs()
        if #outputs > 0 then
            output = outputs[1].wlr_output
            layer_surface.output = output
        end
    end

    -- Initial configure to tell the client its size
    if output ~= nil and output ~= ffi.NULL then
        local output_width, output_height = output_service:get_output_dimensions(output)
        output_width = output_width or output.width
        output_height = output_height or output.height

        local full_area = ffi.new("struct wlr_box", { 0, 0, output_width, output_height })
        local usable_area = ffi.new("struct wlr_box", { 0, 0, output_width, output_height })

        -- Configure the layer surface (positioning happens on map event)
        wl.roots.scene_layer_surface_v1_configure(layer_data.scene_layer, full_area, usable_area)
    end
end

local function layer_surface_destroy(listener, data)
    local layer_data = surface_service.listener_registry:get(listener)
    if not layer_data then return end

    unregister_layer_surface(layer_data)
    cleanup_registered_listener(layer_data.map_listener, listener)
    cleanup_registered_listener(layer_data.unmap_listener, listener)
    cleanup_registered_listener(layer_data.commit_listener, listener)
    cleanup_registered_listener(layer_data.destroy_listener, listener)
end

local function server_new_layer_surface(listener, data)
    local layer_surface = ffi.cast("struct wlr_layer_surface_v1*", data)
    local layer_tree = get_layer_tree_for_layer(layer_surface.pending.layer)
    local scene_layer = wl.roots.scene_layer_surface_v1_create(layer_tree, layer_surface)
    if is_null(scene_layer) then
        return
    end

    local layer_data = {
        layer_surface = layer_surface,
        scene_layer = scene_layer,
    }
    register_layer_surface(layer_data)

    layer_data.map_listener = wl.create_listener(layer_surface_map)
    surface_service.listener_registry:set(layer_data.map_listener, layer_data)
    wl.signal_add(layer_surface.surface.events.map, layer_data.map_listener)

    layer_data.unmap_listener = wl.create_listener(layer_surface_unmap)
    surface_service.listener_registry:set(layer_data.unmap_listener, layer_data)
    wl.signal_add(layer_surface.surface.events.unmap, layer_data.unmap_listener)

    layer_data.commit_listener = wl.create_listener(layer_surface_commit)
    surface_service.listener_registry:set(layer_data.commit_listener, layer_data)
    wl.signal_add(layer_surface.surface.events.commit, layer_data.commit_listener)

    layer_data.destroy_listener = wl.create_listener(layer_surface_destroy)
    surface_service.listener_registry:set(layer_data.destroy_listener, layer_data)
    wl.signal_add(layer_surface.events.destroy, layer_data.destroy_listener)
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function surface_service:init()
    if self.initialized then
        return
    end


    -- Register implemented protocols
    proto.implement("wl_compositor")
    proto.implement("wl_subcompositor")
    proto.implement("wl_surface")
    proto.implement("wl_subsurface")
    proto.implement("wl_buffer")
    proto.implement("wl_callback")
    proto.implement("wl_region")
    proto.implement("xdg_wm_base")
    proto.implement("xdg_surface")
    proto.implement("xdg_toplevel")
    proto.implement("xdg_popup")
    proto.implement("xdg_positioner")
    proto.implement("zwlr_layer_shell_v1")
    proto.implement("zwlr_layer_surface_v1")
    proto.implement("zwlr_foreign_toplevel_manager_v1")
    proto.implement("zwlr_foreign_toplevel_handle_v1")

    -- Create scene
    self.scene = wl.roots.scene_create()
    if is_null(self.scene) then
        log.error("Failed to create wlroots scene")
        return
    end
    self.scene_layout = wl.roots.scene_attach_output_layout(self.scene, output_service:get_output_layout())
    if is_null(self.scene_layout) then
        log.error("Failed to attach scene output layout")
        return
    end

    -- Create layer trees in z-order (first created = bottom, last = top)
    self.layers.background = wl.roots.scene_tree_create(self.scene.tree)
    self.layers.bottom = wl.roots.scene_tree_create(self.scene.tree)
    self.layers.windows = wl.roots.scene_tree_create(self.scene.tree)
    self.layers.top = wl.roots.scene_tree_create(self.scene.tree)
    self.layers.overlay = wl.roots.scene_tree_create(self.scene.tree)
    self.layers.unmanaged = wl.roots.scene_tree_create(self.scene.tree) -- Above overlay
    for name, tree in pairs(self.layers) do
        if is_null(tree) then
            log.error("Failed to create scene layer '%s'", name)
            return
        end
    end

    -- Tell output_service about the scene for scene output creation
    output_service:set_scene(self.scene, self.scene_layout)

    -- Create XDG shell
    self.xdg_shell = wl.roots.xdg_shell_create(core_service:get_display(), 3)
    if is_null(self.xdg_shell) then
        log.error("Failed to create xdg shell")
        return
    end
    self.listeners.new_xdg_toplevel = wl.create_listener(server_new_xdg_toplevel)
    wl.signal_add(self.xdg_shell.events.new_toplevel, self.listeners.new_xdg_toplevel)
    self.listeners.new_xdg_popup = wl.create_listener(server_new_xdg_popup)
    wl.signal_add(self.xdg_shell.events.new_popup, self.listeners.new_xdg_popup)

    -- Create layer shell
    self.layer_shell = wl.roots.layer_shell_v1_create(core_service:get_display(), 4)
    if is_null(self.layer_shell) then
        log.error("Failed to create layer shell")
        return
    end
    self.listeners.new_layer_surface = wl.create_listener(server_new_layer_surface)
    wl.signal_add(self.layer_shell.events.new_surface, self.listeners.new_layer_surface)

    -- Create foreign toplevel manager for taskbar integration
    self.foreign_toplevel_manager = wl.roots.foreign_toplevel_manager_v1_create(core_service:get_display())

    -- Create fractional scale manager for HiDPI support
    self.fractional_scale_manager = wl.roots.fractional_scale_manager_v1_create(core_service:get_display(), 1)
    if self.fractional_scale_manager and self.fractional_scale_manager ~= ffi.NULL then
        proto.implement("wp_fractional_scale_manager_v1")
        proto.implement("wp_fractional_scale_v1")
    end

    -- Create single pixel buffer manager (Phase 1 - Low Hanging Fruit)
    self.single_pixel_buffer_manager = wl.roots.single_pixel_buffer_manager_v1_create(core_service:get_display())
    if self.single_pixel_buffer_manager and self.single_pixel_buffer_manager ~= ffi.NULL then
        proto.implement("wp_single_pixel_buffer_manager_v1")
    end

    -- Create XDG activation (Phase 2 - Easy)
    self.xdg_activation = wl.roots.xdg_activation_v1_create(core_service:get_display())
    if self.xdg_activation and self.xdg_activation ~= ffi.NULL then
        proto.implement("xdg_activation_v1")
        proto.implement("xdg_activation_token_v1")
    end

    -- Create idle inhibit manager (Phase 2 - Easy)
    self.idle_inhibit_manager = wl.roots.idle_inhibit_v1_create(core_service:get_display())
    if self.idle_inhibit_manager and self.idle_inhibit_manager ~= ffi.NULL then
        proto.implement("zwp_idle_inhibit_manager_v1")
        proto.implement("zwp_idle_inhibitor_v1")
    end

    -- Create XDG decoration manager (Phase 2 - Easy)
    self.xdg_decoration_manager = wl.roots.xdg_decoration_manager_v1_create(core_service:get_display())
    if self.xdg_decoration_manager and self.xdg_decoration_manager ~= ffi.NULL then
        self.listeners.new_toplevel_decoration = wl.create_listener(server_new_toplevel_decoration)
        wl.signal_add(
            self.xdg_decoration_manager.events.new_toplevel_decoration,
            self.listeners.new_toplevel_decoration
        )
        proto.implement("zxdg_decoration_manager_v1")
        proto.implement("zxdg_toplevel_decoration_v1")
    end

    self.initialized = true
end

-- Get the scene
function surface_service:get_scene()
    return self.scene
end

-- Get the scene layout
function surface_service:get_scene_layout()
    return self.scene_layout
end

-- Get a layer tree by name
function surface_service:get_layer(name)
    return self.layers[name]
end

-- Get all layer trees
function surface_service:get_layers()
    return self.layers
end

-- Get all windows
function surface_service:get_windows()
    return self.windows
end

--------------------------------------------------------------------------------
-- Surface Geometry Helpers
--------------------------------------------------------------------------------

-- Get the natural dimensions of a surface (for buffer allocation)
function surface_service:get_surface_dimensions(surface)
    if not surface then return 0, 0 end

    -- For toplevels, use the geometry which accounts for CSDs
    if surface.role == "toplevel" and surface.role_obj then
        local geo = surface.role_obj.base.geometry
        if geo.width > 0 and geo.height > 0 then
            return geo.width, geo.height
        end
    end

    -- Fall back to wlr_surface dimensions
    if surface.wlr_surface then
        local current = surface.wlr_surface.current
        if current.width > 0 and current.height > 0 then
            return current.width, current.height
        end
    end

    return 0, 0
end

-- Get the full bounds including decorations (for CSD windows)
function surface_service:get_surface_full_bounds(surface)
    if not surface or not surface.scene_tree then return 0, 0, 0, 0 end

    -- Use the scene tree node coordinates
    local node = surface.scene_tree.node
    local x, y = node.x, node.y

    -- Get dimensions
    local w, h = self:get_surface_dimensions(surface)

    return x, y, w, h
end

-- Cleanup scene on shutdown
function surface_service:shutdown()
    if self.scene then
        wl.roots.scene_node_destroy(self.scene.tree.node)
        self.scene = nil
    end
end

return surface_service
