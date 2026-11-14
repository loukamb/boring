-- Server-side access to wayland, wlroots, xkbcommon and libinput.
--
--   local wl = require("shared.wl")
--   local lib, C = wl.lib, wl.C
--
--   local scene = lib.wlr_scene_create()            -- C functions, by full name
--   tree.node:set_position(x, y)                     -- methods on wlroots structs
--   if mods & C.WLR_MODIFIER_LOGO ~= 0 then ... end  -- enum constants
--
-- NULL pointers compare equal to nil (`ptr == nil`), but cdata is always
-- truthy, so test pointers with `~= nil`, never `if ptr then`.

local ffi = require("ffi")
require("shared.ffi.server")
require("shared.ffi.libc")

local lib = require("shared.ffi.lib").open({
    "libwlroots-0.20.so",
    "libwayland-server.so.0",
    "libxkbcommon.so.0",
    "libinput.so.10",
})

require("shared.wl.types").install(lib)

local uintptr = ffi.typeof("uintptr_t")
local voidp = ffi.typeof("void *")

local wl = {
    ffi = ffi,
    C = ffi.C,
    lib = lib,
    listener = require("shared.wl.listener"),
    scope = require("shared.wl.scope"),
    list = require("shared.wl.list"),
}

--- A number identifying a pointer, for use as a table key (cdata pointers
--- themselves aren't interned, so two casts of one address are different keys).
function wl.addr(ptr)
    return tonumber(ffi.cast(uintptr, ffi.cast(voidp, ptr)))
end

--- Lua string from a C string, nil for NULL.
function wl.string(ptr)
    if ptr == nil then
        return nil
    end
    return ffi.string(ptr)
end

--- Fork and run a shell command; returns the child pid.
function wl.spawn(cmd)
    local pid = ffi.C.fork()
    if pid == 0 then
        ffi.C.execl("/bin/sh", "/bin/sh", "-c", cmd, nil)
        ffi.C._exit(127)
    end
    return pid
end

return wl
