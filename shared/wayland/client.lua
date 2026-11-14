-- shared/wayland/client.lua
-- Wayland client library

local bit = require("bit")
local ffi = require("ffi")
local interface = require("shared.wayland.interface")

--------------------------------------------------------------------------------
-- Load the wayland client library
--------------------------------------------------------------------------------

-- Declarations are generated ahead of time (tools/ffi_gen.lua); at runtime we
-- only load the library.
require("shared.ffi.client")
require("shared.ffi.libc")
local lib = require("shared.ffi.lib").open({ "libwayland-client.so.0" })



--------------------------------------------------------------------------------
-- The client namespace
--------------------------------------------------------------------------------

local wayland = {}

-- Store library references
wayland._lib = lib
wayland._wl = lib -- Legacy accessor
wayland._ffi = ffi
wayland._C = ffi.C
wayland.bit = bit
wayland._prevent_gc = {}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

wayland.WL_SHM_FORMAT_ARGB8888 = 0
wayland.WL_SHM_FORMAT_XRGB8888 = 1

wayland.PROT_READ = ffi.C.PROT_READ
wayland.PROT_WRITE = ffi.C.PROT_WRITE
wayland.MAP_SHARED = ffi.C.MAP_SHARED

wayland.O_RDWR = ffi.C.O_RDWR
wayland.O_CREAT = ffi.C.O_CREAT
wayland.O_EXCL = ffi.C.O_EXCL

-- libwayland-client functions used directly by clients.
wayland.display_connect = lib.wl_display_connect
wayland.display_disconnect = lib.wl_display_disconnect
wayland.display_dispatch = lib.wl_display_dispatch
wayland.display_roundtrip = lib.wl_display_roundtrip

function wayland.is_null(ptr)
    return ptr == nil
end

function wayland.string(ptr)
    if ptr == nil then return nil end
    return ffi.string(ptr)
end

--------------------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------------------

--- An ffi callback that lives as long as the process (listener structs
--- given to libwayland keep pointing at it).
function wayland.persistent_callback(signature, fn)
    local cb = ffi.cast(signature, fn)
    table.insert(wayland._prevent_gc, cb)
    return cb
end

--------------------------------------------------------------------------------
-- Protocol constants
--------------------------------------------------------------------------------

local WL_DISPLAY_GET_REGISTRY = 1
local WL_REGISTRY_BIND = 0
local WL_COMPOSITOR_CREATE_SURFACE = 0
local WL_SHM_CREATE_POOL = 0
local WL_SHM_POOL_CREATE_BUFFER = 0
local WL_SHM_POOL_DESTROY = 1
local WL_BUFFER_DESTROY = 0
local WL_SURFACE_ATTACH = 1
local WL_SURFACE_DAMAGE = 2
local WL_SURFACE_COMMIT = 6
local WL_SURFACE_DAMAGE_BUFFER = 9

--------------------------------------------------------------------------------
-- Core wayland functions
--------------------------------------------------------------------------------

function wayland.display_get_registry(display)
    local proxy = lib.wl_proxy_marshal_constructor(
        ffi.cast("struct wl_proxy*", display),
        WL_DISPLAY_GET_REGISTRY,
        lib.wl_registry_interface,
        nil
    )
    return ffi.cast("struct wl_registry*", proxy)
end

function wayland.registry_bind(registry, name, interface, version)
    local proxy = lib.wl_proxy_marshal_constructor_versioned(
        ffi.cast("struct wl_proxy*", registry),
        WL_REGISTRY_BIND,
        interface,
        version,
        ffi.cast("uint32_t", name),
        interface.name,
        ffi.cast("uint32_t", version),
        ffi.cast("void*", nil)
    )
    return proxy
end

function wayland.registry_add_listener(registry, listener, data)
    return lib.wl_proxy_add_listener(
        ffi.cast("struct wl_proxy*", registry),
        ffi.cast("void(**)(void)", listener),
        data
    )
end

