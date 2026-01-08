-- services/input.lua - Input device management
-- Responsibility: wl_seat, wlr_cursor, keyboard handling, input device hotplug

local log = require("shared.log")
local wl = require("shared.wayland.server")
local proto = require("shared.wayland.registry")
local state = require("compositor.state")
local ffi = wl._ffi
local bit = wl.bit

local core_service = require("compositor.services.core")
local output_service = require("compositor.services.output")
local surface_service = require("compositor.services.surface")

local MOD_MAP = {
    Ctrl = wl.WLR_MODIFIER_CTRL,
    Control = wl.WLR_MODIFIER_CTRL,
    Alt = wl.WLR_MODIFIER_ALT,
    Shift = wl.WLR_MODIFIER_SHIFT,
    Mod1 = wl.WLR_MODIFIER_ALT,
    Mod2 = wl.WLR_MODIFIER_MOD2, -- Usually Num Lock
    Mod3 = wl.WLR_MODIFIER_MOD3, -- Usually unmapped (good for testing!)
    Mod4 = wl.WLR_MODIFIER_LOGO,
    Super = wl.WLR_MODIFIER_LOGO,
    Mod5 = wl.WLR_MODIFIER_MOD5,  -- Usually unmapped or ISO_Level3_Shift
    Hyper = wl.WLR_MODIFIER_MOD3, -- Alias for Mod3
}

local function parse_shortcut(shortcut_str)
    local parts = {}
    for part in shortcut_str:gmatch("[^+]+") do
        table.insert(parts, part)
    end

    local mods = 0
    local key_name = nil

    for i, part in ipairs(parts) do
        local trimmed = part:match("^%s*(.-)%s*$")
        if MOD_MAP[trimmed] then
            mods = bit.bor(mods, MOD_MAP[trimmed])
        else
            key_name = trimmed
        end
    end

    if not key_name then
        return nil, nil
    end

    local xkb_name = "XKB_KEY_" .. key_name
    local sym = wl[xkb_name]
    if not sym then
        local lower_name = key_name:lower()
        sym = wl["XKB_KEY_" .. lower_name]
    end
    if not sym and #key_name == 1 then
        sym = wl["XKB_KEY_" .. key_name:lower()]
    end

    return mods, sym
end

-- Mouse shortcut event types
local MOUSE_EVENT_DRAG = "drag"
local MOUSE_EVENT_SCROLL = "scroll"
local MOUSE_EVENT_DOUBLE_CLICK = "double_click"

-- Mouse button map for shortcut parsing
local MOUSE_BUTTON_MAP = {
    LeftMouseDrag = { event = MOUSE_EVENT_DRAG, button = 0x110 },       -- BTN_LEFT
    RightMouseDrag = { event = MOUSE_EVENT_DRAG, button = 0x111 },      -- BTN_RIGHT
    MiddleMouseDrag = { event = MOUSE_EVENT_DRAG, button = 0x112 },     -- BTN_MIDDLE
    Scroll = { event = MOUSE_EVENT_SCROLL, button = nil },
    DoubleClick = { event = MOUSE_EVENT_DOUBLE_CLICK, button = 0x110 }, -- BTN_LEFT
}

-- Parse a mouse shortcut string like "Ctrl+LeftMouseDrag" or "Shift+Scroll"
-- Returns: modifiers (number), event_type (string), button (number or nil)
local function parse_mouse_shortcut(shortcut_str)
    local parts = {}
    for part in shortcut_str:gmatch("[^+]+") do
        table.insert(parts, part:match("^%s*(.-)%s*$"))
    end

    local mods = 0
    local mouse_action = nil

    for _, part in ipairs(parts) do
        if MOD_MAP[part] then
            mods = bit.bor(mods, MOD_MAP[part])
        elseif MOUSE_BUTTON_MAP[part] then
            mouse_action = MOUSE_BUTTON_MAP[part]
        end
    end

    if not mouse_action then
        return nil, nil, nil
    end

    return mods, mouse_action.event, mouse_action.button
end

-- Check if a shortcut string is a mouse shortcut
local function is_mouse_shortcut(shortcut_str)
    for key, _ in pairs(MOUSE_BUTTON_MAP) do
        if shortcut_str:find(key) then
            return true
        end
    end
    return false
end

-- Cursor modes
local CURSOR_PASSTHROUGH = 0
local CURSOR_MOVE = 1
local CURSOR_RESIZE = 2

