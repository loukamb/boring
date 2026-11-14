-- wlr-layer-shell: panels, wallpapers, launchers, lock screens.
--
-- Layer surfaces are arranged per output: wlroots places each one and
-- shrinks the usable area by its exclusive zone. The result is stored as
-- output.usable so layouts keep windows clear of panels.

local wl = require("shared.wl")
local layout = require("compositor.layout")
local windows = require("compositor.windows")

local ffi, lib, C = wl.ffi, wl.lib, wl.C
local addr = wl.addr

local layer_shell = {}

local LAYERS = {
    [C.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND] = "background",
    [C.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM] = "bottom",
    [C.ZWLR_LAYER_SHELL_V1_LAYER_TOP] = "top",
    [C.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY] = "overlay",
}
-- Exclusive zones of upper layers apply first.
local ARRANGE_ORDER = {
    C.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, C.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
    C.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM, C.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
}

local function output_record(server, wlr_output)
    for _, o in ipairs(server.outputs) do
        if o.wlr == wlr_output then return o end
    end
end

--- Position every layer surface on an output and recompute its usable area.
function layer_shell.arrange(server, o)
    local b = o:box()
    local full = ffi.new("struct wlr_box", { b.x, b.y, b.width, b.height })
    local usable = ffi.new("struct wlr_box", { b.x, b.y, b.width, b.height })
    for _, layer in ipairs(ARRANGE_ORDER) do
        for _, ls in ipairs(server.layer_surfaces) do
            local surface = ls.wlr
            if surface.output == o.wlr and surface.current.layer == layer and surface.initialized then
                lib.wlr_scene_layer_surface_v1_configure(ls.scene, full, usable)
            end
        end
    end
    local old = o.usable
    o.usable = { x = usable.x, y = usable.y, width = usable.width, height = usable.height }
    if not old or old.x ~= usable.x or old.y ~= usable.y
        or old.width ~= usable.width or old.height ~= usable.height then
        layout.usable_area_changed(server, o)
    end
end

-- Exclusive keyboard interactivity (lock screens, launchers) takes the keyboard.
local function update_keyboard_focus(server)
    local exclusive = nil
    for _, ls in ipairs(server.layer_surfaces) do
        local s = ls.wlr
        if ls.mapped and s.current.keyboard_interactive == C.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE
            and s.current.layer >= C.ZWLR_LAYER_SHELL_V1_LAYER_TOP then
            exclusive = ls
        end
    end
    local was = server.exclusive_focus
    server.exclusive_focus = exclusive
    if exclusive then
        local seat = server.seat
        local kb = lib.wlr_seat_get_keyboard(seat)
        if kb ~= nil then
            seat:keyboard_notify_enter(exclusive.wlr.surface, kb.keycodes, kb.num_keycodes, kb.modifiers)
        else
            seat:keyboard_notify_enter(exclusive.wlr.surface, nil, 0, nil)
        end
    elseif was then
        windows.restore_keyboard(server)
    end
end

local function new_surface(server, surface)
    if surface.output == nil then
        local o = server.outputs[1]
        if not o then
            surface:destroy()
            return
        end
        surface.output = o.wlr
    end
    local tree = server.layers[LAYERS[surface.pending.layer] or "background"]
    local scene = lib.wlr_scene_layer_surface_v1_create(tree, surface)
    local ls = { wlr = surface, scene = scene, mapped = false, scope = server.scope:child("layer surface") }
    table.insert(server.layer_surfaces, ls)
    server.popup_parents[addr(surface.surface)] = scene.tree

    local function arrange()
        local o = output_record(server, surface.output)
        if o then layer_shell.arrange(server, o) end
    end

    ls.scope:listen(surface.surface.events.commit, function()
        if not surface.initialized then return end
        -- Layer changes move the surface to another scene tree.
        local want = server.layers[LAYERS[surface.current.layer]]
        if want and scene.tree.node.parent ~= want then
            scene.tree.node:reparent(want)
        end
        if surface.initial_commit or surface.current.committed ~= 0 then
            arrange()
        end
    end)
    ls.scope:listen(surface.surface.events.map, function()
        ls.mapped = true
        arrange()
        update_keyboard_focus(server)
    end)
    ls.scope:listen(surface.surface.events.unmap, function()
        ls.mapped = false
        arrange()
        update_keyboard_focus(server)
    end)
    ls.scope:listen(surface.events.destroy, function()
        for i, x in ipairs(server.layer_surfaces) do
            if x == ls then table.remove(server.layer_surfaces, i) break end
        end
        server.popup_parents[addr(surface.surface)] = nil
        ls.scope:close()
        if server.exclusive_focus == ls then update_keyboard_focus(server) end
        arrange()
    end)
end

function layer_shell.setup(server)
    server.layer_surfaces = {}
    server.popup_parents = server.popup_parents or {}
    local shell = lib.wlr_layer_shell_v1_create(server.display, 4)
    server.scope:listen(shell.events.new_surface, function(surface)
        new_surface(server, surface)
    end, "struct wlr_layer_surface_v1")

    -- Outputs need arranging when they appear or change size.
    server.events:on("output:add", function(o) layer_shell.arrange(server, o) end)
    server.events:on("output:change", function(o) layer_shell.arrange(server, o) end)

    return { "zwlr_layer_shell_v1", "zwlr_layer_surface_v1" }
end

return layer_shell
