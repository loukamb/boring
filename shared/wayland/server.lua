-- shared/wayland/server.lua
-- Wayland server library: wlroots, wayland-server, xkbcommon, libinput

local base = require("shared.wayland.base")
local log = require("shared.log")
local ffi = base.ffi

--------------------------------------------------------------------------------
-- Load the wayland server library
--------------------------------------------------------------------------------

-- Declarations are generated ahead of time (tools/ffi_gen.lua); at runtime we
-- only load the libraries.
require("shared.ffi.server")
require("shared.ffi.libc")
local lib = require("shared.ffi.lib").open({
    "libwlroots-0.20.so",
    "libwayland-server.so.0",
    "libxkbcommon.so.0",
    "libinput.so.10",
})



--------------------------------------------------------------------------------
-- Create wayland namespace with base inheritance and wl_ prefix lookup
--------------------------------------------------------------------------------

local wayland = {}

-- Store library reference
wayland._lib = lib
wayland._ffi = ffi
wayland._C = ffi.C
wayland.bit = base.bit
wayland._prevent_gc = {}

-- Metatable that tries: 1) direct key, 2) wl_ prefix in lib, 3) base module
setmetatable(wayland, {
    __index = function(_, key)
        -- Try wl_ prefix lookup in lib
        local full_name = "wl_" .. key
        local ok, fn = pcall(function() return lib[full_name] end)
        if ok and fn ~= nil then
            rawset(wayland, key, fn)
            return fn
        end
        -- Fall back to base module
        return base[key]
    end
})

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

wayland.WLR_MODIFIER_SHIFT = 0x01
wayland.WLR_MODIFIER_CAPS = 0x02
wayland.WLR_MODIFIER_CTRL = 0x04
wayland.WLR_MODIFIER_ALT = 0x08
wayland.WLR_MODIFIER_MOD2 = 0x10
wayland.WLR_MODIFIER_MOD3 = 0x20
wayland.WLR_MODIFIER_LOGO = 0x40
wayland.WLR_MODIFIER_MOD5 = 0x80

wayland.WLR_EDGE_NONE = 0
wayland.WLR_EDGE_TOP = 1
wayland.WLR_EDGE_BOTTOM = 2
wayland.WLR_EDGE_LEFT = 4
wayland.WLR_EDGE_RIGHT = 8

wayland.WL_SEAT_CAPABILITY_POINTER = 1
wayland.WL_SEAT_CAPABILITY_KEYBOARD = 2
wayland.WL_SEAT_CAPABILITY_TOUCH = 4

wayland.WL_KEYBOARD_KEY_STATE_RELEASED = 0
wayland.WL_KEYBOARD_KEY_STATE_PRESSED = 1

wayland.WL_POINTER_BUTTON_STATE_RELEASED = 0
wayland.WL_POINTER_BUTTON_STATE_PRESSED = 1

wayland.WLR_INPUT_DEVICE_KEYBOARD = 0
wayland.WLR_INPUT_DEVICE_POINTER = 1
wayland.WLR_INPUT_DEVICE_TOUCH = 2
wayland.WLR_INPUT_DEVICE_TABLET = 3
wayland.WLR_INPUT_DEVICE_TABLET_PAD = 4
wayland.WLR_INPUT_DEVICE_SWITCH = 5

wayland.WLR_SCENE_NODE_TREE = 0
wayland.WLR_SCENE_NODE_RECT = 1
wayland.WLR_SCENE_NODE_BUFFER = 2

wayland.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_NONE = 0
wayland.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE = 1
wayland.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE = 2

wayland.WLR_DEBUG = 0
wayland.WLR_INFO = 1
wayland.WLR_ERROR = 2
wayland.WLR_SILENT = 3

wayland.XKB_CONTEXT_NO_FLAGS = 0
wayland.XKB_KEYMAP_COMPILE_NO_FLAGS = 0