-- Double-click detection constants
local DOUBLE_CLICK_TIME_MS = 300
local DOUBLE_CLICK_DISTANCE = 5

-- Mouse button codes
local BTN_LEFT = 0x110
local BTN_RIGHT = 0x111
local BTN_MIDDLE = 0x112

local input_service = {
    -- Seat and cursor
    seat = nil,
    cursor = nil,
    cursor_mgr = nil,

    -- Keyboards
    keyboards = {},

    -- Mouse shortcuts (parsed from keyboard config shortcuts)
    -- Each entry: { modifiers = number, event = string, button = number, action = function }
    mouse_shortcuts = {},

    -- Interactive state (move/resize)
    cursor_mode = CURSOR_PASSTHROUGH,
    grabbed_surface = nil, -- Surface object being moved/resized
    grab_x = 0,
    grab_y = 0,
    grab_geobox = nil,
    resize_edges = 0,

    -- Double-click detection
    last_click_time = 0,
    last_click_x = 0,
    last_click_y = 0,
    last_click_button = 0,

    -- Current modifier state
    current_modifiers = 0,

    -- Listeners
    listeners = {},

    -- Local registry for listener data
    registry = wl.new_registry(),

    -- State
    initialized = false,
}

-- Find a matching mouse shortcut for the given event
-- Returns the action if found, nil otherwise
local function find_mouse_shortcut(modifiers, event_type, button)
    for _, shortcut in ipairs(input_service.mouse_shortcuts) do
        if shortcut.modifiers == modifiers and
            shortcut.event == event_type and
            (shortcut.button == nil or shortcut.button == button) then
            return shortcut.action, shortcut.shortcut_str
        end
    end
    return nil, nil
end

-- Helper to set listener data
local function set_listener_data(listener, data)
    input_service.registry:set(listener, data)
end

-- Helper to get listener data
local function get_listener_data(listener)
    return input_service.registry:get(listener)
end

--------------------------------------------------------------------------------
-- Keyboard Handling
--------------------------------------------------------------------------------

-- Handle keyboard modifier events
local function keyboard_handle_modifiers(listener, data)
    local keyboard = get_listener_data(listener)
    if not keyboard then return end

    wl.roots.seat_set_keyboard(input_service.seat, keyboard.wlr_keyboard)
    wl.roots.seat_keyboard_notify_modifiers(input_service.seat, keyboard.wlr_keyboard.modifiers)

    -- Track current modifier state for mouse handlers
    input_service.current_modifiers = wl.roots.keyboard_get_modifiers(keyboard.wlr_keyboard)
end

local function handle_config_shortcuts(keyboard, modifiers, sym)
    if not keyboard.shortcuts then
        return false
    end

    for shortcut_str, callback in pairs(keyboard.shortcuts) do
        local req_mods, req_sym = parse_shortcut(shortcut_str)
        if req_sym and req_sym == sym and modifiers == req_mods then
            if type(callback) == "function" then
                local ok, err = pcall(callback)
                if not ok then
                    log.error("Shortcut callback error: %s", tostring(err))
                else
                end
                return true
            else
                log.warn("Shortcut callback is not a function: %s", type(callback))
            end
        end
    end
    return false
end

local function handle_keybinding(keyboard, modifiers, sym)
    if handle_config_shortcuts(keyboard, modifiers, sym) then
        return true
    end

    -- Escape without modifiers exits fullscreen mode
    if sym == wl.XKB_KEY_Escape and modifiers == 0 then
        local layout_service = require("compositor.services.layout")
        local monitor_state = layout_service:get_primary_monitor_state()
        if monitor_state and layout_service:is_fullscreen(monitor_state) then
            layout_service:exit_fullscreen(monitor_state)
            return true
        end
    end

    if bit.band(modifiers, wl.WLR_MODIFIER_ALT) ~= 0 then
        if sym == wl.XKB_KEY_Escape then
            core_service:terminate()
            return true
        elseif sym == wl.XKB_KEY_F1 then
            surface_service:cycle_windows()
            return true
        end
    end
    return false
end

