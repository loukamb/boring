-- plugins/xwayland.lua
-- XWayland integration plugin - enables running X11 applications

local log = require("shared.log")
local wl = require("shared.wayland.server")
local ffi = wl._ffi

local plugin = {
    name = "xwayland",
}

-- State
local xwayland = nil
local listeners = {}
local unmanaged_surfaces = {}
local managed_surfaces = {}

--------------------------------------------------------------------------------
-- Unmanaged Surfaces (override_redirect = true)
-- Popups, menus, tooltips - render above everything
--------------------------------------------------------------------------------

local function create_unmanaged(xsurface)
    local surface_service = require("compositor.services.surface")

    local surface = {
        xsurface = xsurface,
        scene_surface = nil,
        listeners = {},
    }

    -- Handle map
    surface.listeners.map = wl.create_listener(function(listener, data)
        if not xsurface.surface or xsurface.surface == ffi.NULL then return end

        -- Create scene surface in unmanaged layer
        surface.scene_surface = wl.roots.scene_surface_create(
            surface_service.layers.unmanaged,
            xsurface.surface
        )

        if surface.scene_surface and surface.scene_surface ~= ffi.NULL then
            -- Position at X11 coordinates
            wl.roots.scene_node_set_position(
                surface.scene_surface.buffer.node,
                xsurface.x, xsurface.y
            )
        end
    end)

    -- Handle unmap
    surface.listeners.unmap = wl.create_listener(function(listener, data)
        if surface.scene_surface and surface.scene_surface ~= ffi.NULL then
            wl.roots.scene_node_destroy(surface.scene_surface.buffer.node)
            surface.scene_surface = nil
        end
    end)

    -- Handle geometry changes
    surface.listeners.set_geometry = wl.create_listener(function(listener, data)
        if surface.scene_surface and surface.scene_surface ~= ffi.NULL then
            wl.roots.scene_node_set_position(
                surface.scene_surface.buffer.node,
                xsurface.x, xsurface.y
            )
        end
    end)

    -- Handle configure requests
    surface.listeners.request_configure = wl.create_listener(function(listener, data)
        local ev = ffi.cast("struct wlr_xwayland_surface_configure_event*", data)
        wl.roots.xwayland_surface_configure(xsurface, ev.x, ev.y, ev.width, ev.height)
    end)

    -- Handle destroy
    surface.listeners.destroy = wl.create_listener(function(listener, data)
        -- Clean up listeners
        for _, l in pairs(surface.listeners) do
            wl.destroy_listener(l)
        end
        unmanaged_surfaces[xsurface] = nil
    end)

    -- Wire up listeners
    wl.signal_add(xsurface.events.request_configure, surface.listeners.request_configure)

    -- Associate/dissociate for surface lifecycle
    surface.listeners.associate = wl.create_listener(function(listener, data)
        if xsurface.surface and xsurface.surface ~= ffi.NULL then
            wl.signal_add(xsurface.surface.events.map, surface.listeners.map)
            wl.signal_add(xsurface.surface.events.unmap, surface.listeners.unmap)
        end
    end)

    surface.listeners.dissociate = wl.create_listener(function(listener, data)
        wl.list_remove(surface.listeners.map[0].link)
        wl.list_remove(surface.listeners.unmap[0].link)
    end)

    wl.signal_add(xsurface.events.associate, surface.listeners.associate)
    wl.signal_add(xsurface.events.dissociate, surface.listeners.dissociate)
    wl.signal_add(xsurface.events.destroy, surface.listeners.destroy)
    wl.signal_add(xsurface.events.set_geometry, surface.listeners.set_geometry)

    unmanaged_surfaces[xsurface] = surface
    return surface
end

--------------------------------------------------------------------------------
-- Managed Surfaces (regular X11 windows)
-- Integrated into compositor as normal windows
--------------------------------------------------------------------------------

