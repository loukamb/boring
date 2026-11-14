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
    {
        -- Frame timing feedback for video players and games.
        interfaces = { "wp_presentation", "wp_presentation_feedback" },
        setup = function(server) lib.wlr_presentation_create(server.display, server.backend, 2) end,
    },
    {
        -- GPU buffers (only with a renderer that can import them).
        interfaces = { "zwp_linux_dmabuf_v1", "zwp_linux_buffer_params_v1", "zwp_linux_dmabuf_feedback_v1" },
        setup = function(server)
            if lib.wlr_renderer_get_texture_formats(server.renderer, C.WLR_BUFFER_CAP_DMABUF) == nil then
                return false
            end
            local dmabuf = lib.wlr_linux_dmabuf_v1_create_with_renderer(server.display, 5, server.renderer)
            lib.wlr_scene_set_linux_dmabuf_v1(server.scene, dmabuf)
        end,
    },
    {
        interfaces = { "wp_alpha_modifier_v1", "wp_alpha_modifier_surface_v1" },
        setup = function(server) lib.wlr_alpha_modifier_v1_create(server.display) end,
    },
    {
        interfaces = { "wp_content_type_manager_v1", "wp_content_type_v1" },
        setup = function(server) lib.wlr_content_type_manager_v1_create(server.display, 1) end,
    },
    {
        interfaces = { "wp_tearing_control_manager_v1", "wp_tearing_control_v1" },
        setup = function(server) lib.wlr_tearing_control_manager_v1_create(server.display, 1) end,
    },
    {
        interfaces = { "xdg_wm_dialog_v1", "xdg_dialog_v1" },
        setup = function(server) lib.wlr_xdg_wm_dialog_v1_create(server.display, 1) end,
    },
    {
        interfaces = { "xdg_toplevel_icon_manager_v1", "xdg_toplevel_icon_v1" },
        setup = function(server) lib.wlr_xdg_toplevel_icon_manager_v1_create(server.display, 1) end,
    },
    {
        interfaces = { "xdg_system_bell_v1" },
        setup = function(server) lib.wlr_xdg_system_bell_v1_create(server.display, 1) end,
    },
    {
        -- Lets portals parent dialogs to windows of other clients.
        interfaces = { "zxdg_exporter_v1", "zxdg_importer_v1", "zxdg_exporter_v2", "zxdg_importer_v2",
            "zxdg_exported_v1", "zxdg_imported_v1", "zxdg_exported_v2", "zxdg_imported_v2" },
        setup = function(server)
            local registry = lib.wlr_xdg_foreign_registry_create(server.display)
            lib.wlr_xdg_foreign_v1_create(server.display, registry)
            lib.wlr_xdg_foreign_v2_create(server.display, registry)
        end,
    },
    {
        -- Clipboard managers.
        interfaces = { "zwlr_data_control_manager_v1", "zwlr_data_control_device_v1",
            "zwlr_data_control_source_v1", "zwlr_data_control_offer_v1",
            "ext_data_control_manager_v1", "ext_data_control_device_v1",
            "ext_data_control_source_v1", "ext_data_control_offer_v1" },
        setup = function(server)
            lib.wlr_data_control_manager_v1_create(server.display)
            lib.wlr_ext_data_control_manager_v1_create(server.display, 1)
        end,
    },
    {
        -- Screen capture for portals and recorders (successor of screencopy).
        interfaces = { "ext_image_copy_capture_manager_v1", "ext_image_copy_capture_session_v1",
            "ext_image_copy_capture_frame_v1", "ext_output_image_capture_source_manager_v1",
            "ext_image_capture_source_v1" },
        setup = function(server)
            lib.wlr_ext_image_copy_capture_manager_v1_create(server.display, 1)
            lib.wlr_ext_output_image_capture_source_manager_v1_create(server.display, 1)
        end,
    },
    {
        -- Idle daemons (swayidle): input counts as activity; idle inhibitors
        -- (video players) hold it off.
        interfaces = { "ext_idle_notifier_v1", "ext_idle_notification_v1",
            "zwp_idle_inhibit_manager_v1", "zwp_idle_inhibitor_v1" },
        setup = function(server)
            local notifier = lib.wlr_idle_notifier_v1_create(server.display)
            server.on_activity = function()
                lib.wlr_idle_notifier_v1_notify_activity(notifier, server.seat)
            end
            local inhibit = lib.wlr_idle_inhibit_v1_create(server.display)
            local count = 0
            server.scope:listen(inhibit.events.new_inhibitor, function(inhibitor)
                count = count + 1
                lib.wlr_idle_notifier_v1_set_inhibited(notifier, true)
                local scope = server.scope:child("idle inhibitor")
                scope:listen(inhibitor.events.destroy, function()
                    count = count - 1
                    lib.wlr_idle_notifier_v1_set_inhibited(notifier, count > 0)
                    scope:close()
                end)
            end, "struct wlr_idle_inhibitor_v1")
        end,
    },
    {
        -- Remote desktops and VMs may ask to receive compositor shortcuts.
        interfaces = { "zwp_keyboard_shortcuts_inhibit_manager_v1", "zwp_keyboard_shortcuts_inhibitor_v1" },
        setup = function(server)
            local manager = lib.wlr_keyboard_shortcuts_inhibit_v1_create(server.display)
            local inhibitors = {}
            server.shortcuts_inhibited = function()
                local focused = server.focused
                if not focused then return false end
                for inhibitor in pairs(inhibitors) do
                    if inhibitor.surface == focused.surface and inhibitor.active then return true end
                end
                return false
            end
            server.scope:listen(manager.events.new_inhibitor, function(inhibitor)
                inhibitors[inhibitor] = true
                lib.wlr_keyboard_shortcuts_inhibitor_v1_activate(inhibitor)
                local scope = server.scope:child("shortcuts inhibitor")
                scope:listen(inhibitor.events.destroy, function()
                    inhibitors[inhibitor] = nil
                    scope:close()
                end)
            end, "struct wlr_keyboard_shortcuts_inhibitor_v1")
        end,
    },
    {
        -- Taskbars, newer protocol: a read-only list of windows.
        interfaces = { "ext_foreign_toplevel_list_v1", "ext_foreign_toplevel_handle_v1" },
        setup = function(server)
            local list = lib.wlr_ext_foreign_toplevel_list_v1_create(server.display, 1)
            local state = wl.ffi.new("struct wlr_ext_foreign_toplevel_handle_v1_state")
            local function fill(w)
                state.title = w:title()
                state.app_id = w:app_id()
                return state
            end
            server.events:on("window:map", function(w)
                w.data.ext_toplevel = lib.wlr_ext_foreign_toplevel_handle_v1_create(list, fill(w))
            end)
            server.events:on("window:unmap", function(w)
                if w.data.ext_toplevel then
                    lib.wlr_ext_foreign_toplevel_handle_v1_destroy(w.data.ext_toplevel)
                    w.data.ext_toplevel = nil
                end
            end)
            server.events:on("window:title", function(w)
                if w.data.ext_toplevel then
                    lib.wlr_ext_foreign_toplevel_handle_v1_update_state(w.data.ext_toplevel, fill(w))
                end
            end)
        end,
    },
}

--- Create every protocol in the list. Returns the interfaces they provide.
function protocols.setup(server)
    local interfaces = {}
    for _, p in ipairs(protocols.list) do
        -- setup returns false when the protocol isn't available here.
        if p.setup(server) ~= false then
            for _, name in ipairs(p.interfaces) do interfaces[#interfaces + 1] = name end
        end
    end
    return interfaces
end

return protocols