local function keyboard_handle_key(listener, data)
    local keyboard = get_listener_data(listener)
    if not keyboard then return end

    local event = ffi.cast("struct wlr_keyboard_key_event*", data)
    local seat = input_service.seat

    local keycode = event.keycode + 8

    local syms = ffi.new("const xkb_keysym_t*[1]")
    local nsyms = wl.xkb.state_key_get_syms(keyboard.wlr_keyboard.xkb_state, keycode, syms)

    local handled = false
    local modifiers = wl.roots.keyboard_get_modifiers(keyboard.wlr_keyboard)

    if event.state == wl.WL_KEYBOARD_KEY_STATE_PRESSED then
        for i = 0, nsyms - 1 do
            if handle_keybinding(keyboard, modifiers, syms[0][i]) then
                handled = true
                break
            end
        end
    end

    if not handled then
        wl.roots.seat_set_keyboard(seat, keyboard.wlr_keyboard)
        wl.roots.seat_keyboard_notify_key(seat, event.time_msec, event.keycode, event.state)
    end
end

-- Handle keyboard destruction
local function keyboard_handle_destroy(listener, data)
    local keyboard = get_listener_data(listener)
    if not keyboard then return end

    for i, kb in ipairs(input_service.keyboards) do
        if kb == keyboard then
            table.remove(input_service.keyboards, i)
            break
        end
    end
end

local function server_new_keyboard(device)
    local wlr_keyboard = wl.roots.keyboard_from_input_device(device)
    local device_name = ffi.string(device.name)

    local config = state.resolve_keyboard(device_name)

    -- Separate keyboard and mouse shortcuts
    local keyboard_shortcuts = {}
    local all_shortcuts = config.shortcuts or {}

    for shortcut_str, action in pairs(all_shortcuts) do
        if is_mouse_shortcut(shortcut_str) then
            -- Parse and store mouse shortcut
            local mods, event_type, button = parse_mouse_shortcut(shortcut_str)
            if event_type then
                table.insert(input_service.mouse_shortcuts, {
                    modifiers = mods,
                    event = event_type,
                    button = button,
                    action = action,
                    shortcut_str = shortcut_str,
                })
            end
        else
            -- Keep keyboard shortcuts
            keyboard_shortcuts[shortcut_str] = action
        end
    end

    local keyboard = {
        wlr_keyboard = wlr_keyboard,
        device_name = device_name,
        shortcuts = keyboard_shortcuts,
    }

    local context = wl.xkb.context_new(wl.XKB_CONTEXT_NO_FLAGS)

    local xkb_names = nil
    if config.xkb and (config.xkb.layout or config.xkb.options or config.xkb.model or config.xkb.variant) then
        xkb_names = ffi.new("struct xkb_rule_names")
        if config.xkb.rules then
            xkb_names.rules = config.xkb.rules
        end
        if config.xkb.model then
            xkb_names.model = config.xkb.model
        end
        if config.xkb.layout then
            xkb_names.layout = config.xkb.layout
        end
        if config.xkb.variant then
            xkb_names.variant = config.xkb.variant
        end
        if config.xkb.options then
            xkb_names.options = config.xkb.options
        end
    end

    local keymap = wl.xkb.keymap_new_from_names(context, xkb_names, wl.XKB_KEYMAP_COMPILE_NO_FLAGS)
    wl.roots.keyboard_set_keymap(wlr_keyboard, keymap)
    wl.xkb.keymap_unref(keymap)
    wl.xkb.context_unref(context)

    local repeat_rate = 30
    local repeat_delay = 300
    if config["repeat"] then
        repeat_rate = config["repeat"].rate or repeat_rate
        repeat_delay = config["repeat"].delay or repeat_delay
    end
    wl.roots.keyboard_set_repeat_info(wlr_keyboard, repeat_rate, repeat_delay)

    keyboard.modifiers_listener = wl.create_listener(keyboard_handle_modifiers)
    set_listener_data(keyboard.modifiers_listener, keyboard)
    wl.signal_add(wlr_keyboard.events.modifiers, keyboard.modifiers_listener)

    keyboard.key_listener = wl.create_listener(keyboard_handle_key)
    set_listener_data(keyboard.key_listener, keyboard)
    wl.signal_add(wlr_keyboard.events.key, keyboard.key_listener)

    keyboard.destroy_listener = wl.create_listener(keyboard_handle_destroy)
    set_listener_data(keyboard.destroy_listener, keyboard)
    wl.signal_add(device.events.destroy, keyboard.destroy_listener)

    wl.roots.seat_set_keyboard(input_service.seat, wlr_keyboard)
    table.insert(input_service.keyboards, keyboard)
