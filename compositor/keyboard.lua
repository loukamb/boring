-- Keyboards: keymaps and repeat from the config, compositor shortcuts, and
-- forwarding everything else to the focused client.

local wl = require("shared.wl")
local log = require("shared.log")
local state = require("compositor.state")
local shortcuts = require("compositor.shortcuts")

local ffi, lib, C = wl.ffi, wl.lib, wl.C

local keyboard = {}

local syms_out = ffi.new("const xkb_keysym_t *[1]")

-- Mouse shortcuts live in keyboard configs (they're modifier+button combos);
-- the pointer matches against the union of all keyboards'.
local function rebuild_mouse_shortcuts(server)
    local all = {}
    for _, kb in ipairs(server.keyboards) do
        for _, s in ipairs(kb.mouse) do all[#all + 1] = s end
    end
    server.mouse_shortcuts = all
end

local function set_keymap(wlr_keyboard, xkb)
    local context = lib.xkb_context_new(C.XKB_CONTEXT_NO_FLAGS)
    local names = nil
    if xkb then
        names = ffi.new("struct xkb_rule_names")
        names.rules = xkb.rules
        names.model = xkb.model
        names.layout = xkb.layout
        names.variant = xkb.variant
        names.options = xkb.options
    end
    local keymap = lib.xkb_keymap_new_from_names(context, names, C.XKB_KEYMAP_COMPILE_NO_FLAGS)
    if keymap == nil then
        log.error("invalid xkb settings; using the default keymap")
        keymap = lib.xkb_keymap_new_from_names(context, nil, C.XKB_KEYMAP_COMPILE_NO_FLAGS)
    end
    wlr_keyboard:set_keymap(keymap)
    lib.xkb_keymap_unref(keymap)
    lib.xkb_context_unref(context)
end

local function key(server, kb, event)
    local wlr_keyboard = kb.wlr
    local seat = server.seat
    if event.state == C.WL_KEYBOARD_KEY_STATE_PRESSED then
        local mods = wlr_keyboard:get_modifiers()
        local n = lib.xkb_state_key_get_syms(wlr_keyboard.xkb_state, event.keycode + 8, syms_out)
        for i = 0, n - 1 do
            local s = shortcuts.match_key(kb.keys, mods, syms_out[0][i])
            if s then
                if type(s.action) == "function" then
                    local ok, err = xpcall(s.action, debug.traceback)
                    if not ok then log.error("shortcut %s failed: %s", s.name, tostring(err)) end
                else
                    log.warn("shortcut %s isn't bound to a function", s.name)
                end
                return
            end
        end
    end
    seat:set_keyboard(wlr_keyboard)
    seat:keyboard_notify_key(event.time_msec, event.keycode, event.state)
end

-- (Re)apply the config for a keyboard: shortcuts, keymap, repeat.
local function configure(server, kb)
    local config = state.resolve_keyboard(kb.name)
    local keys, mice, errors = shortcuts.compile(config.shortcuts)
    for _, err in ipairs(errors) do log.warn("keyboard %s: %s", kb.name, err) end
    kb.keys, kb.mouse = keys, mice
    set_keymap(kb.wlr, config.xkb)
    local rep = config["repeat"] or {}
    kb.wlr:set_repeat_info(rep.rate or 30, rep.delay or 300)
end

--- Re-read the config for every keyboard (after a reload).
function keyboard.reconfigure_all(server)
    for _, kb in ipairs(server.keyboards) do configure(server, kb) end
    rebuild_mouse_shortcuts(server)
end

function keyboard.add_device(server, device)
    local wlr_keyboard = lib.wlr_keyboard_from_input_device(device)
    local name = wl.string(device.name)
    local kb = {
        name = name,
        wlr = wlr_keyboard,
        keys = {},
        mouse = {},
        scope = server.scope:child("keyboard " .. name),
    }
    configure(server, kb)

    kb.scope:listen(wlr_keyboard.events.modifiers, function()
        server.seat:set_keyboard(wlr_keyboard)
        server.seat:keyboard_notify_modifiers(wlr_keyboard.modifiers)
        server.modifiers = wlr_keyboard:get_modifiers()
    end)
    kb.scope:listen(wlr_keyboard.events.key, function(event) key(server, kb, event) end,
        "struct wlr_keyboard_key_event")
    kb.scope:listen(device.events.destroy, function()
        for i, x in ipairs(server.keyboards) do
            if x == kb then table.remove(server.keyboards, i) break end
        end
        kb.scope:close()
        rebuild_mouse_shortcuts(server)
        require("compositor.input").update_capabilities(server)
    end)

    server.seat:set_keyboard(wlr_keyboard)
    table.insert(server.keyboards, kb)
    rebuild_mouse_shortcuts(server)
end

return keyboard