local function create_managed(xsurface)
    local surface_service = require("compositor.services.surface")
    local core_service = require("compositor.services.core")

    local surface = {
        xsurface = xsurface,
        scene_tree = nil,
        mapped = false,
        listeners = {},
        -- Surface properties
        title = nil,
        class = nil,
        role = "xwayland",
    }

    -- Handle map
    surface.listeners.map = wl.create_listener(function(listener, data)
        if not xsurface.surface or xsurface.surface == ffi.NULL then return end

        -- Create scene tree in windows layer
        surface.scene_tree = wl.roots.scene_subsurface_tree_create(
            surface_service.layers.windows,
            xsurface.surface
        )

        if surface.scene_tree and surface.scene_tree ~= ffi.NULL then
            surface.mapped = true

            -- Get title/class
            if xsurface.title and xsurface.title ~= ffi.NULL then
                surface.title = ffi.string(xsurface.title)
            end
            if xsurface.class and xsurface.class ~= ffi.NULL then
                surface.class = ffi.string(xsurface.class)
            end

            -- Add set_size method for layout compatibility
            function surface:set_size(width, height)
                wl.roots.xwayland_surface_configure(
                    self.xsurface,
                    self.xsurface.x, self.xsurface.y,
                    width, height
                )
            end

            -- Add role_obj shim for borders plugin compatibility
            -- The borders plugin expects surface.role_obj.base.current.geometry
            surface.role_obj = {
                base = {
                    current = {
                        geometry = {
                            width = xsurface.width,
                            height = xsurface.height,
                            x = 0,
                            y = 0,
                        }
                    }
                }
            }

            -- Add method to update geometry after resize
            function surface:update_geometry()
                self.role_obj.base.current.geometry.width = self.xsurface.width
                self.role_obj.base.current.geometry.height = self.xsurface.height
            end

            -- Add to window list
            table.insert(surface_service.windows, 1, surface)

            -- Notify layout service
            local layout_service = require("compositor.services.layout")
            layout_service:on_window_add(surface, nil)

            -- Emit map event for plugins
            surface_service.events:emit("surface:map", surface)

            -- Focus the window
            surface_service:focus_window(surface)
        end
    end)

    -- Handle unmap
    surface.listeners.unmap = wl.create_listener(function(listener, data)
        if not surface.mapped then return end

        -- Notify layout
        local layout_service = require("compositor.services.layout")
        layout_service:on_window_remove(surface)

        -- Emit unmap event
        surface_service.events:emit("surface:unmap", surface)

        -- Remove from windows list
        for i, w in ipairs(surface_service.windows) do
            if w == surface then
                table.remove(surface_service.windows, i)
                break
            end
        end

        -- Destroy scene tree
        if surface.scene_tree and surface.scene_tree ~= ffi.NULL then
            wl.roots.scene_node_destroy(surface.scene_tree.node)
            surface.scene_tree = nil
        end

        surface.mapped = false
    end)

    -- Handle commit (for plugins)
    surface.listeners.commit = wl.create_listener(function(listener, data)
        if surface.mapped then
            -- Update geometry for borders plugin
            if surface.update_geometry then
                surface:update_geometry()
            end
            surface_service.events:emit("surface:commit", surface)
        end
    end)

    -- Handle configure requests
    surface.listeners.request_configure = wl.create_listener(function(listener, data)
        local ev = ffi.cast("struct wlr_xwayland_surface_configure_event*", data)

        if not surface.mapped then
            -- Not mapped yet, allow configure
            wl.roots.xwayland_surface_configure(xsurface, ev.x, ev.y, ev.width, ev.height)
        else
            -- Mapped - constrain to current position/size if tiled
            -- For now, allow floating behavior
            wl.roots.xwayland_surface_configure(xsurface, ev.x, ev.y, ev.width, ev.height)
        end
    end)

    -- Handle fullscreen requests
    surface.listeners.request_fullscreen = wl.create_listener(function(listener, data)
        -- TODO: Implement fullscreen
    end)

    -- Handle move requests
    surface.listeners.request_move = wl.create_listener(function(listener, data)
        if not surface.mapped then return end
        local input_service = require("compositor.services.input")
        local layout_service = require("compositor.services.layout")
        local cursor = input_service:get_cursor()
        layout_service:begin_move(surface, cursor.x, cursor.y)
    end)

    -- Handle resize requests
    surface.listeners.request_resize = wl.create_listener(function(listener, data)
        if not surface.mapped then return end
        local ev = ffi.cast("struct wlr_xwayland_resize_event*", data)
        local input_service = require("compositor.services.input")
        local layout_service = require("compositor.services.layout")
        local cursor = input_service:get_cursor()
        layout_service:begin_resize(surface, cursor.x, cursor.y, ev.edges)
    end)

    -- Handle title changes
    surface.listeners.set_title = wl.create_listener(function(listener, data)
        if xsurface.title and xsurface.title ~= ffi.NULL then
            surface.title = ffi.string(xsurface.title)
        end
    end)

    -- Handle class changes
    surface.listeners.set_class = wl.create_listener(function(listener, data)
        if xsurface.class and xsurface.class ~= ffi.NULL then
            surface.class = ffi.string(xsurface.class)
        end
    end)

    -- Handle destroy
    surface.listeners.destroy = wl.create_listener(function(listener, data)
        if surface.mapped then
            surface.listeners.unmap[0].notify(surface.listeners.unmap, nil)
        end

        for _, l in pairs(surface.listeners) do
            wl.destroy_listener(l)
        end
        managed_surfaces[xsurface] = nil
    end)

    -- Wire up listeners
    wl.signal_add(xsurface.events.request_configure, surface.listeners.request_configure)
    wl.signal_add(xsurface.events.request_fullscreen, surface.listeners.request_fullscreen)
    wl.signal_add(xsurface.events.request_move, surface.listeners.request_move)
    wl.signal_add(xsurface.events.request_resize, surface.listeners.request_resize)
    wl.signal_add(xsurface.events.set_title, surface.listeners.set_title)
    wl.signal_add(xsurface.events.set_class, surface.listeners.set_class)
    wl.signal_add(xsurface.events.destroy, surface.listeners.destroy)

    -- Associate/dissociate
    surface.listeners.associate = wl.create_listener(function(listener, data)
        if xsurface.surface and xsurface.surface ~= ffi.NULL then
            wl.signal_add(xsurface.surface.events.map, surface.listeners.map)
            wl.signal_add(xsurface.surface.events.unmap, surface.listeners.unmap)
            wl.signal_add(xsurface.surface.events.commit, surface.listeners.commit)
        end
    end)

    surface.listeners.dissociate = wl.create_listener(function(listener, data)
        wl.list_remove(surface.listeners.map[0].link)
        wl.list_remove(surface.listeners.unmap[0].link)
        wl.list_remove(surface.listeners.commit[0].link)
    end)

    wl.signal_add(xsurface.events.associate, surface.listeners.associate)
    wl.signal_add(xsurface.events.dissociate, surface.listeners.dissociate)

    managed_surfaces[xsurface] = surface
    return surface
