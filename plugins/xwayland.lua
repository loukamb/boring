-- plugins/xwayland.lua
-- Run X11 applications through XWayland.
--
--   plugin("@boring/xwayland"):mount()
--
-- Regular X11 windows become boring windows (role "xwayland"); override-
-- redirect ones (menus, tooltips) are drawn unmanaged above everything.

local plugin = { name = "xwayland" }

function plugin:mount(_, ctx)
    local wl = boring.wl
    local lib, C, ffi = wl.lib, wl.C, wl.ffi
    local server = boring.server

    if lib.wlr_xwayland_create == nil then
        boring.log.warn("xwayland: wlroots was built without XWayland support")
        return {}
    end
    local xwayland = lib.wlr_xwayland_create(server.display, server.compositor, true)
    if xwayland == nil then
        boring.log.warn("xwayland: failed to start XWayland; X11 apps won't work")
        return {}
    end

    local scope = ctx.scope
    scope:defer(function() lib.wlr_xwayland_destroy(xwayland) end)

    -- Role implementation (see compositor/window.lua).
    local function impl(xs)
        return {
            role = "xwayland",
            geometry = function() return 0, 0, xs.width, xs.height end,
            set_size = function(width, height)
                local w = boring.window.from_surface(xs.surface)
                local x, y = 0, 0
                if w then x, y = w:position() end
                xs:configure(x, y, width, height)
            end,
            moved = function(x, y) xs:configure(x, y, xs.width, xs.height) end,
            set_activated = function(on)
                xs:activate(on)
                if on then lib.wlr_xwayland_set_seat(xwayland, server.seat) end
            end,
            set_fullscreen = function(on) xs:set_fullscreen(on) end,
            close = function() xs:close() end,
            title = function() return wl.string(xs.title) end,
            app_id = function() return wl.string(xs.class) end,
        }
    end

    local function managed(xs, s)
        local w = nil
        local surface_scope = nil

        local function map()
            if w or xs.surface == nil then return end
            local tree = lib.wlr_scene_subsurface_tree_create(boring.layers.windows, xs.surface)
            w = boring.window.new(xs.surface, tree, impl(xs))
            w.tree.node:set_position(xs.x, xs.y)
            boring.window.map(w)
        end

        local function unmap()
            if not w then return end
            boring.window.destroy(w)
            w.tree.node:destroy()
            w = nil
        end

        s:listen(xs.events.associate, function()
            surface_scope = s:child("xwayland surface")
            surface_scope:listen(xs.surface.events.map, map)
            surface_scope:listen(xs.surface.events.unmap, unmap)
            surface_scope:listen(xs.surface.events.commit, function()
                if w then
                    boring.layout.position_window(w)
                    boring.events:emit("window:commit", w)
                end
            end)
        end)
        s:listen(xs.events.dissociate, function()
            unmap()
            if surface_scope then surface_scope:close() end
            surface_scope = nil
        end)
        s:listen(xs.events.request_configure, function(ev)
            xs:configure(ev.x, ev.y, ev.width, ev.height)
            if w and not w.monitor then w.tree.node:set_position(ev.x, ev.y) end
        end, "struct wlr_xwayland_surface_configure_event")
        s:listen(xs.events.request_fullscreen, function()
            if w then
                if xs.fullscreen then boring.layout.enter_fullscreen(w) else boring.layout.exit_fullscreen(w.monitor) end
            end
        end)
        s:listen(xs.events.request_activate, function() if w then boring.focus(w) end end)
        s:listen(xs.events.request_move, function() if w then boring.begin_move(w) end end)
        s:listen(xs.events.request_resize, function(ev)
            if w then boring.begin_resize(w, ev.edges) end
        end, "struct wlr_xwayland_resize_event")
        s:listen(xs.events.set_title, function() if w then boring.events:emit("window:title", w) end end)
        s:listen(xs.events.set_class, function() if w then boring.events:emit("window:title", w) end end)
        return unmap
    end

    local function unmanaged(xs, s)
        local scene_surface = nil
        local surface_scope = nil
        local function place()
            if scene_surface then scene_surface.buffer.node:set_position(xs.x, xs.y) end
        end
        local function unmap()
            if scene_surface then
                scene_surface.buffer.node:destroy()
                scene_surface = nil
            end
        end
        s:listen(xs.events.associate, function()
            surface_scope = s:child("xwayland unmanaged surface")
            surface_scope:listen(xs.surface.events.map, function()
                scene_surface = lib.wlr_scene_surface_create(boring.layers.unmanaged, xs.surface)
                place()
            end)
            surface_scope:listen(xs.surface.events.unmap, unmap)
        end)
        s:listen(xs.events.dissociate, function()
            unmap()
            if surface_scope then surface_scope:close() end
            surface_scope = nil
        end)
        s:listen(xs.events.set_geometry, place)
        s:listen(xs.events.request_configure, function(ev)
            xs:configure(ev.x, ev.y, ev.width, ev.height)
        end, "struct wlr_xwayland_surface_configure_event")
        return unmap
    end

    scope:listen(xwayland.events.new_surface, function(xs)
        local s = scope:child("xwayland window")
        local cleanup = (xs.override_redirect and unmanaged or managed)(xs, s)
        s:listen(xs.events.destroy, function()
            cleanup()
            s:close()
        end)
    end, "struct wlr_xwayland_surface")

    scope:listen(xwayland.events.ready, function()
        lib.wlr_xwayland_set_seat(xwayland, server.seat)
    end)

    local display = wl.string(xwayland.display_name)
    if display then C.setenv("DISPLAY", display, 1) end
    boring.implement("xwayland_shell_v1", "xwayland_surface_v1")
end

return plugin