-- XKB key constants
wayland.XKB_KEY_Escape = 0xff1b
wayland.XKB_KEY_Return = 0xff0d
wayland.XKB_KEY_Enter = 0xff0d
wayland.XKB_KEY_Tab = 0xff09
wayland.XKB_KEY_BackSpace = 0xff08
wayland.XKB_KEY_Delete = 0xffff
wayland.XKB_KEY_Insert = 0xff63
wayland.XKB_KEY_Home = 0xff50
wayland.XKB_KEY_End = 0xff57
wayland.XKB_KEY_Page_Up = 0xff55
wayland.XKB_KEY_Page_Down = 0xff56
wayland.XKB_KEY_Left = 0xff51
wayland.XKB_KEY_Up = 0xff52
wayland.XKB_KEY_Right = 0xff53
wayland.XKB_KEY_Down = 0xff54
wayland.XKB_KEY_F1 = 0xffbe
wayland.XKB_KEY_F2 = 0xffbf
wayland.XKB_KEY_F3 = 0xffc0
wayland.XKB_KEY_F4 = 0xffc1
wayland.XKB_KEY_F5 = 0xffc2
wayland.XKB_KEY_F6 = 0xffc3
wayland.XKB_KEY_F7 = 0xffc4
wayland.XKB_KEY_F8 = 0xffc5
wayland.XKB_KEY_F9 = 0xffc6
wayland.XKB_KEY_F10 = 0xffc7
wayland.XKB_KEY_F11 = 0xffc8
wayland.XKB_KEY_F12 = 0xffc9
wayland.XKB_KEY_space = 0x0020
wayland.XKB_KEY_a = 0x0061
wayland.XKB_KEY_b = 0x0062
wayland.XKB_KEY_c = 0x0063
wayland.XKB_KEY_d = 0x0064
wayland.XKB_KEY_e = 0x0065
wayland.XKB_KEY_f = 0x0066
wayland.XKB_KEY_g = 0x0067
wayland.XKB_KEY_h = 0x0068
wayland.XKB_KEY_i = 0x0069
wayland.XKB_KEY_j = 0x006a
wayland.XKB_KEY_k = 0x006b
wayland.XKB_KEY_l = 0x006c
wayland.XKB_KEY_m = 0x006d
wayland.XKB_KEY_n = 0x006e
wayland.XKB_KEY_o = 0x006f
wayland.XKB_KEY_p = 0x0070
wayland.XKB_KEY_q = 0x0071
wayland.XKB_KEY_r = 0x0072
wayland.XKB_KEY_s = 0x0073
wayland.XKB_KEY_t = 0x0074
wayland.XKB_KEY_u = 0x0075
wayland.XKB_KEY_v = 0x0076
wayland.XKB_KEY_w = 0x0077
wayland.XKB_KEY_x = 0x0078
wayland.XKB_KEY_y = 0x0079
wayland.XKB_KEY_z = 0x007a
wayland.XKB_KEY_0 = 0x0030
wayland.XKB_KEY_1 = 0x0031
wayland.XKB_KEY_2 = 0x0032
wayland.XKB_KEY_3 = 0x0033
wayland.XKB_KEY_4 = 0x0034
wayland.XKB_KEY_5 = 0x0035
wayland.XKB_KEY_6 = 0x0036
wayland.XKB_KEY_7 = 0x0037
wayland.XKB_KEY_8 = 0x0038
wayland.XKB_KEY_9 = 0x0039
wayland.XKB_KEY_bracketleft = 0x005b
wayland.XKB_KEY_bracketright = 0x005d
wayland.XKB_KEY_braceleft = 0x007b
wayland.XKB_KEY_braceright = 0x007d
wayland.XKB_KEY_parenleft = 0x0028
wayland.XKB_KEY_parenright = 0x0029
wayland.XKB_KEY_semicolon = 0x003b
wayland.XKB_KEY_colon = 0x003a
wayland.XKB_KEY_apostrophe = 0x0027
wayland.XKB_KEY_quotedbl = 0x0022
wayland.XKB_KEY_grave = 0x0060
wayland.XKB_KEY_asciitilde = 0x007e
wayland.XKB_KEY_comma = 0x002c
wayland.XKB_KEY_period = 0x002e
wayland.XKB_KEY_slash = 0x002f
wayland.XKB_KEY_backslash = 0x005c
wayland.XKB_KEY_minus = 0x002d
wayland.XKB_KEY_equal = 0x003d
wayland.XKB_KEY_plus = 0x002b
wayland.XKB_KEY_underscore = 0x005f