end

local function configure_libinput_pointer(device, config)
    local libinput_device = wl.roots.libinput_get_device_handle(device)
    if libinput_device == nil or libinput_device == ffi.NULL then
        return false
    end

    if config.tap ~= nil then
        local has_tap = wl.libinput.device_config_tap_get_finger_count(libinput_device)
        if has_tap > 0 then
            local tap_state = config.tap and wl.LIBINPUT_CONFIG_TAP_ENABLED or wl.LIBINPUT_CONFIG_TAP_DISABLED
            wl.libinput.device_config_tap_set_enabled(libinput_device, tap_state)
        end
    end

    if config.acceleration ~= nil then
        local has_accel = wl.libinput.device_config_accel_is_available(libinput_device)
        if has_accel ~= 0 then
            local speed = math.max(-1, math.min(1, config.acceleration))
            wl.libinput.device_config_accel_set_speed(libinput_device, speed)
        end
    end

    if config.scroll and config.scroll.natural ~= nil then
        local has_natural = wl.libinput.device_config_scroll_has_natural_scroll(libinput_device)
        if has_natural ~= 0 then
            wl.libinput.device_config_scroll_set_natural_scroll_enabled(libinput_device, config.scroll.natural and 1 or 0)
        end
    end

    if config.handedness then
        local has_handed = wl.libinput.device_config_left_handed_is_available(libinput_device)
        if has_handed ~= 0 then
            local left_handed = config.handedness == "left" and 1 or 0
            wl.libinput.device_config_left_handed_set(libinput_device, left_handed)
        end
    end

    return true
end

local function server_new_pointer(device)
    local device_name = ffi.string(device.name)
    local config = state.resolve_mouse(device_name)

    wl.roots.cursor_attach_input_device(input_service.cursor, device)

    local backend = core_service:get_backend()
    local is_libinput = wl.roots.backend_is_libinput(backend)
    if is_libinput then
        assert(configure_libinput_pointer(device, config), "Failed to configure libinput pointer")
    end
end

-- Handle new input device
local function server_new_input(listener, data)
    local device = ffi.cast("struct wlr_input_device*", data)

    if device.type == wl.WLR_INPUT_DEVICE_KEYBOARD then
        server_new_keyboard(device)
    elseif device.type == wl.WLR_INPUT_DEVICE_POINTER then
        server_new_pointer(device)
    end

    -- Update seat capabilities
    local caps = wl.WL_SEAT_CAPABILITY_POINTER
    if #input_service.keyboards > 0 then
        caps = bit.bor(caps, wl.WL_SEAT_CAPABILITY_KEYBOARD)
    end
    wl.roots.seat_set_capabilities(input_service.seat, caps)
end

--------------------------------------------------------------------------------
-- Cursor Handling
--------------------------------------------------------------------------------

-- Reset cursor mode
function input_service:reset_cursor_mode()
    local layout_service = require("compositor.services.layout")

    -- Notify layout service of end of interaction
    if self.cursor_mode == CURSOR_MOVE and self.grabbed_surface then
        layout_service:end_move(self.grabbed_surface)
    elseif self.cursor_mode == CURSOR_RESIZE and self.grabbed_surface then
        layout_service:end_resize(self.grabbed_surface)
    end

    self.cursor_mode = CURSOR_PASSTHROUGH
    self.grabbed_surface = nil

    -- Reset cursor to default
    wl.roots.cursor_set_xcursor(self.cursor, self.cursor_mgr, "default")
end

-- Process cursor move
local function process_cursor_move()
    local surface = input_service.grabbed_surface
    if not surface then return end

    local layout_service = require("compositor.services.layout")

    -- Try layout service first
    if surface._monitor_state then
        layout_service:update_move(surface, input_service.cursor.x, input_service.cursor.y)
        return
    end

    -- Fall back to direct scene manipulation
    if not surface.scene_tree then return end
    wl.roots.scene_node_set_position(surface.scene_tree.node,
        input_service.cursor.x - input_service.grab_x,
        input_service.cursor.y - input_service.grab_y)
end

