-- shared/wayland/server.lua
--
-- COMPATIBILITY LAYER over shared.wl, kept while services and plugins are
-- ported (see ARCHITECTURE.md roadmap). New code should use shared.wl:
--
--   wl.roots.foo(...)        ->  wl.lib.wlr_foo(...)  or a method on the object
--   wl.WLR_SOMETHING         ->  wl.C.WLR_SOMETHING
--   wl.Listener / get_data   ->  scope:listen(signal, function(data) ... end, ctype)

local new_wl = require("shared.wl")
local base = require("shared.wayland.base")
local list = require("shared.wl.list")
local listener = require("shared.wl.listener")

local ffi = new_wl.ffi
local lib = new_wl.lib
local C = ffi.C

local wayland = {
    _lib = lib,
    _ffi = ffi,
    _C = C,
    bit = base.bit,
}

local function prefixed(prefix)
    local ns = {}
    return setmetatable(ns, {
        __index = function(_, key)
            local fn = lib[prefix .. key]
            if fn ~= nil then rawset(ns, key, fn) end
            return fn
        end,
    })
end

wayland.roots = prefixed("wlr_")
wayland.xkb = prefixed("xkb_")
wayland.libinput = prefixed("libinput_")

local function c_constant(name)
    return C[name]
end

-- wl.foo -> wl_foo; wl.XKB_KEY_x -> keysym; wl.CONSTANT -> generated enum.
setmetatable(wayland, {
    __index = function(_, key)
        local fn = lib["wl_" .. key]
        if fn ~= nil then
            rawset(wayland, key, fn)
            return fn
        end
        local keysym_name = key:match("^XKB_KEY_(.+)$")
        if keysym_name then
            local sym = lib.xkb_keysym_from_name(keysym_name, 0)
            if sym ~= 0 then return sym end
            return nil
        end
        if key:match("^[A-Z][A-Z0-9_]+$") then
            local ok, value = pcall(c_constant, key)
            if ok then
                rawset(wayland, key, value)
                return value
            end
        end
        return base[key]
    end,
})

--------------------------------------------------------------------------------
-- Helpers still used by unported code
--------------------------------------------------------------------------------

wayland._prevent_gc = {}
function wayland.persistent_callback(signature, fn)
    return base.persistent_callback(wayland, signature, fn)
end

wayland.ptr_to_num = new_wl.addr
wayland.offsetof = ffi.offsetof
wayland.container_of = list.container_of
wayland.list_length = list.length
wayland.signal_init = listener.signal_init

function wayland.list_init(l)
    l.prev = l
    l.next = l
end

function wayland.fork_exec(cmd)
    return new_wl.spawn(cmd)
end

function wayland.setenv(name, value)
    C.setenv(name, value, 1)
end

function wayland.event(data, ctype)
    return ffi.cast(ctype, data)
end

-- Pointer-keyed table (ObjectRegistry replacement).
function wayland.new_registry()
    local data = {}
    return {
        set = function(_, ptr, value) data[new_wl.addr(ptr)] = value end,
        get = function(_, ptr) return data[new_wl.addr(ptr)] end,
        remove = function(_, ptr) data[new_wl.addr(ptr)] = nil end,
        clear = function() data = {} end,
    }
end

-- Old-style listener callbacks receive (handle, data) and fetch their user
-- data with wl.Listener.get_data(handle).
wayland.Listener = {
    get_data = function(handle)
        return handle and handle.data
    end,
}

return wayland