wayland.LIBINPUT_CONFIG_TAP_DISABLED = 0
wayland.LIBINPUT_CONFIG_TAP_ENABLED = 1
wayland.LIBINPUT_CONFIG_ACCEL_PROFILE_NONE = 0
wayland.LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT = 1
wayland.LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE = 2

--------------------------------------------------------------------------------
-- Sub-namespaces for different prefixes
--------------------------------------------------------------------------------

-- wlr_ prefix functions accessed via wayland.roots
wayland.roots = setmetatable({}, {
    __index = function(_, key)
        local full_name = "wlr_" .. key
        local ok, fn = pcall(function() return lib[full_name] end)
        if ok and fn then
            rawset(wayland.roots, key, fn)
            return fn
        end
        return nil
    end
})

-- xkb_ prefix functions accessed via wayland.xkb
wayland.xkb = setmetatable({}, {
    __index = function(_, key)
        local full_name = "xkb_" .. key
        local ok, fn = pcall(function() return lib[full_name] end)
        if ok and fn then
            rawset(wayland.xkb, key, fn)
            return fn
        end
        return nil
    end
})

-- libinput_ prefix functions accessed via wayland.libinput
wayland.libinput = setmetatable({}, {
    __index = function(_, key)
        local full_name = "libinput_" .. key
        local fn = lib[full_name]
        local ok = fn ~= nil
        if ok and fn then
            rawset(wayland.libinput, key, fn)
            return fn
        end
        return nil
    end
})

--------------------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------------------

function wayland.persistent_callback(signature, fn)
    return base.persistent_callback(wayland, signature, fn)
end

local function remove_prevent_gc(item)
    for i = #wayland._prevent_gc, 1, -1 do
        if wayland._prevent_gc[i] == item then
            table.remove(wayland._prevent_gc, i)
        end
    end
end

local listener_handles = {}

local function listener_key(listener)
    return wayland.ptr_to_num(listener)
end

local function clear_listener_notify(listener_ref)
    if ffi.istype("struct wl_listener[1]", listener_ref) then
        listener_ref[0].notify = nil
    elseif listener_ref and listener_ref ~= ffi.NULL then
        listener_ref.notify = nil
    end
end

local function release_listener_handle(key, listener_arr, listener_ref, handle)
    remove_prevent_gc(listener_arr)
    remove_prevent_gc(handle.callback)

    if handle.callback and handle.callback ~= ffi.NULL then
        pcall(function()
            handle.callback:free()
        end)
    end

    clear_listener_notify(listener_ref)
    handle.callback = nil
    handle.destroyed = true
    listener_handles[key] = nil
end

local function protected_notify(fn)
    return function(listener, data)
        local key = listener_key(listener)
        local handle = listener_handles[key]
        if handle then
            handle.dispatching = (handle.dispatching or 0) + 1
        end
        local ok, err = xpcall(fn, debug.traceback, listener, data)
        if handle then
            handle.dispatching = handle.dispatching - 1
            if handle.pending_destroy and handle.dispatching == 0 then
                release_listener_handle(key, handle.listener_arr, listener, handle)
            end
        end
        if not ok then
            log.error("wl listener error: %s", tostring(err))
        end
    end
end

function wayland.offsetof(ctype, member)
    return ffi.offsetof(ctype, member)
end