-- Process cursor resize
local function process_cursor_resize()
    local surface = input_service.grabbed_surface
    if not surface then return end

    local layout_service = require("compositor.services.layout")

    -- Try layout service first
    if surface._monitor_state then
        layout_service:update_resize(surface, input_service.cursor.x, input_service.cursor.y)
        return
    end

    -- Fall back to direct scene manipulation
    if not surface.scene_tree then return end

    local border_x = input_service.cursor.x - input_service.grab_x
    local border_y = input_service.cursor.y - input_service.grab_y
    local new_left = input_service.grab_geobox.x
    local new_right = input_service.grab_geobox.x + input_service.grab_geobox.width
    local new_top = input_service.grab_geobox.y
    local new_bottom = input_service.grab_geobox.y + input_service.grab_geobox.height

    if bit.band(input_service.resize_edges, wl.WLR_EDGE_TOP) ~= 0 then
        new_top = border_y
        if new_top >= new_bottom then new_top = new_bottom - 1 end
    elseif bit.band(input_service.resize_edges, wl.WLR_EDGE_BOTTOM) ~= 0 then
        new_bottom = border_y
        if new_bottom <= new_top then new_bottom = new_top + 1 end
    end

    if bit.band(input_service.resize_edges, wl.WLR_EDGE_LEFT) ~= 0 then
        new_left = border_x
        if new_left >= new_right then new_left = new_right - 1 end
    elseif bit.band(input_service.resize_edges, wl.WLR_EDGE_RIGHT) ~= 0 then
        new_right = border_x
        if new_right <= new_left then new_right = new_left + 1 end
    end

    local geo_box = surface.role_obj.base.geometry
    wl.roots.scene_node_set_position(surface.scene_tree.node,
        new_left - geo_box.x, new_top - geo_box.y)

    local new_width = new_right - new_left
    local new_height = new_bottom - new_top
    surface:set_size(new_width, new_height)
end

-- Process cursor motion
local function process_cursor_motion(time)
    if input_service.cursor_mode == CURSOR_MOVE then
        process_cursor_move()
        return
    elseif input_service.cursor_mode == CURSOR_RESIZE then
        process_cursor_resize()
        return
    end

    -- Hit test via surface_service
    local surface, wlr_surface, sx, sy = surface_service:surface_at(
        input_service.cursor.x, input_service.cursor.y)

    if not surface then
        wl.roots.cursor_set_xcursor(input_service.cursor, input_service.cursor_mgr, "default")
    end

    if wlr_surface then
        wl.roots.seat_pointer_notify_enter(input_service.seat, wlr_surface, sx, sy)
        wl.roots.seat_pointer_notify_motion(input_service.seat, time, sx, sy)
    else
        wl.roots.seat_pointer_clear_focus(input_service.seat)
    end
end

-- Handle cursor motion
local function server_cursor_motion(listener, data)
    local event = ffi.cast("struct wlr_pointer_motion_event*", data)
    wl.roots.cursor_move(input_service.cursor, event.pointer.base, event.delta_x, event.delta_y)
    process_cursor_motion(event.time_msec)
end

-- Handle absolute cursor motion
local function server_cursor_motion_absolute(listener, data)
    local event = ffi.cast("struct wlr_pointer_motion_absolute_event*", data)
    wl.roots.cursor_warp_absolute(input_service.cursor, event.pointer.base, event.x, event.y)
    process_cursor_motion(event.time_msec)
end

-- Check if this is a double-click
local function is_double_click(x, y, button, time_msec)
    local time_delta = time_msec - input_service.last_click_time
    local dx = math.abs(x - input_service.last_click_x)
    local dy = math.abs(y - input_service.last_click_y)

    local is_double = input_service.last_click_button == button and
        time_delta < DOUBLE_CLICK_TIME_MS and
        dx < DOUBLE_CLICK_DISTANCE and
        dy < DOUBLE_CLICK_DISTANCE

    -- Update last click info
    input_service.last_click_time = time_msec
    input_service.last_click_x = x
    input_service.last_click_y = y
    input_service.last_click_button = button

    return is_double
end

