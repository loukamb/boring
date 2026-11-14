-- Pointer: cursor motion, buttons, scrolling, mouse shortcuts and pointer
-- grabs.
--
-- A grab takes the pointer until it ends: { motion = fn(x, y), button =
-- fn(button, pressed) -> true to end, finish = fn(cancelled), cursor, window }.
-- Without a `button` handler, releasing a button ends it. Free move and
-- resize (`boring.begin_move`, `boring.begin_resize`) are grabs; layouts use
-- them or start their own. Core never decides to move a window: mouse
-- shortcuts and client requests become window:request_move/resize events.

local bit = require("bit")
local wl = require("shared.wl")
local log = require("shared.log")
local state = require("compositor.state")
local windows = require("compositor.windows")
local shortcuts = require("compositor.shortcuts")

local ffi, lib, C = wl.ffi, wl.lib, wl.C

local pointer = {}

local DOUBLE_CLICK_MS = 300
local DOUBLE_CLICK_DISTANCE = 5

local function set_cursor(server, name)
    lib.wlr_cursor_set_xcursor(server.cursor, server.cursor_mgr, name)
end
pointer.set_cursor = set_cursor
pointer.resize_cursor = shortcuts.resize_cursor

--------------------------------------------------------------------------------
-- Grabs
--------------------------------------------------------------------------------

local function call(what, fn, ...)
    local ok, err = xpcall(fn, debug.traceback, ...)
    if not ok then log.error("pointer grab %s: %s", what, tostring(err)) end
    return ok and err
end

--- End the current grab (if any). `cancelled` is passed to its finish.
function pointer.end_grab(server, cancelled)
    local grab = server.grab
    if not grab then return end
    server.grab = nil
    lib.wlr_seat_pointer_clear_focus(server.seat)
    set_cursor(server, "default")
    if grab.finish then call("finish", grab.finish, cancelled or false) end
end

--- Take the pointer (see the top of this file). Ends any grab in progress.
--- Returns a function that ends this grab.
function pointer.grab(server, handlers)
    pointer.end_grab(server, true)
    server.grab = handlers
    lib.wlr_seat_pointer_clear_focus(server.seat)
    set_cursor(server, handlers.cursor or "default")
    return function()
        if server.grab == handlers then pointer.end_grab(server) end
    end
end

--- Move a window with the pointer until the button is released.
function pointer.begin_move(server, w)
    if not w or not w.mapped then return end
    local cursor = server.cursor
    local x, y = w:position()
    local dx, dy = cursor.x - x, cursor.y - y
    pointer.grab(server, {
        window = w,
        cursor = "grabbing",
        motion = function(cx, cy) w:set_position(cx - dx, cy - dy) end,
    })
end

--- Resize a window by its `edges` (WLR_EDGE_*) until the button is released.
function pointer.begin_resize(server, w, edges)
    if not w or not w.mapped then return end
    local cursor = server.cursor
    local b = w:bounds()
    local edge_x = bit.band(edges, C.WLR_EDGE_RIGHT) ~= 0 and b.x + b.width or b.x
    local edge_y = bit.band(edges, C.WLR_EDGE_BOTTOM) ~= 0 and b.y + b.height or b.y
    local dx, dy = cursor.x - edge_x, cursor.y - edge_y
    pointer.grab(server, {
        window = w,
        cursor = shortcuts.resize_cursor(edges),
        motion = function(cx, cy)
            local left, top, right, bottom = b.x, b.y, b.x + b.width, b.y + b.height
            local ex, ey = cx - dx, cy - dy
            if bit.band(edges, C.WLR_EDGE_TOP) ~= 0 then
                top = math.min(ey, bottom - 1)
            elseif bit.band(edges, C.WLR_EDGE_BOTTOM) ~= 0 then
                bottom = math.max(ey, top + 1)
            end
            if bit.band(edges, C.WLR_EDGE_LEFT) ~= 0 then
                left = math.min(ex, right - 1)
            elseif bit.band(edges, C.WLR_EDGE_RIGHT) ~= 0 then
                right = math.max(ex, left + 1)
            end
            local g = w:geometry()
            w:set_position(left - g.x, top - g.y)
            w:set_size(right - left, bottom - top)
        end,
    })
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function motion(server, time_msec)
    server.on_activity()
    local grab = server.grab
    if grab then
        if grab.motion then call("motion", grab.motion, server.cursor.x, server.cursor.y) end
        return
    end
    local seat = server.seat
    local w, surface, sx, sy = windows.at(server, server.cursor.x, server.cursor.y)
    if surface ~= nil then
        seat:pointer_notify_enter(surface, sx, sy)
        seat:pointer_notify_motion(time_msec, sx, sy)
    else
        set_cursor(server, "default")
        lib.wlr_seat_pointer_clear_focus(seat)
    end
end