function wayland.container_of(ptr, ctype, member)
    local offset = ffi.offsetof(ctype, member)
    local addr = ffi.cast("char*", ptr) - offset
    return ffi.cast(ctype .. "*", addr)
end

function wayland.list_init(list)
    list.prev = list
    list.next = list
end

function wayland.list_insert(pos, entry)
    entry.prev = pos
    entry.next = pos.next
    pos.next.prev = entry
    pos.next = entry
end

function wayland.list_remove(entry)
    if entry == nil or entry == ffi.NULL or entry.prev == nil or entry.prev == ffi.NULL then
        return
    end
    entry.prev.next = entry.next
    entry.next.prev = entry.prev
    entry.prev = nil
    entry.next = nil
end

function wayland.list_empty(list)
    return list.next == list
end

function wayland.list_length(list)
    local count = 0
    local pos = list.next
    while pos ~= list do
        count = count + 1
        pos = pos.next
    end
    return count
end

function wayland.signal_add(signal, listener)
    local l = listener
    if ffi.istype("struct wl_listener[1]", listener) then
        l = listener[0]
    end
    wayland.list_insert(signal.listener_list.prev, l.link)
end

function wayland.fork_exec(cmd)
    local pid = ffi.C.fork()
    if pid == 0 then
        ffi.C.execl("/bin/sh", "/bin/sh", "-c", cmd, ffi.NULL)
        os.exit(1)
    end
    return pid
end

function wayland.setenv(name, value)
    ffi.C.setenv(name, value, 1)
end

function wayland.callback(signature, fn)
    return ffi.cast(signature, fn)
end

function wayland.notify_callback(fn)
    return ffi.cast("wl_notify_func_t", fn)
end

function wayland.event(data, ctype)
    return ffi.cast(ctype, data)
end

function wayland.alloc(ctype)
    local ptr = ffi.new(ctype .. "[1]")
    ffi.fill(ptr, ffi.sizeof(ctype))
    return ptr[0]
end

function wayland.alloc_ptr(ctype)
    return ffi.new(ctype .. "*", ffi.new(ctype))
end

--------------------------------------------------------------------------------
-- ObjectRegistry class
--------------------------------------------------------------------------------

local ObjectRegistry = {}
ObjectRegistry.__index = ObjectRegistry

function ObjectRegistry.new()
    local self = setmetatable({}, ObjectRegistry)
    self._data = {}
    return self
end

function ObjectRegistry:set(ptr, data)
    local addr = wayland.ptr_to_num(ptr)
    self._data[addr] = data
end

function ObjectRegistry:get(ptr)
    local addr = wayland.ptr_to_num(ptr)
    return self._data[addr]
end

function ObjectRegistry:remove(ptr)
    local addr = wayland.ptr_to_num(ptr)
    self._data[addr] = nil
end

function ObjectRegistry:clear()
    self._data = {}
end

wayland.ObjectRegistry = ObjectRegistry

function wayland.new_registry()
    return ObjectRegistry.new()
end

--------------------------------------------------------------------------------
-- Listener class
--------------------------------------------------------------------------------

local Listener = {}
Listener.__index = Listener

local listener_registry = ObjectRegistry.new()

function Listener.new(callback, user_data)
    local self = setmetatable({}, Listener)

    self._listener_arr = ffi.new("struct wl_listener[1]")
    self._callback = wayland.persistent_callback("wl_notify_func_t", protected_notify(callback))
    self._listener_arr[0].notify = self._callback
    self._user_data = user_data
    self._destroyed = false
    listener_handles[listener_key(self._listener_arr)] = {
        callback = self._callback,
        listener_arr = self._listener_arr,
        owner = self,
        destroyed = false,
        dispatching = 0,
    }

    table.insert(wayland._prevent_gc, self._listener_arr)
    table.insert(wayland._prevent_gc, self)

    listener_registry:set(self._listener_arr, self)

    return self
end

function Listener:data()
    return self._user_data
end

function Listener:set_data(data)
    self._user_data = data
end

