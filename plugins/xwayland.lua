-- plugins/xwayland.lua
-- XWayland integration plugin - enables running X11 applications

local log = require("shared.log")
local wl = require("shared.wayland.server")
local Scope = require("shared.scope")
local ffi = wl._ffi

local plugin = {
    name = "xwayland",
}

local xwayland = nil
local unmanaged_surfaces = {}
local managed_surfaces = {}

--------------------------------------------------------------------------------
-- Unmanaged Surfaces (override_redirect = true)
--------------------------------------------------------------------------------

local function create_unmanaged(xsurface)
    local surface_service = require("compositor.services.surface")

    local state = {
        xsurface = xsurface,
        scene_surface = nil,
        scope = Scope.new("xwayland:unmanaged"),
        surface_scope = nil,
    }

    local function map()
        if not xsurface.surface or xsurface.surface == ffi.NULL then return end

        state.scene_surface = wl.roots.scene_surface_create(
            surface_service.layers.unmanaged,
            xsurface.surface
        )

        if state.scene_surface and state.scene_surface ~= ffi.NULL then
            wl.roots.scene_node_set_position(
                state.scene_surface.buffer.node,
                xsurface.x,
                xsurface.y
            )
        end
    end

    local function unmap()
        if state.scene_surface and state.scene_surface ~= ffi.NULL then
            wl.roots.scene_node_destroy(state.scene_surface.buffer.node)
            state.scene_surface = nil
        end
    end

    state.scope:listen(xsurface.events.request_configure, function(_, data)
        local ev = wl.event(data, "struct wlr_xwayland_surface_configure_event*")
        wl.roots.xwayland_surface_configure(xsurface, ev.x, ev.y, ev.width, ev.height)
    end)

    state.scope:listen(xsurface.events.set_geometry, function()
        if state.scene_surface and state.scene_surface ~= ffi.NULL then
            wl.roots.scene_node_set_position(
                state.scene_surface.buffer.node,
                xsurface.x,
                xsurface.y
            )
        end
    end)

    state.scope:listen(xsurface.events.associate, function()
        if state.surface_scope then
            state.surface_scope:close()
        end
        state.surface_scope = Scope.new("xwayland:unmanaged-surface")
        if xsurface.surface and xsurface.surface ~= ffi.NULL then
            state.surface_scope:listen(xsurface.surface.events.map, function() map() end)
            state.surface_scope:listen(xsurface.surface.events.unmap, function() unmap() end)
        end
    end)

    state.scope:listen(xsurface.events.dissociate, function()
        if state.surface_scope then
            state.surface_scope:close()
            state.surface_scope = nil
        end
    end)

    state.scope:listen(xsurface.events.destroy, function()
        unmap()
        if state.surface_scope then
            state.surface_scope:close()
            state.surface_scope = nil
        end
        state.scope:close()
        unmanaged_surfaces[xsurface] = nil
    end)

    unmanaged_surfaces[xsurface] = state
    return state
end

--------------------------------------------------------------------------------
-- Managed Surfaces (regular X11 windows)
--------------------------------------------------------------------------------