-- Handle cursor button
local function server_cursor_button(listener, data)
    local event = ffi.cast("struct wlr_pointer_button_event*", data)
    local cursor_x, cursor_y = input_service.cursor.x, input_service.cursor.y
    local surface, _, _, _ = surface_service:surface_at(cursor_x, cursor_y)
    local layout_service = require("compositor.services.layout")

    if event.state == wl.WL_POINTER_BUTTON_STATE_RELEASED then
        input_service:reset_cursor_mode()
        wl.roots.seat_pointer_notify_button(input_service.seat, event.time_msec, event.button, event.state)
        return
    end

    -- Button pressed
    local double_click = is_double_click(cursor_x, cursor_y, event.button, event.time_msec)
    local modifiers = input_service.current_modifiers

    -- Get monitor state for layout operations
    local monitor_state = layout_service:get_monitor_state_at(cursor_x, cursor_y)

    -- Check for double-click shortcuts first
    if double_click then
        local action, shortcut_str = find_mouse_shortcut(modifiers, MOUSE_EVENT_DOUBLE_CLICK, event.button)
        if action then
            if type(action) == "function" then
                local ok, err = pcall(action)
                if not ok then
                    log.error("Mouse shortcut callback error: %s", tostring(err))
                end
            elseif action == "fullscreen" then
                -- Built-in fullscreen toggle
                if surface then
                    if layout_service:is_fullscreen(monitor_state) then
                        layout_service:exit_fullscreen(monitor_state)
                    else
                        layout_service:enter_fullscreen(surface)
                    end
                end
            end
            return
        end
    end

    -- Check for drag shortcuts
    local action, shortcut_str = find_mouse_shortcut(modifiers, MOUSE_EVENT_DRAG, event.button)
    if action then
        -- Handle built-in drag actions
        if action == "move_window" or action == "drag_window" then
            if surface then
                if layout_service:begin_move(surface, cursor_x, cursor_y) then
                    input_service.cursor_mode = CURSOR_MOVE
                    input_service.grabbed_surface = surface
                    wl.roots.cursor_set_xcursor(input_service.cursor, input_service.cursor_mgr, "grabbing")
                else
                    input_service:begin_interactive(surface, "move", 0)
                end
                surface_service:focus_window(surface)
            end
            return
        elseif action == "resize_window" then
            if surface then
                -- Calculate resize edges based on cursor position relative to window center
                local edges = 0
                if surface.scene_tree then
                    local geo = surface.role_obj and surface.role_obj.base.geometry
                    if geo then
                        local win_x = surface.scene_tree.node.x + geo.x
                        local win_y = surface.scene_tree.node.y + geo.y
                        local win_cx = win_x + geo.width / 2
                        local win_cy = win_y + geo.height / 2

                        if cursor_x < win_cx then
                            edges = bit.bor(edges, wl.WLR_EDGE_LEFT)
                        else
                            edges = bit.bor(edges, wl.WLR_EDGE_RIGHT)
                        end
                        if cursor_y < win_cy then
                            edges = bit.bor(edges, wl.WLR_EDGE_TOP)
                        else
                            edges = bit.bor(edges, wl.WLR_EDGE_BOTTOM)
                        end
                    end
                end

                if layout_service:begin_resize(surface, cursor_x, cursor_y, edges) then
                    input_service.cursor_mode = CURSOR_RESIZE
                    input_service.grabbed_surface = surface
                    input_service.resize_edges = edges

                    -- Set appropriate resize cursor
                    local cursor_name = "default"
                    if bit.band(edges, wl.WLR_EDGE_TOP) ~= 0 then
                        if bit.band(edges, wl.WLR_EDGE_LEFT) ~= 0 then
                            cursor_name = "nw-resize"
                        elseif bit.band(edges, wl.WLR_EDGE_RIGHT) ~= 0 then
                            cursor_name = "ne-resize"
                        else
                            cursor_name = "n-resize"
                        end
                    elseif bit.band(edges, wl.WLR_EDGE_BOTTOM) ~= 0 then
                        if bit.band(edges, wl.WLR_EDGE_LEFT) ~= 0 then
                            cursor_name = "sw-resize"
                        elseif bit.band(edges, wl.WLR_EDGE_RIGHT) ~= 0 then
                            cursor_name = "se-resize"
                        else
                            cursor_name = "s-resize"
                        end
                    elseif bit.band(edges, wl.WLR_EDGE_LEFT) ~= 0 then
                        cursor_name = "w-resize"
                    elseif bit.band(edges, wl.WLR_EDGE_RIGHT) ~= 0 then
                        cursor_name = "e-resize"
                    end
                    wl.roots.cursor_set_xcursor(input_service.cursor, input_service.cursor_mgr, cursor_name)
                else
                    input_service:begin_interactive(surface, "resize", edges)
                end
                surface_service:focus_window(surface)
            end
            return
        elseif type(action) == "function" then
            local ok, err = pcall(action)
            if not ok then
                log.error("Mouse shortcut callback error: %s", tostring(err))
            end
            return
        end
    end

    -- Normal click handling
    wl.roots.seat_pointer_notify_button(input_service.seat, event.time_msec, event.button, event.state)
    if surface then
        surface_service:focus_window(surface)
    end