function Listener:ptr()
    return self._listener_arr
end

function Listener:get()
    return self._listener_arr[0]
end

function Listener:connect(signal)
    wayland.list_insert(signal.listener_list.prev, self._listener_arr[0].link)
end

function Listener:disconnect()
    wayland.list_remove(self._listener_arr[0].link)
end

function Listener:destroy()
    if self._destroyed then
        return
    end
    self:disconnect()
    listener_registry:remove(self._listener_arr)
    remove_prevent_gc(self._listener_arr)
    remove_prevent_gc(self._callback)
    remove_prevent_gc(self)
    local key = listener_key(self._listener_arr)
    local handle = listener_handles[key]
    if handle and handle.dispatching and handle.dispatching > 0 then
        handle.pending_destroy = true
    else
        release_listener_handle(key, self._listener_arr, self._listener_arr, handle or {
            callback = self._callback,
        })
    end
    self._callback = nil
    self._destroyed = true
end

function Listener.from_ptr(listener_ptr)
    return listener_registry:get(listener_ptr)
end

function Listener.get_data(listener_ptr)
    local listener = listener_registry:get(listener_ptr)
    return listener and listener._user_data or nil
end

wayland.Listener = Listener

--------------------------------------------------------------------------------
-- ManagedList class
--------------------------------------------------------------------------------

local ManagedList = {}
ManagedList.__index = ManagedList

function ManagedList.new()
    local self = setmetatable({}, ManagedList)
    self._items = {}
    return self
end

function ManagedList:add(item)
    table.insert(self._items, item)
end

function ManagedList:prepend(item)
    table.insert(self._items, 1, item)
end

function ManagedList:remove(item)
    for i, v in ipairs(self._items) do
        if v == item then
            table.remove(self._items, i)
            return true
        end
    end
    return false
end

function ManagedList:contains(item)
    for _, v in ipairs(self._items) do
        if v == item then return true end
    end
    return false
end

function ManagedList:first()
    return self._items[1]
end

function ManagedList:last()
    return self._items[#self._items]
end

function ManagedList:length()
    return #self._items
end

function ManagedList:is_empty()
    return #self._items == 0
end

function ManagedList:items()
    return self._items
end

function ManagedList:ipairs()
    return ipairs(self._items)
end

wayland.ManagedList = ManagedList

--------------------------------------------------------------------------------
-- Legacy helper functions
--------------------------------------------------------------------------------

function wayland.create_listener(fn)
    local listener_arr = ffi.new("struct wl_listener[1]")
    local callback = wayland.persistent_callback("wl_notify_func_t", protected_notify(fn))
    listener_arr[0].notify = callback
    listener_handles[listener_key(listener_arr)] = {
        callback = callback,
        listener_arr = listener_arr,
        destroyed = false,
        dispatching = 0,
    }
    table.insert(wayland._prevent_gc, listener_arr)
    return listener_arr
end

function wayland.destroy_listener(listener)
    if not listener or listener == ffi.NULL then
        return
    end

    if type(listener) == "table" and getmetatable(listener) == Listener then
        listener:destroy()
        return
    end

    local handle = listener_handles[listener_key(listener)]
    if handle and handle.destroyed then
        return
    end

    local listener_arr = listener
    local listener_ptr = listener
    if ffi.istype("struct wl_listener[1]", listener) then
        listener_ptr = listener[0]
    end

    wayland.list_remove(listener_ptr.link)

    handle = listener_handles[listener_key(listener_arr)]
    local callback = (handle and handle.callback) or listener_ptr.notify
    remove_prevent_gc(listener_arr)
    if handle and handle.dispatching and handle.dispatching > 0 then
        handle.pending_destroy = true
        return
    end
    release_listener_handle(listener_key(listener_arr), listener_arr, listener_arr, handle or {
        callback = callback,
    })
end

function wayland.new_listener(callback, user_data)
    return wayland.Listener.new(callback, user_data)
end

return wayland