local function create_managed(xsurface)
    local surface_service = require("compositor.services.surface")

    local state = {
        xsurface = xsurface,
        surface = nil,
        mapped = false,
        scope = Scope.new("xwayland:managed"),
        surface_scope = nil,
    }

    local function update_metadata(surface)
        if xsurface.title and xsurface.title ~= ffi.NULL then
            surface.title = ffi.string(xsurface.title)
        end
        if xsurface.class and xsurface.class ~= ffi.NULL then
            surface.class = ffi.string(xsurface.class)
        end
    end

    local function map()
        if state.mapped or not xsurface.surface or xsurface.surface == ffi.NULL then return end

        local scene_tree = wl.roots.scene_subsurface_tree_create(
            surface_service.layers.windows,
            xsurface.surface
        )
        if not scene_tree or scene_tree == ffi.NULL then
            return
        end

        local surface = surface_service:upgrade(xsurface.surface, "xwayland", xsurface, scene_tree)
        surface.mapped = true
        update_metadata(surface)

        state.surface = surface
        state.mapped = true

        table.insert(surface_service.windows, 1, surface)

        local layout_service = require("compositor.services.layout")
        layout_service:on_window_add(surface, nil)

        surface_service.events:emit("surface:map", surface)
        surface_service:focus_window(surface)
    end

    local function unmap()
        local surface = state.surface
        if not state.mapped or not surface then return end

        local layout_service = require("compositor.services.layout")
        layout_service:on_window_remove(surface)
        surface_service.events:emit("surface:unmap", surface)

        for i, w in ipairs(surface_service.windows) do
            if w == surface then
                table.remove(surface_service.windows, i)
                break
            end
        end

        local scene = surface:scene_node()
        if scene then
            scene:destroy()
        end
        surface.mapped = false

        state.surface = nil
        state.mapped = false
        surface_service:remove_surface(xsurface.surface)
        surface:set_role("xwayland", xsurface, nil)
    end

    state.scope:listen(xsurface.events.request_configure, function(_, data)
        local ev = wl.event(data, "struct wlr_xwayland_surface_configure_event*")
        wl.roots.xwayland_surface_configure(xsurface, ev.x, ev.y, ev.width, ev.height)
    end)

    state.scope:listen(xsurface.events.request_fullscreen, function()
        if state.surface then
            local layout_service = require("compositor.services.layout")
            layout_service:enter_fullscreen(state.surface)
        end
    end)

    state.scope:listen(xsurface.events.request_move, function()
        if not state.surface then return end
        local input_service = require("compositor.services.input")
        local layout_service = require("compositor.services.layout")
        local cursor = input_service:get_cursor()
        layout_service:begin_move(state.surface, cursor.x, cursor.y)
    end)

    state.scope:listen(xsurface.events.request_resize, function(_, data)
        if not state.surface then return end
        local ev = wl.event(data, "struct wlr_xwayland_resize_event*")
        local input_service = require("compositor.services.input")
        local layout_service = require("compositor.services.layout")
        local cursor = input_service:get_cursor()
        layout_service:begin_resize(state.surface, cursor.x, cursor.y, ev.edges)
    end)

    state.scope:listen(xsurface.events.set_title, function()
        if state.surface then
            update_metadata(state.surface)
        end
    end)

    state.scope:listen(xsurface.events.set_class, function()
        if state.surface then
            update_metadata(state.surface)
        end
    end)

    state.scope:listen(xsurface.events.associate, function()
        if state.surface_scope then
            state.surface_scope:close()
        end
        state.surface_scope = Scope.new("xwayland:managed-surface")
        if xsurface.surface and xsurface.surface ~= ffi.NULL then
            state.surface_scope:listen(xsurface.surface.events.map, function() map() end)
            state.surface_scope:listen(xsurface.surface.events.unmap, function() unmap() end)
            state.surface_scope:listen(xsurface.surface.events.commit, function()
                if state.surface and state.mapped then
                    surface_service.events:emit("surface:commit", state.surface)
                end
            end)
        end
    end)

    state.scope:listen(xsurface.events.dissociate, function()
        if state.surface_scope then
            state.surface_scope:close()
            state.surface_scope = nil
        end
    end)

    state.scope:listen(xsurface.events.destroy, function()
        unmap()
        if state.surface_scope then
            state.surface_scope:close()
            state.surface_scope = nil
        end
        state.scope:close()
        managed_surfaces[xsurface] = nil
    end)

    managed_surfaces[xsurface] = state
    return state
end

--------------------------------------------------------------------------------
-- Plugin Lifecycle
--------------------------------------------------------------------------------

local function handle_new_surface(listener, data)
    local xsurface = wl.event(data, "struct wlr_xwayland_surface*")

    if xsurface.override_redirect then
        create_unmanaged(xsurface)
    else
        create_managed(xsurface)
    end
end

function plugin:mount(config)
    self._config = config
    self._initialized = false

    local core_service = require("compositor.services.core")
    self._ready_listener = core_service.events:on("compositor:ready", function()
        self:init_xwayland()
    end)

    return {}
end

function plugin:init_xwayland()
    if self._initialized then return end

    local core_service = require("compositor.services.core")

    if not wl.roots.xwayland_create then
        log.warn("XWayland not available (wlroots may be built without XWayland support)")
        return false
    end

    local display = core_service.wl_display
    local compositor = core_service.compositor

    if not display or not compositor then
        log.warn("XWayland: core_service not properly initialized")
        return false
    end

    local ok, result = pcall(function()
        return wl.roots.xwayland_create(display, compositor, true)
    end)

    if not ok then
        log.warn("XWayland creation failed: %s", tostring(result))
        return false
    end

    xwayland = result
    if not xwayland or xwayland == ffi.NULL then
        log.warn("Failed to create XWayland server - X11 apps will not work")
        return false
    end

    self._scope = Scope.new("xwayland")

    if xwayland.display_name and xwayland.display_name ~= ffi.NULL then
        wl.setenv("DISPLAY", ffi.string(xwayland.display_name))
    end

    self._scope:listen(xwayland.events.new_surface, handle_new_surface, self)

    self._scope:listen(xwayland.events.ready, function()
        local display_name = xwayland.display_name and xwayland.display_name ~= ffi.NULL
            and ffi.string(xwayland.display_name) or nil
        if display_name then
            wl.setenv("DISPLAY", display_name)
        else
            log.warn("XWayland ready but no display name available")
        end

        local input_service = require("compositor.services.input")
        if input_service.seat then
            wl.roots.xwayland_set_seat(xwayland, input_service.seat)
        end
    end, self)

    local proto = require("shared.wayland.registry")
    proto.implement("xwayland_shell_v1")
    proto.implement("xwayland_surface_v1")

    self._initialized = true
    return true
end

function plugin:unmount()
    if self._ready_listener and self._ready_listener.off then
        self._ready_listener:off()
        self._ready_listener = nil
    end

    if self._scope then
        self._scope:close()
        self._scope = nil
    end

    for _, surface in pairs(unmanaged_surfaces) do
        surface.scope:close()
    end
    for _, surface in pairs(managed_surfaces) do
        surface.scope:close()
    end

    if xwayland and xwayland ~= ffi.NULL then
        wl.roots.xwayland_destroy(xwayland)
        xwayland = nil
    end

    unmanaged_surfaces = {}
    managed_surfaces = {}
    self._initialized = false
end

return plugin
