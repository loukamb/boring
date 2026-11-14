-- Window bookkeeping: registration, map/unmap, keyboard focus, hit testing.
--
-- server.windows holds mapped windows, most recently focused first.
-- Hidden windows (a plugin called w:set_enabled(false)) don't get focus
-- when another window goes away or focus cycles.

local wl = require("shared.wl")

local ffi, lib, C = wl.ffi, wl.lib, wl.C
local addr = wl.addr

local windows = {}

function windows.register(server, w)
    server.surfaces[addr(w.surface)] = w
    server.trees[addr(w.tree)] = w
end

function windows.unregister(server, w)
    server.surfaces[addr(w.surface)] = nil
    server.trees[addr(w.tree)] = nil
end

--- The window a wlr_surface belongs to, if any.
function windows.from_surface(server, surface)
    if surface == nil then return nil end
    return server.surfaces[addr(surface)]
end

function windows.focused(server)
    return server.focused
end

local function remove(list, item)
    for i = 1, #list do
        if list[i] == item then
            table.remove(list, i)
            return true
        end
    end
    return false
end

--- Is the keyboard held by a lock screen or an exclusive layer surface?
function windows.keyboard_grabbed(server)
    return server.locked ~= nil or server.exclusive_focus ~= nil
end

local function keyboard_enter(server, surface)
    local seat = server.seat
    local kb = lib.wlr_seat_get_keyboard(seat)
    if kb ~= nil then
        seat:keyboard_notify_enter(surface, kb.keycodes, kb.num_keycodes, kb.modifiers)
    else
        seat:keyboard_notify_enter(surface, nil, 0, nil)
    end
end

--- Give a window keyboard focus and raise it.
function windows.focus(server, w)
    if w == nil or not w.mapped then return end
    local prev = server.focused
    if prev == w then
        w:raise()
        return
    end
    if prev then
        prev.activated = false
        prev.impl.set_activated(false)
    end

    server.focused = w
    w:set_urgent(false)
    w:raise()
    remove(server.windows, w)
    table.insert(server.windows, 1, w)
    w.activated = true
    w.impl.set_activated(true)
    -- A lock screen or exclusive layer surface keeps the keyboard.
    if not windows.keyboard_grabbed(server) then
        keyboard_enter(server, w.surface)
    end

    if prev then server.events:emit("window:blur", prev) end
    server.events:emit("window:focus", w)
end

--- Drop keyboard focus from windows (e.g. a layer surface takes it).
function windows.blur(server)
    local prev = server.focused
    if not prev then return end
    server.focused = nil
    prev.activated = false
    prev.impl.set_activated(false)
    lib.wlr_seat_keyboard_notify_clear_focus(server.seat)
    server.events:emit("window:blur", prev)
end

--- Re-send keyboard focus to the focused window (after a layer surface let go).
function windows.restore_keyboard(server)
    if server.focused then
        keyboard_enter(server, server.focused.surface)
    else
        lib.wlr_seat_keyboard_notify_clear_focus(server.seat)
    end
end

-- Without plugins, a new window opens at the origin of the output under
-- the cursor.
local function place(server, w)
    if w.impl.positioned then return end
    local cursor = server.cursor
    local o = cursor ~= nil and require("compositor.output").at(server, cursor.x, cursor.y)
        or server.outputs[1]
    if not o then return end
    local b, g = o:box(), w:geometry()
    w:set_position(b.x - g.x, b.y - g.y)
end

function windows.map(server, w)
    if w.mapped then return end
    w.mapped = true
    table.insert(server.windows, 1, w)
    place(server, w)
    server.events:emit("window:map", w)
    windows.focus(server, w)
end

-- The most recently focused visible window, other than `except`.
local function next_visible(server, except)
    for _, w in ipairs(server.windows) do
        if w ~= except and w:visible() then return w end
    end
end
windows.next_visible = next_visible

function windows.unmap(server, w)
    if not w.mapped then return end
    w.mapped = false
    local grab = server.grab
    if grab and grab.window == w then
        server.grab = nil
        if grab.finish then
            local ok, err = xpcall(grab.finish, debug.traceback, true)
            if not ok then require("shared.log").error("pointer grab: %s", tostring(err)) end
        end
    end
    remove(server.windows, w)
    server.events:emit("window:unmap", w)
    if server.focused == w then
        server.focused = nil
        w.activated = false
        server.events:emit("window:blur", w)
        local next_window = next_visible(server)
        if next_window then
            windows.focus(server, next_window)
        elseif not windows.keyboard_grabbed(server) then
            lib.wlr_seat_keyboard_notify_clear_focus(server.seat)
        end
    end
end

--- Focus the least recently focused visible window (simple alt-tab).
function windows.cycle(server)
    for i = #server.windows, 2, -1 do
        local w = server.windows[i]
        if w:visible() then
            windows.focus(server, w)
            return
        end
    end
end

local sx_out = ffi.new("double[1]")
local sy_out = ffi.new("double[1]")

--- What's under a point in layout coordinates.
--- Returns window (or nil), wlr_surface (or nil), surface-local x, y, and the
--- scene node hit (or nil). Decorations are scene nodes without a surface.
function windows.at(server, lx, ly)
    local node = server.scene.tree.node:at(lx, ly, sx_out, sy_out)
    if node == nil then
        return nil
    end
    local surface, sx, sy = nil, sx_out[0], sy_out[0]
    if node.type == C.WLR_SCENE_NODE_BUFFER then
        local scene_surface = lib.wlr_scene_surface_try_from_buffer(lib.wlr_scene_buffer_from_node(node))
        if scene_surface ~= nil then
            surface = scene_surface.surface
        end
    end

    local tree = node.parent
    while tree ~= nil do
        local w = server.trees[addr(tree)]
        if w then
            return w, surface, sx, sy, node
        end
        tree = tree.node.parent
    end
    return nil, surface, sx, sy, node
end

return windows
