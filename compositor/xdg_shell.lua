-- xdg-shell: toplevels become windows, popups attach to their parent's scene
-- tree, and xdg-decoration negotiates server-side decorations.
--
-- Requests from the client (move, resize, fullscreen, maximize, minimize)
-- become window:request_* events; plugins decide what they mean.

local bit = require("bit")
local wl = require("shared.wl")
local window = require("compositor.window")
local windows = require("compositor.windows")

local ffi, lib, C = wl.ffi, wl.lib, wl.C
local addr = wl.addr

local xdg_shell = {}

local scene_tree_ptr = ffi.typeof("struct wlr_scene_tree *")

-- Role implementation for an xdg toplevel (see compositor/window.lua).
local function toplevel_impl(xt)
    local base = xt.base
    return {
        role = "toplevel",
        geometry = function()
            local g = base.geometry
            if g.width > 0 then
                return g.x, g.y, g.width, g.height
            end
            local current = base.surface.current
            return 0, 0, current.width, current.height
        end,
        set_size = function(width, height)
            if base.initialized then xt:set_size(width, height) end
        end,
        set_activated = function(on)
            if base.initialized then xt:set_activated(on) end
        end,
        set_fullscreen = function(on)
            if base.initialized then xt:set_fullscreen(on) end
        end,
        set_maximized = function(on)
            if base.initialized then xt:set_maximized(on) end
        end,
        set_tiled = function(on)
            if base.initialized then
                xt:set_tiled(on and bit.bor(C.WLR_EDGE_TOP, C.WLR_EDGE_BOTTOM, C.WLR_EDGE_LEFT, C.WLR_EDGE_RIGHT) or 0)
            end
        end,
        close = function() xt:send_close() end,
        title = function() return wl.string(xt.title) end,
        app_id = function() return wl.string(xt.app_id) end,
    }
end

local function new_toplevel(server, xt)
    local base = xt.base
    local tree = lib.wlr_scene_xdg_surface_create(server.layers.windows, base)
    base.data = tree

    local w = window.new(server, base.surface, tree, toplevel_impl(xt))
    windows.register(server, w)
    local scope = server.scope:child("xdg toplevel")
    local surface_events = base.surface.events

    scope:listen(surface_events.map, function() windows.map(server, w) end)
    scope:listen(surface_events.unmap, function() windows.unmap(server, w) end)

    scope:listen(surface_events.commit, function()
        if base.initial_commit then
            -- Let the client pick its size; plugins configure it on map.
            xt:set_size(0, 0)
            xt:set_wm_capabilities(bit.bor(C.WLR_XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN,
                C.WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE, C.WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE))
        elseif w.mapped then
            server.events:emit("window:commit", w)
        end
    end)

    scope:listen(xt.events.destroy, function()
        windows.unmap(server, w)
        windows.unregister(server, w)
        scope:close()
    end)

    -- Every request is answered with a configure, even if nothing changed.
    local function configure()
        if base.initialized then lib.wlr_xdg_surface_schedule_configure(base) end
    end
    local events = server.events

    scope:listen(xt.events.request_move, function()
        if w.mapped then events:emit("window:request_move", w) end
    end)
    scope:listen(xt.events.request_resize, function(event)
        if w.mapped then events:emit("window:request_resize", w, event.edges) end
    end, "struct wlr_xdg_toplevel_resize_event")
    scope:listen(xt.events.request_fullscreen, function()
        if w.mapped then events:emit("window:request_fullscreen", w, xt.requested.fullscreen) end
        configure()
    end)
    scope:listen(xt.events.request_maximize, function()
        if w.mapped then events:emit("window:request_maximize", w, xt.requested.maximized) end
        configure()
    end)
    scope:listen(xt.events.request_minimize, function()
        if w.mapped then events:emit("window:request_minimize", w) end
    end)

    scope:listen(xt.events.set_title, function() server.events:emit("window:title", w) end)
    scope:listen(xt.events.set_app_id, function() server.events:emit("window:title", w) end)
end

-- Scene tree to put a popup under: the parent xdg surface's tree, or a
-- layer surface's (registered by compositor/layer_shell.lua).
local function popup_parent_tree(server, popup)
    local parent = lib.wlr_xdg_surface_try_from_wlr_surface(popup.parent)
    if parent ~= nil and parent.data ~= nil then
        return ffi.cast(scene_tree_ptr, parent.data)
    end
    return server.popup_parents[addr(popup.parent)]
end

local function new_popup(server, popup)
    local parent_tree = popup_parent_tree(server, popup)
    if parent_tree == nil then return end
    local base = popup.base
    local tree = lib.wlr_scene_xdg_surface_create(parent_tree, base)
    base.data = tree

    local scope = server.scope:child("xdg popup")
    scope:listen(base.surface.events.commit, function()
        if not base.initial_commit then return end
        -- Keep the popup on the output its parent is on.
        local px, py = parent_tree.node.x, parent_tree.node.y
        local lx, ly = ffi.new("int[1]"), ffi.new("int[1]")
        if lib.wlr_scene_node_coords(parent_tree.node, lx, ly) then
            px, py = lx[0], ly[0]
        end
        local o = require("compositor.output").at(server, px, py) or server.outputs[1]
        if o then
            local b = o:box()
            local box = ffi.new("struct wlr_box", { b.x - px, b.y - py, b.width, b.height })
            lib.wlr_xdg_popup_unconstrain_from_box(popup, box)
        end
        lib.wlr_xdg_surface_schedule_configure(base)
    end)
    scope:listen(popup.events.destroy, function() scope:close() end)
end

-- Prefer server-side decorations: windows get borders/title bars from plugins.
local function new_decoration(server, decoration)
    local function apply()
        decoration:set_mode(C.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE)
    end
    -- set_mode schedules a configure, only allowed after the initial commit.
    local base = decoration.toplevel.base
    if base.initialized then
        apply()
        return
    end
    local scope = server.scope:child("xdg decoration")
    scope:listen(base.surface.events.commit, function()
        if base.initial_commit then
            apply()
            scope:close()
        end
    end)
    scope:listen(decoration.events.destroy, function() scope:close() end)
end

function xdg_shell.setup(server)
    server.popup_parents = server.popup_parents or {}
    server.xdg_shell = lib.wlr_xdg_shell_create(server.display, 6)
    server.scope:listen(server.xdg_shell.events.new_toplevel, function(xt)
        new_toplevel(server, xt)
    end, "struct wlr_xdg_toplevel")
    server.scope:listen(server.xdg_shell.events.new_popup, function(popup)
        new_popup(server, popup)
    end, "struct wlr_xdg_popup")

    local decorations = lib.wlr_xdg_decoration_manager_v1_create(server.display)
    server.scope:listen(decorations.events.new_toplevel_decoration, function(decoration)
        new_decoration(server, decoration)
    end, "struct wlr_xdg_toplevel_decoration_v1")

    return { "xdg_wm_base", "xdg_surface", "xdg_toplevel", "xdg_popup", "xdg_positioner",
        "zxdg_decoration_manager_v1", "zxdg_toplevel_decoration_v1" }
end

return xdg_shell