end

--------------------------------------------------------------------------------
-- New Surface Handler
--------------------------------------------------------------------------------

local function handle_new_surface(listener, data)
    local xsurface = ffi.cast("struct wlr_xwayland_surface*", data)

    if xsurface.override_redirect then
        create_unmanaged(xsurface)
    else
        create_managed(xsurface)
    end
end

--------------------------------------------------------------------------------
-- Plugin Lifecycle
--------------------------------------------------------------------------------

function plugin:mount(config)
    -- XWayland needs core_service to be initialized first.
    -- Subscribe to compositor:ready event to initialize when services are up.
    self._config = config
    self._initialized = false

    local core_service = require("compositor.services.core")
    self._ready_listener = core_service.events:on("compositor:ready", function()
        self:init_xwayland()
    end)

    return {}
end

-- Actually initialize XWayland (called lazily or after services are ready)
function plugin:init_xwayland()
    if self._initialized then return end

    local core_service = require("compositor.services.core")
    local surface_service = require("compositor.services.surface")

    -- Check if XWayland function exists
    if not wl.roots.xwayland_create then
        log.warn("XWayland not available (wlroots may be built without XWayland support)")
        return false
    end

    -- Get compositor resources directly
    local display = core_service.wl_display
    local compositor = core_service.compositor

    if not display or not compositor then
        log.warn("XWayland: core_service not properly initialized")
        return false
    end

    -- Create XWayland server (lazy mode) with error handling
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

    -- Set DISPLAY environment variable immediately (like Sway does)
    -- This allows X11 apps to connect even before the ready event
    if xwayland.display_name and xwayland.display_name ~= ffi.NULL then
        local display_name = ffi.string(xwayland.display_name)
        wl.setenv("DISPLAY", display_name)
    end

    -- Listen for new surfaces
    listeners.new_surface = wl.create_listener(handle_new_surface)
    wl.signal_add(xwayland.events.new_surface, listeners.new_surface)

    -- Ready listener (for atom resolution and DISPLAY env var)
    listeners.ready = wl.create_listener(function(listener, data)
        local display_name = xwayland.display_name and xwayland.display_name ~= ffi.NULL
            and ffi.string(xwayland.display_name) or nil
        if display_name then
            wl.setenv("DISPLAY", display_name)
        else
            log.warn("XWayland ready but no display name available")
        end
        -- Set seat for XWayland
        local input_service = require("compositor.services.input")
        if input_service.seat then
            wl.roots.xwayland_set_seat(xwayland, input_service.seat)
        end
    end)
    wl.signal_add(xwayland.events.ready, listeners.ready)

    -- Register xwayland protocols
    local proto = require("shared.wayland.registry")
    proto.implement("xwayland_shell_v1")
    proto.implement("xwayland_surface_v1")

    self._initialized = true
    return true
end

function plugin:unmount()
    -- Clean up ready listener
    if self._ready_listener and self._ready_listener.off then
        self._ready_listener:off()
        self._ready_listener = nil
    end

    -- Clean up listeners
    for _, l in pairs(listeners) do
        wl.destroy_listener(l)
    end
    listeners = {}

    -- Destroy XWayland
    if xwayland and xwayland ~= ffi.NULL then
        wl.roots.xwayland_destroy(xwayland)
        xwayland = nil
    end

    -- Clear surface tables
    unmanaged_surfaces = {}
    managed_surfaces = {}
    self._initialized = false
end

return plugin
