-- shared/wayland/client.lua
-- Wayland client library using clib.lua builder

local clib = require("shared.clib")
local base = require("shared.wayland.base")
local ffi = base.ffi

--------------------------------------------------------------------------------
-- Build the wayland client library
--------------------------------------------------------------------------------

local lib = clib.new()
    :cache("client")
    :soname("wayland-client")
    :package("wayland-client")
    :include("<time.h>")
    :include("<wayland-client.h>")
    :include("<wayland-client-protocol.h>")
    :include('"$DIR/wlr-layer-shell-unstable-v1-client-protocol.h"')
    :include('"$DIR/xdg-shell-client-protocol.h"')
    :variable("DIR", "$(mktemp -d)")
    :shell('trap "rm -rf $DIR" EXIT')
    :shell(
        'wayland-scanner client-header /usr/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml "$DIR/wlr-layer-shell-unstable-v1-client-protocol.h" 2>/dev/null')
    :shell(
        'wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml "$DIR/xdg-shell-client-protocol.h" 2>/dev/null')
    :cdef([[
typedef int pid_t;
pid_t fork(void);
int execl(const char *path, const char *arg, ...);
int setenv(const char *name, const char *value, int overwrite);

void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset);
int munmap(void *addr, size_t length);
int close(int fd);

int shm_open(const char *name, int oflag, unsigned int mode);
int shm_unlink(const char *name);
int ftruncate(int fd, long length);

struct zwlr_layer_shell_v1;
struct zwlr_layer_surface_v1;

struct zwlr_layer_surface_v1_listener {
    void (*configure)(void *data, struct zwlr_layer_surface_v1 *surface,
                      uint32_t serial, uint32_t width, uint32_t height);
    void (*closed)(void *data, struct zwlr_layer_surface_v1 *surface);
};
]])
    :build()



--------------------------------------------------------------------------------
-- Create wayland namespace with base inheritance and wl_ prefix lookup
--------------------------------------------------------------------------------

local wayland = {}

-- Store library references
wayland._lib = lib
wayland._wl = lib -- Legacy accessor
wayland._ffi = ffi
wayland._C = ffi.C
wayland.bit = base.bit
wayland._prevent_gc = {}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

wayland.WL_SHM_FORMAT_ARGB8888 = 0
wayland.WL_SHM_FORMAT_XRGB8888 = 1

wayland.PROT_READ = 0x1
wayland.PROT_WRITE = 0x2
wayland.MAP_SHARED = 0x01

wayland.O_RDWR = 2
wayland.O_CREAT = 64
wayland.O_EXCL = 128

-- Metatable that tries: 1) wl_ prefix in lib, 2) base module
setmetatable(wayland, {
    __index = function(_, key)
        -- Try wl_ prefix lookup in lib
        local full_name = "wl_" .. key
        local ok, fn = pcall(function() return lib[full_name] end)
        if ok and fn ~= nil then
            return fn
        end
        -- Try ffi.C for wl_ prefix
        ok, fn = pcall(function() return ffi.C[full_name] end)
        if ok and fn ~= nil then
            return fn
        end
        -- Fall back to base module
        return base[key]
    end
})

--------------------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------------------

function wayland.persistent_callback(signature, fn)
    return base.persistent_callback(wayland, signature, fn)
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

function wayland.create_shm_buffer(shm, width, height, format)
    local stride = width * 4
    local size = stride * height

    local name = string.format("/wl_shm-%d-%d", os.time(), math.random(100000))
    local fd = ffi.C.shm_open(name, base.bit.bor(wayland.O_RDWR, wayland.O_CREAT, wayland.O_EXCL), 0x180)
    if fd < 0 then
        return nil, nil, "shm_open failed"
    end
    ffi.C.shm_unlink(name)

    if ffi.C.ftruncate(fd, size) < 0 then
        ffi.C.close(fd)
        return nil, nil, "ftruncate failed"
    end

    local data = ffi.C.mmap(nil, size, base.bit.bor(wayland.PROT_READ, wayland.PROT_WRITE), wayland.MAP_SHARED, fd, 0)
    if data == ffi.cast("void*", -1) then
        ffi.C.close(fd)
        return nil, nil, "mmap failed"
    end

    local pool = wayland.shm_create_pool(shm, fd, size)
    local buffer = wayland.shm_pool_create_buffer(pool, 0, width, height, stride, format)
    wayland.shm_pool_destroy(pool)
    ffi.C.close(fd)

    return buffer, data