function wayland.compositor_create_surface(compositor)
    local proxy = lib.wl_proxy_marshal_constructor(
        ffi.cast("struct wl_proxy*", compositor),
        WL_COMPOSITOR_CREATE_SURFACE,
        lib.wl_surface_interface,
        nil
    )
    return ffi.cast("struct wl_surface*", proxy)
end

function wayland.shm_create_pool(shm, fd, size)
    local proxy = lib.wl_proxy_marshal_constructor(
        ffi.cast("struct wl_proxy*", shm),
        WL_SHM_CREATE_POOL,
        lib.wl_shm_pool_interface,
        ffi.cast("void*", nil),
        ffi.cast("int32_t", fd),
        ffi.cast("int32_t", size)
    )
    return ffi.cast("struct wl_shm_pool*", proxy)
end

function wayland.shm_pool_create_buffer(pool, offset, width, height, stride, format)
    local proxy = lib.wl_proxy_marshal_constructor(
        ffi.cast("struct wl_proxy*", pool),
        WL_SHM_POOL_CREATE_BUFFER,
        lib.wl_buffer_interface,
        ffi.cast("void*", nil),
        ffi.cast("int32_t", offset),
        ffi.cast("int32_t", width),
        ffi.cast("int32_t", height),
        ffi.cast("int32_t", stride),
        ffi.cast("uint32_t", format)
    )
    return ffi.cast("struct wl_buffer*", proxy)
end

function wayland.shm_pool_destroy(pool)
    lib.wl_proxy_marshal(ffi.cast("struct wl_proxy*", pool), WL_SHM_POOL_DESTROY)
    lib.wl_proxy_destroy(ffi.cast("struct wl_proxy*", pool))
end

function wayland.buffer_destroy(buffer)
    if buffer == nil or buffer == ffi.NULL then
        return
    end
    lib.wl_proxy_marshal(ffi.cast("struct wl_proxy*", buffer), WL_BUFFER_DESTROY)
    lib.wl_proxy_destroy(ffi.cast("struct wl_proxy*", buffer))
end

function wayland.surface_attach(surface, buffer, x, y)
    lib.wl_proxy_marshal(
        ffi.cast("struct wl_proxy*", surface),
        WL_SURFACE_ATTACH,
        ffi.cast("struct wl_proxy*", buffer),
        ffi.cast("int32_t", x),
        ffi.cast("int32_t", y)
    )
end

function wayland.surface_damage(surface, x, y, width, height)
    lib.wl_proxy_marshal(
        ffi.cast("struct wl_proxy*", surface),
        WL_SURFACE_DAMAGE,
        ffi.cast("int32_t", x),
        ffi.cast("int32_t", y),
        ffi.cast("int32_t", width),
        ffi.cast("int32_t", height)
    )
end

function wayland.surface_damage_buffer(surface, x, y, width, height)
    lib.wl_proxy_marshal(
        ffi.cast("struct wl_proxy*", surface),
        WL_SURFACE_DAMAGE_BUFFER,
        ffi.cast("int32_t", x),
        ffi.cast("int32_t", y),
        ffi.cast("int32_t", width),
        ffi.cast("int32_t", height)
    )
end

function wayland.surface_commit(surface)
    lib.wl_proxy_marshal(ffi.cast("struct wl_proxy*", surface), WL_SURFACE_COMMIT)
end

local shm_counter = 0

function wayland.create_shm_buffer(shm, width, height, format)
    local stride = width * 4
    local size = stride * height

    shm_counter = shm_counter + 1
    local name = string.format("/wl_shm-%d-%d", tonumber(ffi.C.getpid()), shm_counter)
    local fd = ffi.C.shm_open(name, bit.bor(wayland.O_RDWR, wayland.O_CREAT, wayland.O_EXCL), 0x180)
    if fd < 0 then
        return nil, nil, nil, "shm_open failed"
    end
    ffi.C.shm_unlink(name)

    if ffi.C.ftruncate(fd, size) < 0 then
        ffi.C.close(fd)
        return nil, nil, nil, "ftruncate failed"
    end

    local data = ffi.C.mmap(nil, size, bit.bor(wayland.PROT_READ, wayland.PROT_WRITE), wayland.MAP_SHARED, fd, 0)
    if data == ffi.cast("void*", -1) then
        ffi.C.close(fd)
        return nil, nil, nil, "mmap failed"
    end

    local pool = wayland.shm_create_pool(shm, fd, size)
    local buffer = wayland.shm_pool_create_buffer(pool, 0, width, height, stride, format)
    wayland.shm_pool_destroy(pool)
    ffi.C.close(fd)

    return buffer, data, size