end

-- Handle cursor axis (scroll)
local function server_cursor_axis(listener, data)
    local event = ffi.cast("struct wlr_pointer_axis_event*", data)
    local modifiers = input_service.current_modifiers

    -- Check for scroll shortcuts
    local action, shortcut_str = find_mouse_shortcut(modifiers, MOUSE_EVENT_SCROLL, nil)
    if action then
        -- Handle built-in zoom action
        if action == "zoom" then
            local layout_service = require("compositor.services.layout")
            local cursor_x, cursor_y = input_service.cursor.x, input_service.cursor.y
            local monitor_state = layout_service:get_monitor_state_at(cursor_x, cursor_y)

            if monitor_state then
                -- Positive delta = scroll down = zoom out, negative = zoom in
                local zoom_delta = event.delta < 0 and 1 or -1
                layout_service:zoom(monitor_state, zoom_delta, cursor_x, cursor_y)
            end
            return
        elseif type(action) == "function" then
            -- Pass scroll direction to the callback
            local direction = event.delta < 0 and 1 or -1
            local ok, err = pcall(action, direction)
            if not ok then
                log.error("Mouse shortcut callback error: %s", tostring(err))
            end
            return
        end
    end

    -- Normal scroll handling
    wl.roots.seat_pointer_notify_axis(input_service.seat, event.time_msec, event.orientation,
        event.delta, event.delta_discrete, event.source, event.relative_direction)
end

-- Handle cursor frame
local function server_cursor_frame(listener, data)
    wl.roots.seat_pointer_notify_frame(input_service.seat)
end

--------------------------------------------------------------------------------
-- Seat Request Handlers
--------------------------------------------------------------------------------

-- Handle cursor set request
local function seat_request_cursor(listener, data)
    local event = ffi.cast("struct wlr_seat_pointer_request_set_cursor_event*", data)
    local focused_client = input_service.seat.pointer_state.focused_client

    if focused_client == event.seat_client then
        wl.roots.cursor_set_surface(input_service.cursor, event.surface, event.hotspot_x, event.hotspot_y)
    end
end

-- Handle pointer focus change
local function seat_pointer_focus_change(listener, data)
    local event = ffi.cast("struct wlr_seat_pointer_focus_change_event*", data)
    if event.new_surface == nil or event.new_surface == ffi.NULL then
        wl.roots.cursor_set_xcursor(input_service.cursor, input_service.cursor_mgr, "default")
    end
end

-- Handle selection request
local function seat_request_set_selection(listener, data)
    local event = ffi.cast("struct wlr_seat_request_set_selection_event*", data)
    wl.roots.seat_set_selection(input_service.seat, event.source, event.serial)
end

--------------------------------------------------------------------------------
-- Interactive Move/Resize API
--------------------------------------------------------------------------------

-- Begin interactive move/resize
function input_service:begin_interactive(surface, mode, edges)
    if not surface or not surface.scene_tree then return end

    self.grabbed_surface = surface

    if mode == "move" then
        self.cursor_mode = CURSOR_MOVE
        self.grab_x = self.cursor.x - surface.scene_tree.node.x
        self.grab_y = self.cursor.y - surface.scene_tree.node.y
    else
        self.cursor_mode = CURSOR_RESIZE
        local geo_box = surface.role_obj.base.geometry

        local border_x = surface.scene_tree.node.x + geo_box.x
        if bit.band(edges, wl.WLR_EDGE_RIGHT) ~= 0 then
            border_x = border_x + geo_box.width
        end

        local border_y = surface.scene_tree.node.y + geo_box.y
        if bit.band(edges, wl.WLR_EDGE_BOTTOM) ~= 0 then
            border_y = border_y + geo_box.height
        end

        self.grab_x = self.cursor.x - border_x
        self.grab_y = self.cursor.y - border_y

        self.grab_geobox = ffi.new("struct wlr_box")
        self.grab_geobox.x = geo_box.x + surface.scene_tree.node.x
        self.grab_geobox.y = geo_box.y + surface.scene_tree.node.y
        self.grab_geobox.width = geo_box.width
        self.grab_geobox.height = geo_box.height

        self.resize_edges = edges
    end