end

--------------------------------------------------------------------------------
-- Layer shell protocol definitions
--------------------------------------------------------------------------------

local function cstr(s)
    local c = ffi.new("char[?]", #s + 1, s)
    table.insert(wayland._prevent_gc, c)
    return c
end

local layer_shell_strings = {
    name = cstr("zwlr_layer_shell_v1"),
    get_layer_surface = cstr("get_layer_surface"),
    get_layer_surface_sig = cstr("no?ous"),
    destroy = cstr("destroy"),
    empty_sig = cstr(""),
}

local layer_surface_strings = {
    name = cstr("zwlr_layer_surface_v1"),
    set_size = cstr("set_size"),
    set_anchor = cstr("set_anchor"),
    set_exclusive_zone = cstr("set_exclusive_zone"),
    set_margin = cstr("set_margin"),
    set_keyboard_interactivity = cstr("set_keyboard_interactivity"),
    get_popup = cstr("get_popup"),
    ack_configure = cstr("ack_configure"),
    destroy = cstr("destroy"),
    set_layer = cstr("set_layer"),
    set_exclusive_edge = cstr("set_exclusive_edge"),
    configure = cstr("configure"),
    closed = cstr("closed"),
    sig_uu = cstr("uu"),
    sig_u = cstr("u"),
    sig_i = cstr("i"),
    sig_iiii = cstr("iiii"),
    sig_o = cstr("o"),
    sig_uuu = cstr("uuu"),
    sig_empty = cstr(""),
}

local layer_surface_v1_types = ffi.new("const struct wl_interface*[5]", {
    nil,
    lib.wl_surface_interface,
    lib.wl_output_interface,
    nil,
    nil,
})

local layer_shell_v1_requests = ffi.new("struct wl_message[2]", {
    { layer_shell_strings.get_layer_surface, layer_shell_strings.get_layer_surface_sig, layer_surface_v1_types },
    { layer_shell_strings.destroy,           layer_shell_strings.empty_sig,             nil },
})

local zwlr_layer_shell_v1_interface = ffi.new("struct wl_interface", {
    layer_shell_strings.name, 4, 2, layer_shell_v1_requests, 0, nil
})
wayland.zwlr_layer_shell_v1_interface = zwlr_layer_shell_v1_interface

local layer_surface_v1_requests = ffi.new("struct wl_message[10]", {
    { layer_surface_strings.set_size,                   layer_surface_strings.sig_uu,    nil },
    { layer_surface_strings.set_anchor,                 layer_surface_strings.sig_u,     nil },
    { layer_surface_strings.set_exclusive_zone,         layer_surface_strings.sig_i,     nil },
    { layer_surface_strings.set_margin,                 layer_surface_strings.sig_iiii,  nil },
    { layer_surface_strings.set_keyboard_interactivity, layer_surface_strings.sig_u,     nil },
    { layer_surface_strings.get_popup,                  layer_surface_strings.sig_o,     nil },
    { layer_surface_strings.ack_configure,              layer_surface_strings.sig_u,     nil },
    { layer_surface_strings.destroy,                    layer_surface_strings.sig_empty, nil },
    { layer_surface_strings.set_layer,                  layer_surface_strings.sig_u,     nil },
    { layer_surface_strings.set_exclusive_edge,         layer_surface_strings.sig_u,     nil },
})

local layer_surface_v1_events = ffi.new("struct wl_message[2]", {
    { layer_surface_strings.configure, layer_surface_strings.sig_uuu,   nil },
    { layer_surface_strings.closed,    layer_surface_strings.sig_empty, nil },
})

local zwlr_layer_surface_v1_interface = ffi.new("struct wl_interface", {
    layer_surface_strings.name, 4, 10, layer_surface_v1_requests, 2, layer_surface_v1_events
})
wayland.zwlr_layer_surface_v1_interface = zwlr_layer_surface_v1_interface

table.insert(wayland._prevent_gc, layer_surface_v1_types)
table.insert(wayland._prevent_gc, layer_shell_v1_requests)
table.insert(wayland._prevent_gc, layer_surface_v1_requests)
table.insert(wayland._prevent_gc, layer_surface_v1_events)
table.insert(wayland._prevent_gc, zwlr_layer_shell_v1_interface)
table.insert(wayland._prevent_gc, zwlr_layer_surface_v1_interface)

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