end

--------------------------------------------------------------------------------
-- Layer shell protocol definitions
--------------------------------------------------------------------------------

-- Built from the protocol XML (shared/wayland/interface.lua).
wayland.zwlr_layer_shell_v1_interface = interface.get("zwlr_layer_shell_v1", lib)
wayland.zwlr_layer_surface_v1_interface = interface.get("zwlr_layer_surface_v1", lib)
local zwlr_layer_shell_v1_interface = wayland.zwlr_layer_shell_v1_interface
local zwlr_layer_surface_v1_interface = wayland.zwlr_layer_surface_v1_interface

--------------------------------------------------------------------------------
-- Layer surface protocol functions
--------------------------------------------------------------------------------

local ZWLR_LAYER_SHELL_V1_GET_LAYER_SURFACE = 0
local ZWLR_LAYER_SURFACE_V1_SET_SIZE = 0
local ZWLR_LAYER_SURFACE_V1_SET_ANCHOR = 1
local ZWLR_LAYER_SURFACE_V1_SET_EXCLUSIVE_ZONE = 2
local ZWLR_LAYER_SURFACE_V1_ACK_CONFIGURE = 6

function wayland.layer_shell_get_layer_surface(layer_shell, surface, output, layer, namespace)
    local proxy = lib.wl_proxy_marshal_constructor(
        ffi.cast("struct wl_proxy*", layer_shell),
        ZWLR_LAYER_SHELL_V1_GET_LAYER_SURFACE,
        zwlr_layer_surface_v1_interface,
        ffi.cast("void*", nil),
        ffi.cast("struct wl_proxy*", surface),
        ffi.cast("struct wl_proxy*", output),
        ffi.cast("uint32_t", layer),
        namespace
    )
    return ffi.cast("struct zwlr_layer_surface_v1*", proxy)
end

function wayland.layer_surface_set_size(layer_surface, width, height)
    lib.wl_proxy_marshal(
        ffi.cast("struct wl_proxy*", layer_surface),
        ZWLR_LAYER_SURFACE_V1_SET_SIZE,
        ffi.cast("uint32_t", width),
        ffi.cast("uint32_t", height)
    )
end

function wayland.layer_surface_set_anchor(layer_surface, anchor)
    lib.wl_proxy_marshal(
        ffi.cast("struct wl_proxy*", layer_surface),
        ZWLR_LAYER_SURFACE_V1_SET_ANCHOR,
        ffi.cast("uint32_t", anchor)
    )
end

function wayland.layer_surface_set_exclusive_zone(layer_surface, zone)
    lib.wl_proxy_marshal(
        ffi.cast("struct wl_proxy*", layer_surface),
        ZWLR_LAYER_SURFACE_V1_SET_EXCLUSIVE_ZONE,
        ffi.cast("int32_t", zone)
    )
end

function wayland.layer_surface_ack_configure(layer_surface, serial)
    lib.wl_proxy_marshal(
        ffi.cast("struct wl_proxy*", layer_surface),
        ZWLR_LAYER_SURFACE_V1_ACK_CONFIGURE,
        ffi.cast("uint32_t", serial)
    )
end

function wayland.layer_surface_add_listener(layer_surface, listener, data)
    return lib.wl_proxy_add_listener(
        ffi.cast("struct wl_proxy*", layer_surface),
        ffi.cast("void(**)(void)", listener),
        data
    )
end

return wayland