-- Edges for a modifier+drag resize: the quadrant of the window under the cursor.
local function quadrant_edges(w, x, y)
    local b = w:bounds()
    local edges = x < b.x + b.width / 2 and C.WLR_EDGE_LEFT or C.WLR_EDGE_RIGHT
    return bit.bor(edges, y < b.y + b.height / 2 and C.WLR_EDGE_TOP or C.WLR_EDGE_BOTTOM)
end

local function run_action(name, action, ...)
    local ok, err = xpcall(action, debug.traceback, ...)
    if not ok then
        log.error("shortcut %s failed: %s", name, tostring(err))
    end
end

-- Built-in string actions for mouse shortcuts (see config/action/window.lua).
-- Window actions become requests, as if the client asked.
local function mouse_action(server, s, w)
    local action = s.action
    if type(action) == "function" then
        run_action(s.name, action, w)
    elseif action == "move_window" or action == "drag_window" then
        if w then
            windows.focus(server, w)
            server.events:emit("window:request_move", w)
        end
    elseif action == "resize_window" then
        if w then
            windows.focus(server, w)
            server.events:emit("window:request_resize", w, quadrant_edges(w, server.cursor.x, server.cursor.y))
        end
    elseif action == "fullscreen" then
        if w then server.events:emit("window:request_fullscreen", w, not w.fullscreen) end
    else
        log.warn("unknown mouse action %s for %s", tostring(action), s.name)
    end
end

local function is_double_click(click, x, y, button, time)
    local double = click.button == button and time - click.time < DOUBLE_CLICK_MS
        and math.abs(x - click.x) < DOUBLE_CLICK_DISTANCE
        and math.abs(y - click.y) < DOUBLE_CLICK_DISTANCE
    if double then
        -- A third click starts over rather than counting as another double.
        click.time, click.button = 0, 0
    else
        click.time, click.x, click.y, click.button = time, x, y, button
    end
    return double
end

local function button(server, event)
    server.on_activity()
    local seat = server.seat
    local cx, cy = server.cursor.x, server.cursor.y

    local pressed = event.state == C.WL_POINTER_BUTTON_STATE_PRESSED
    local grab = server.grab
    if grab then
        -- The seat has no pointer focus during a grab; this only keeps its
        -- button state right.
        seat:pointer_notify_button(event.time_msec, event.button, event.state)
        if grab.button then
            if call("button", grab.button, event.button, pressed) == true then pointer.end_grab(server) end
        elseif not pressed then
            pointer.end_grab(server)
        end
        return
    end

    if not pressed then
        seat:pointer_notify_button(event.time_msec, event.button, event.state)
        return
    end

    local w, surface, _, _, node = windows.at(server, cx, cy)
    local mods = server.modifiers or 0

    -- Clicks on decorations go to their handlers (boring.on_click).
    if surface == nil and node ~= nil then
        local handlers = server.click_handlers
        while node ~= nil do
            local handler = handlers[wl.addr(node)]
            if handler then
                if w then windows.focus(server, w) end
                run_action("click handler", handler, w, event.button)
                return
            end
            node = node.parent ~= nil and node.parent.node or nil
        end
    end
    local mice = server.mouse_shortcuts

    if is_double_click(server.click, cx, cy, event.button, event.time_msec) then
        local s = shortcuts.match_mouse(mice, mods, "double_click", event.button)
        if s then
            mouse_action(server, s, w)
            return
        end
    end

    local s = shortcuts.match_mouse(mice, mods, "drag", event.button)
    if s then
        mouse_action(server, s, w)
        return
    end

    seat:pointer_notify_button(event.time_msec, event.button, event.state)
    if w then
        windows.focus(server, w)
    end
end

local function axis(server, event)
    server.on_activity()
    if event.delta ~= 0 then
        local s = shortcuts.match_mouse(server.mouse_shortcuts, server.modifiers or 0, "scroll")
        if s and type(s.action) == "function" then
            run_action(s.name, s.action, event.delta < 0 and 1 or -1)
            return
        end
    end
    server.seat:pointer_notify_axis(event.time_msec, event.orientation, event.delta,
        event.delta_discrete, event.source, event.relative_direction)
end

--------------------------------------------------------------------------------
-- Devices
--------------------------------------------------------------------------------

local function configure_libinput(device, config)
    local dev = lib.wlr_libinput_get_device_handle(device)
    if dev == nil then return end
    if config.tap ~= nil and lib.libinput_device_config_tap_get_finger_count(dev) > 0 then
        lib.libinput_device_config_tap_set_enabled(dev,
            config.tap and C.LIBINPUT_CONFIG_TAP_ENABLED or C.LIBINPUT_CONFIG_TAP_DISABLED)
    end
    if config.acceleration ~= nil and lib.libinput_device_config_accel_is_available(dev) ~= 0 then
        lib.libinput_device_config_accel_set_speed(dev, math.max(-1, math.min(1, config.acceleration)))
    end
    if config.scroll and config.scroll.natural ~= nil
        and lib.libinput_device_config_scroll_has_natural_scroll(dev) ~= 0 then
        lib.libinput_device_config_scroll_set_natural_scroll_enabled(dev, config.scroll.natural and 1 or 0)
    end
    if config.handedness and lib.libinput_device_config_left_handed_is_available(dev) ~= 0 then
        lib.libinput_device_config_left_handed_set(dev, config.handedness == "left" and 1 or 0)
    end
