-- Protocols wlroots implements for us, each a self-contained entry:
--   { interfaces = { "wl_interface_name", ... }, setup = function(server) end }
-- setup creates the global and wires whatever compositor policy it needs.
-- Bigger protocols get their own module (xdg_shell, layer_shell, ...).

local wl = require("shared.wl")
local windows = require("compositor.windows")

local lib, C = wl.lib, wl.C

local protocols = {}

protocols.list = {
    {
        interfaces = { "wl_subcompositor", "wl_subsurface" },
        setup = function(server) lib.wlr_subcompositor_create(server.display) end,
    },
    {
        interfaces = { "wp_viewporter", "wp_viewport" },
        setup = function(server) lib.wlr_viewporter_create(server.display) end,
    },
    {
        interfaces = { "wp_single_pixel_buffer_manager_v1" },
        setup = function(server) lib.wlr_single_pixel_buffer_manager_v1_create(server.display) end,
    },
    {
        interfaces = { "wp_fractional_scale_manager_v1", "wp_fractional_scale_v1" },
        setup = function(server) lib.wlr_fractional_scale_manager_v1_create(server.display, 1) end,
    },
    {
        interfaces = { "zxdg_output_manager_v1", "zxdg_output_v1" },
        setup = function(server) lib.wlr_xdg_output_manager_v1_create(server.display, server.output_layout) end,
    },
    {
        interfaces = { "zwlr_gamma_control_manager_v1", "zwlr_gamma_control_v1" },
        setup = function(server)
            local manager = lib.wlr_gamma_control_manager_v1_create(server.display)
            lib.wlr_scene_set_gamma_control_manager_v1(server.scene, manager)
        end,
    },
    {
        interfaces = { "zwlr_screencopy_manager_v1", "zwlr_screencopy_frame_v1" },
        setup = function(server) lib.wlr_screencopy_manager_v1_create(server.display) end,
    },
    {
        interfaces = { "zwp_idle_inhibit_manager_v1", "zwp_idle_inhibitor_v1" },
        setup = function(server) lib.wlr_idle_inhibit_v1_create(server.display) end,
    },
    {
        interfaces = { "zwp_pointer_constraints_v1", "zwp_confined_pointer_v1", "zwp_locked_pointer_v1" },
        setup = function(server) lib.wlr_pointer_constraints_v1_create(server.display) end,
    },
    {
        -- Clients that use cursor-shape name their cursor instead of drawing it.
        interfaces = { "wp_cursor_shape_manager_v1", "wp_cursor_shape_device_v1" },
        setup = function(server)
            local manager = lib.wlr_cursor_shape_manager_v1_create(server.display, 1)
            server.scope:listen(manager.events.request_set_shape, function(event)
                local seat = server.seat
                if event.seat_client == seat.pointer_state.focused_client and not server.grab then
                    lib.wlr_cursor_set_xcursor(server.cursor, server.cursor_mgr,
                        lib.wlr_cursor_shape_v1_name(event.shape))
                end
            end, "struct wlr_cursor_shape_manager_v1_request_set_shape_event")
        end,
    },
    {
        -- Launchers hand an activation token to the app they start; honour it.
        interfaces = { "xdg_activation_v1", "xdg_activation_token_v1" },
        setup = function(server)
            local activation = lib.wlr_xdg_activation_v1_create(server.display)
            server.scope:listen(activation.events.request_activate, function(event)
                local w = windows.from_surface(server, event.surface)
                if w and w.mapped then windows.focus(server, w) end
            end, "struct wlr_xdg_activation_v1_request_activate_event")
        end,
    },
    {
        -- Taskbars: a handle per mapped window, kept in sync with its state.
        interfaces = { "zwlr_foreign_toplevel_manager_v1", "zwlr_foreign_toplevel_handle_v1" },
        setup = function(server)
            local manager = lib.wlr_foreign_toplevel_manager_v1_create(server.display)
            local events = server.events

            local function sync(w)
                local h = w.data.foreign_toplevel
                if not h then return end
                local title, app_id = w:title(), w:app_id()
                if title then h:set_title(title) end
                if app_id then h:set_app_id(app_id) end
            end

            events:on("window:map", function(w)
                local h = lib.wlr_foreign_toplevel_handle_v1_create(manager)
                w.data.foreign_toplevel = h
                local scope = server.scope:child("foreign toplevel")
                w.data.foreign_toplevel_scope = scope
                scope:listen(h.events.request_activate, function() windows.focus(server, w) end)
                scope:listen(h.events.request_close, function() w:close() end)
                sync(w)
            end)
            events:on("window:unmap", function(w)
                local h = w.data.foreign_toplevel
                if not h then return end
                w.data.foreign_toplevel_scope:close()
                h:destroy()
                w.data.foreign_toplevel, w.data.foreign_toplevel_scope = nil, nil
            end)
            events:on("window:title", sync)
            events:on("window:focus", function(w)
                if w.data.foreign_toplevel then w.data.foreign_toplevel:set_activated(true) end
            end)
            events:on("window:blur", function(w)
                if w.data.foreign_toplevel then w.data.foreign_toplevel:set_activated(false) end
            end)
        end,
    },
}

--- Create every protocol in the list. Returns the interfaces they provide.
function protocols.setup(server)
    local interfaces = {}
    for _, p in ipairs(protocols.list) do
        p.setup(server)
        for _, name in ipairs(p.interfaces) do interfaces[#interfaces + 1] = name end
    end
    return interfaces
end

return protocols
