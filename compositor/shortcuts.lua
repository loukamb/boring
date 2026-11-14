-- Parse shortcut strings: "Mod4+Return", "Ctrl+Alt+t", "Super+LeftMouseDrag".
--
-- Key names are xkb keysym names (case-insensitive), so every key xkb knows
-- works, plus a few friendlier aliases. Pure functions; no compositor state.

local bit = require("bit")
local wl = require("shared.wl")

local lib, C = wl.lib, wl.C

local shortcuts = {}

local MODIFIERS = {
    Shift = C.WLR_MODIFIER_SHIFT,
    Caps = C.WLR_MODIFIER_CAPS,
    Ctrl = C.WLR_MODIFIER_CTRL,
    Control = C.WLR_MODIFIER_CTRL,
    Alt = C.WLR_MODIFIER_ALT,
    Mod1 = C.WLR_MODIFIER_ALT,
    Mod2 = C.WLR_MODIFIER_MOD2,
    Mod3 = C.WLR_MODIFIER_MOD3,
    Hyper = C.WLR_MODIFIER_MOD3,
    Mod4 = C.WLR_MODIFIER_LOGO,
    Super = C.WLR_MODIFIER_LOGO,
    Logo = C.WLR_MODIFIER_LOGO,
    Mod5 = C.WLR_MODIFIER_MOD5,
}
shortcuts.MODIFIERS = MODIFIERS

-- Caps Lock and Num Lock never take part in matching.
local LOCKS = bit.bor(C.WLR_MODIFIER_CAPS, C.WLR_MODIFIER_MOD2)
local NOT_LOCKS = bit.bnot(LOCKS)

function shortcuts.normalize(mods)
    return bit.band(mods or 0, NOT_LOCKS)
end

local KEY_ALIASES = {
    PrintScreen = "Print",
    Enter = "Return",
    Esc = "Escape",
    Del = "Delete",
    Space = "space",
    PageUp = "Prior",
    PageDown = "Next",
}

local BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
shortcuts.BTN_LEFT, shortcuts.BTN_RIGHT, shortcuts.BTN_MIDDLE = BTN_LEFT, BTN_RIGHT, BTN_MIDDLE

local MOUSE = {
    LeftMouseDrag = { event = "drag", button = BTN_LEFT },
    RightMouseDrag = { event = "drag", button = BTN_RIGHT },
    MiddleMouseDrag = { event = "drag", button = BTN_MIDDLE },
    Scroll = { event = "scroll" },
    DoubleClick = { event = "double_click", button = BTN_LEFT },
}

local XKB_KEYSYM_CASE_INSENSITIVE = 1

local function keysym(name)
    name = KEY_ALIASES[name] or name
    local sym = lib.xkb_keysym_from_name(name, 0)
    if sym == 0 then
        sym = lib.xkb_keysym_from_name(name, XKB_KEYSYM_CASE_INSENSITIVE)
    end
    return sym ~= 0 and sym or nil
end

--- Parse a shortcut string.
--- Returns nil, err for unknown keys/modifiers, otherwise one of:
---   { kind = "key", mods = n, sym = keysym }
---   { kind = "mouse", mods = n, event = "drag"|"scroll"|"double_click", button = n|nil }
function shortcuts.parse(str)
    local mods, key = 0, nil
    for part in str:gmatch("[^+]+") do
        part = part:match("^%s*(.-)%s*$")
        local m = MODIFIERS[part]
        if m then
            mods = bit.bor(mods, m)
        elseif key then
            return nil, string.format("shortcut %q has more than one key", str)
        else
            key = part
        end
    end
    if not key then
        return nil, string.format("shortcut %q has no key", str)
    end
    local mouse = MOUSE[key]
    if mouse then
        return { kind = "mouse", mods = mods, event = mouse.event, button = mouse.button }
    end
    local sym = keysym(key)
    if not sym then
        return nil, string.format("unknown key %q in shortcut %q", key, str)
    end
    return { kind = "key", mods = mods, sym = sym }
end

--- Compile a { ["Mod4+Return"] = action } table into key and mouse lists.
--- Returns keys, mice, errors.
function shortcuts.compile(map)
    local keys, mice, errors = {}, {}, {}
    for str, action in pairs(map or {}) do
        local s, err = shortcuts.parse(str)
        if not s then
            errors[#errors + 1] = err
        else
            s.action = action
            s.name = str
            s.mods = shortcuts.normalize(s.mods)
            if s.kind == "key" then keys[#keys + 1] = s else mice[#mice + 1] = s end
        end
    end
    return keys, mice, errors
end

--- First key shortcut matching a keysym with modifiers, or nil.
function shortcuts.match_key(list, mods, sym)
    mods = shortcuts.normalize(mods)
    for i = 1, #list do
        local s = list[i]
        if s.sym == sym and s.mods == mods then return s end
    end
end

--- First mouse shortcut matching an event, or nil.
function shortcuts.match_mouse(list, mods, event, button)
    mods = shortcuts.normalize(mods)
    for i = 1, #list do
        local s = list[i]
        if s.event == event and s.mods == mods and (s.button == nil or s.button == button) then
            return s
        end
    end
end

--- xcursor name for a set of WLR_EDGE_* bits.
function shortcuts.resize_cursor(edges)
    local top = bit.band(edges, C.WLR_EDGE_TOP) ~= 0
    local bottom = bit.band(edges, C.WLR_EDGE_BOTTOM) ~= 0
    local left = bit.band(edges, C.WLR_EDGE_LEFT) ~= 0
    local right = bit.band(edges, C.WLR_EDGE_RIGHT) ~= 0
    local v = top and "n" or (bottom and "s" or "")
    local h = left and "w" or (right and "e" or "")
    if v == "" and h == "" then return "default" end
    return v .. h .. "-resize"
end

return shortcuts