end

function pointer.add_device(server, device)
    server.cursor:attach_input_device(device)
    if lib.wlr_input_device_is_libinput(device) then
        configure_libinput(device, state.resolve_mouse(wl.string(device.name)))
    end
end

function pointer.setup(server)
    server.cursor = lib.wlr_cursor_create()
    server.cursor:attach_output_layout(server.output_layout)
    server.cursor_mgr = lib.wlr_xcursor_manager_create(nil, 24)
    server.mouse_shortcuts = server.mouse_shortcuts or {}
    server.click_handlers = {}
    server.click = { time = 0, x = 0, y = 0, button = 0 }
    server.relative_pointer = lib.wlr_relative_pointer_manager_v1_create(server.display)

    local cursor, scope = server.cursor, server.scope
    scope:listen(cursor.events.motion, function(event)
        cursor:move(event.pointer.base, event.delta_x, event.delta_y)
        lib.wlr_relative_pointer_manager_v1_send_relative_motion(server.relative_pointer, server.seat,
            event.time_msec * 1000ULL, event.delta_x, event.delta_y, event.unaccel_dx, event.unaccel_dy)
        motion(server, event.time_msec)
    end, "struct wlr_pointer_motion_event")
    scope:listen(cursor.events.motion_absolute, function(event)
        cursor:warp_absolute(event.pointer.base, event.x, event.y)
        motion(server, event.time_msec)
    end, "struct wlr_pointer_motion_absolute_event")
    scope:listen(cursor.events.button, function(event) button(server, event) end,
        "struct wlr_pointer_button_event")
    scope:listen(cursor.events.axis, function(event) axis(server, event) end,
        "struct wlr_pointer_axis_event")
    scope:listen(cursor.events.frame, function() server.seat:pointer_notify_frame() end)

    -- Touchpad gestures go to the client under the pointer.
    local gestures = lib.wlr_pointer_gestures_v1_create(server.display)
    local function gesture(signal, ctype, send)
        scope:listen(signal, function(e)
            server.on_activity()
            send(e)
        end, ctype)
    end
    local seat = function() return server.seat end
    gesture(cursor.events.swipe_begin, "struct wlr_pointer_swipe_begin_event", function(e)
        lib.wlr_pointer_gestures_v1_send_swipe_begin(gestures, seat(), e.time_msec, e.fingers)
    end)
    gesture(cursor.events.swipe_update, "struct wlr_pointer_swipe_update_event", function(e)
        lib.wlr_pointer_gestures_v1_send_swipe_update(gestures, seat(), e.time_msec, e.dx, e.dy)
    end)
    gesture(cursor.events.swipe_end, "struct wlr_pointer_swipe_end_event", function(e)
        lib.wlr_pointer_gestures_v1_send_swipe_end(gestures, seat(), e.time_msec, e.cancelled)
    end)
    gesture(cursor.events.pinch_begin, "struct wlr_pointer_pinch_begin_event", function(e)
        lib.wlr_pointer_gestures_v1_send_pinch_begin(gestures, seat(), e.time_msec, e.fingers)
    end)
    gesture(cursor.events.pinch_update, "struct wlr_pointer_pinch_update_event", function(e)
        lib.wlr_pointer_gestures_v1_send_pinch_update(gestures, seat(), e.time_msec, e.dx, e.dy, e.scale, e.rotation)
    end)
    gesture(cursor.events.pinch_end, "struct wlr_pointer_pinch_end_event", function(e)
        lib.wlr_pointer_gestures_v1_send_pinch_end(gestures, seat(), e.time_msec, e.cancelled)
    end)
    gesture(cursor.events.hold_begin, "struct wlr_pointer_hold_begin_event", function(e)
        lib.wlr_pointer_gestures_v1_send_hold_begin(gestures, seat(), e.time_msec, e.fingers)
    end)
    gesture(cursor.events.hold_end, "struct wlr_pointer_hold_end_event", function(e)
        lib.wlr_pointer_gestures_v1_send_hold_end(gestures, seat(), e.time_msec, e.cancelled)
    end)

    return { "zwp_relative_pointer_manager_v1", "zwp_relative_pointer_v1",
        "zwp_pointer_gestures_v1", "zwp_pointer_gesture_swipe_v1", "zwp_pointer_gesture_pinch_v1",
        "zwp_pointer_gesture_hold_v1" }
end

pointer._private = {
    is_double_click = is_double_click,
    quadrant_edges = quadrant_edges,
}

return pointer
