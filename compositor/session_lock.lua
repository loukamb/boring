-- ext-session-lock: screen lockers (swaylock, gtklock, ...).
--
-- While locked, every output is covered by an opaque rectangle in the "lock"
-- scene layer with the locker's surface on top, compositor shortcuts are
-- off, and only lock surfaces get keyboard focus. If the locker dies without
-- unlocking, the session stays locked until a new locker takes over.

local ffi = require("ffi")
local wl = require("shared.wl")
local log = require("shared.log")
local windows = require("compositor.windows")

local lib = wl.lib

local session_lock = {}

local BLANK = ffi.new("float[4]", { 0, 0, 0, 1 })

local function focus_surface(server, surface)
    local seat = server.seat
    local kb = lib.wlr_seat_get_keyboard(seat)
    if kb ~= nil then
        seat:keyboard_notify_enter(surface, kb.keycodes, kb.num_keycodes, kb.modifiers)
    else
        seat:keyboard_notify_enter(surface, nil, 0, nil)
    end
end

-- Cover each output with an opaque rectangle.
local function blank_outputs(server, state)
    for _, o in ipairs(server.outputs) do
        if not state.blanks[o] then
            local b = o:box()
            local rect = lib.wlr_scene_rect_create(server.layers.lock, b.width, b.height, BLANK)
            rect.node:set_position(b.x, b.y)
            state.blanks[o] = rect
        end
    end
end

local function unlock(server)
    local state = server.locked
    if not state then return end
    state.scope:close()
    for _, rect in pairs(state.blanks) do rect.node:destroy() end
    server.locked = nil
    windows.restore_keyboard(server)
    log.info("session unlocked")
end

-- Start locking (or let a new locker take over a session whose locker died).
local function adopt_lock(server, lock)
    local state = server.locked
    if not state then
        state = { blanks = {}, scope = server.scope:child("session lock") }
        server.locked = state
        lib.wlr_seat_keyboard_notify_clear_focus(server.seat)
        log.info("session locked")
    end
    blank_outputs(server, state)

    -- Listeners on this lock object live exactly as long as it does.
    local scope = state.scope:child("lock")
    state.active = lock

    scope:listen(lock.events.new_surface, function(ls)
        local o
        for _, x in ipairs(server.outputs) do
            if x.wlr == ls.output then o = x end
        end
        if not o then return end
        local b = o:box()
        local tree = lib.wlr_scene_subsurface_tree_create(server.layers.lock, ls.surface)
        tree.node:set_position(b.x, b.y)
        lib.wlr_session_lock_surface_v1_configure(ls, b.width, b.height)
        local surface_scope = scope:child("lock surface")
        surface_scope:listen(ls.surface.events.map, function() focus_surface(server, ls.surface) end)
        surface_scope:listen(ls.events.destroy, function() surface_scope:close() end)
    end, "struct wlr_session_lock_surface_v1")

    scope:listen(lock.events.unlock, function() unlock(server) end)

    scope:listen(lock.events.destroy, function()
        scope:close()
        if server.locked == state and state.active == lock then
            state.active = nil
            log.warn("screen locker exited without unlocking; staying locked")
        end
    end)

    -- Outputs are blanked from now on; it's safe to say we're locked.
    lock:send_locked()
end

function session_lock.setup(server)
    local manager = lib.wlr_session_lock_manager_v1_create(server.display)
    server.scope:listen(manager.events.new_lock, function(lock)
        if server.locked and server.locked.active ~= nil then
            -- Already locked by a live locker: refuse the second one.
            lock:destroy()
            return
        end
        adopt_lock(server, lock)
    end, "struct wlr_session_lock_v1")

    -- New outputs appearing while locked get blanked too.
    server.events:on("output:add", function()
        if server.locked then blank_outputs(server, server.locked) end
    end)

    return { "ext_session_lock_manager_v1", "ext_session_lock_v1", "ext_session_lock_surface_v1" }
end

return session_lock