end

-- Called by surface_service when a surface is unmapped
function input_service:on_surface_unmapped(surface)
    if self.grabbed_surface == surface then
        self:reset_cursor_mode()
    end
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function input_service:init()
    if self.initialized then
        return
    end


    -- Register implemented protocols
    proto.implement("wl_seat")
    proto.implement("wl_keyboard")
    proto.implement("wl_pointer")
    proto.implement("wl_touch")
    proto.implement("wl_data_device_manager")
    proto.implement("wl_data_device")
    proto.implement("wl_data_offer")
    proto.implement("wl_data_source")

    -- Create cursor
    self.cursor = wl.roots.cursor_create()
    wl.roots.cursor_attach_output_layout(self.cursor, output_service:get_output_layout())

    -- Create xcursor manager
    self.cursor_mgr = wl.roots.xcursor_manager_create(nil, 24)

    -- Create cursor shape manager (Phase 1 - Low Hanging Fruit)
    self.cursor_shape_manager = wl.roots.cursor_shape_manager_v1_create(core_service:get_display(), 1)
    if self.cursor_shape_manager and self.cursor_shape_manager ~= ffi.NULL then
        proto.implement("wp_cursor_shape_manager_v1")
        proto.implement("wp_cursor_shape_device_v1")
    end

    -- Create pointer constraints (Phase 2 - Easy)
    self.pointer_constraints = wl.roots.pointer_constraints_v1_create(core_service:get_display())
    if self.pointer_constraints and self.pointer_constraints ~= ffi.NULL then
        proto.implement("zwp_pointer_constraints_v1")
        proto.implement("zwp_confined_pointer_v1")
        proto.implement("zwp_locked_pointer_v1")
    end

    -- Create relative pointer manager (Phase 2 - Easy)
    self.relative_pointer_manager = wl.roots.relative_pointer_manager_v1_create(core_service:get_display())
    if self.relative_pointer_manager and self.relative_pointer_manager ~= ffi.NULL then
        proto.implement("zwp_relative_pointer_manager_v1")
        proto.implement("zwp_relative_pointer_v1")
    end

    -- Set up cursor listeners
    self.listeners.cursor_motion = wl.create_listener(server_cursor_motion)
    wl.signal_add(self.cursor.events.motion, self.listeners.cursor_motion)

    self.listeners.cursor_motion_absolute = wl.create_listener(server_cursor_motion_absolute)
    wl.signal_add(self.cursor.events.motion_absolute, self.listeners.cursor_motion_absolute)

    self.listeners.cursor_button = wl.create_listener(server_cursor_button)
    wl.signal_add(self.cursor.events.button, self.listeners.cursor_button)

    self.listeners.cursor_axis = wl.create_listener(server_cursor_axis)
    wl.signal_add(self.cursor.events.axis, self.listeners.cursor_axis)

    self.listeners.cursor_frame = wl.create_listener(server_cursor_frame)
    wl.signal_add(self.cursor.events.frame, self.listeners.cursor_frame)

    -- Listen for new inputs
    self.listeners.new_input = wl.create_listener(server_new_input)
    wl.signal_add(core_service:get_backend().events.new_input, self.listeners.new_input)

    -- Create seat
    self.seat = wl.roots.seat_create(core_service:get_display(), "seat0")

    self.listeners.request_cursor = wl.create_listener(seat_request_cursor)
    wl.signal_add(self.seat.events.request_set_cursor, self.listeners.request_cursor)

    self.listeners.pointer_focus_change = wl.create_listener(seat_pointer_focus_change)
    wl.signal_add(self.seat.pointer_state.events.focus_change, self.listeners.pointer_focus_change)

    self.listeners.request_set_selection = wl.create_listener(seat_request_set_selection)
    wl.signal_add(self.seat.events.request_set_selection, self.listeners.request_set_selection)

    self.initialized = true
end

-- Get the seat
function input_service:get_seat()
    return self.seat
end

-- Get the cursor
function input_service:get_cursor()
    return self.cursor
end

-- Cleanup on shutdown
function input_service:shutdown()
    if self.cursor_mgr then
        wl.roots.xcursor_manager_destroy(self.cursor_mgr)
        self.cursor_mgr = nil
    end

    if self.cursor then
        wl.roots.cursor_destroy(self.cursor)
        self.cursor = nil
    end
end

return input_service
