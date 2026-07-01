-- shared/wayland/server.lua
-- Wayland server library using clib.lua builder

local clib = require("shared.clib")
local base = require("shared.wayland.base")
local log = require("shared.log")
local ffi = base.ffi

--------------------------------------------------------------------------------
-- Build the wayland server library
--------------------------------------------------------------------------------

local lib = clib.new()
    :cache("server")
    :soname("wayland-server")
    :soname("wlroots-0.20")
    :soname("xkbcommon")
    :package("pixman-1", "wlroots-0.20", "wayland-server", "xkbcommon")
    :define("WLR_USE_UNSTABLE", "")
    :include("<wlr/util/log.h>")
    :include("<time.h>")
    :include("<wayland-server-core.h>")
    :include("<wlr/backend.h>")
    :include("<wlr/render/allocator.h>")
    :include("<wlr/render/wlr_renderer.h>")
    :include("<wlr/types/wlr_buffer.h>")
    :include("<wlr/interfaces/wlr_buffer.h>")
    :include("<wlr/types/wlr_cursor.h>")
    :include("<wlr/types/wlr_compositor.h>")
    :include("<wlr/types/wlr_data_device.h>")
    :include("<wlr/types/wlr_input_device.h>")
    :include("<wlr/types/wlr_keyboard.h>")
    :include("<wlr/types/wlr_output.h>")
    :include("<wlr/types/wlr_output_layout.h>")
    :include("<wlr/types/wlr_pointer.h>")
    :include("<wlr/types/wlr_scene.h>")
    :include("<wlr/types/wlr_seat.h>")
    :include("<wlr/types/wlr_subcompositor.h>")
    :include("<wlr/types/wlr_xcursor_manager.h>")
    :include("<wlr/types/wlr_xdg_shell.h>")
    :include("<wlr/types/wlr_layer_shell_v1.h>")
    :include("<wlr/types/wlr_foreign_toplevel_management_v1.h>")
    :include("<wlr/types/wlr_fractional_scale_v1.h>")
    :include("<wlr/types/wlr_viewporter.h>")
    :include("<wlr/types/wlr_xdg_output_v1.h>")
    :include("<wlr/types/wlr_gamma_control_v1.h>")
    :include("<wlr/types/wlr_screencopy_v1.h>")
    :include("<wlr/types/wlr_single_pixel_buffer_v1.h>")
    :include("<wlr/types/wlr_xdg_activation_v1.h>")
    :include("<wlr/types/wlr_idle_inhibit_v1.h>")
    :include("<wlr/types/wlr_xdg_decoration_v1.h>")
    :include("<wlr/types/wlr_cursor_shape_v1.h>")
    :include("<wlr/types/wlr_pointer_constraints_v1.h>")
    :include("<wlr/types/wlr_relative_pointer_v1.h>")
    :include("<wlr/render/egl.h>")
    :include("<wlr/render/gles2.h>")
    :include("<wlr/xwayland.h>")
    :include("<xkbcommon/xkbcommon.h>")
    :include('"$DIR/xdg-shell-protocol.h"')
    :include('"$DIR/wlr-layer-shell-unstable-v1-protocol.h"')
    :include('"$DIR/cursor-shape-v1-protocol.h"')
    :include('"$DIR/pointer-constraints-unstable-v1-protocol.h"')
    :include('"$DIR/xdg-decoration-unstable-v1-protocol.h"')
    :include('"$DIR/relative-pointer-unstable-v1-protocol.h"')
    :variable("DIR", "$(mktemp -d)")
    :shell('trap "rm -rf $DIR" EXIT')
    :shell(
        'wayland-scanner server-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml "$DIR/xdg-shell-protocol.h"')
    :shell(
        'wayland-scanner server-header /usr/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml "$DIR/wlr-layer-shell-unstable-v1-protocol.h"')
    :shell(
        'wayland-scanner server-header /usr/share/wayland-protocols/staging/cursor-shape/cursor-shape-v1.xml "$DIR/cursor-shape-v1-protocol.h"')
    :shell(
        'wayland-scanner server-header /usr/share/wayland-protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml "$DIR/pointer-constraints-unstable-v1-protocol.h"')
    :shell(
        'wayland-scanner server-header /usr/share/wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml "$DIR/xdg-decoration-unstable-v1-protocol.h"')
    :shell(
        'wayland-scanner server-header /usr/share/wayland-protocols/unstable/relative-pointer/relative-pointer-unstable-v1.xml "$DIR/relative-pointer-unstable-v1-protocol.h"')
    :cdef([[
typedef int pid_t;
pid_t fork(void);
int execl(const char *path, const char *arg, ...);
int setenv(const char *name, const char *value, int overwrite);

struct libinput_device;
struct libinput_device *wlr_libinput_get_device_handle(struct wlr_input_device *dev);
bool wlr_backend_is_libinput(struct wlr_backend *backend);

struct wlr_egl;
bool wlr_renderer_is_gles2(struct wlr_renderer *renderer);
struct wlr_egl *wlr_gles2_renderer_get_egl(struct wlr_renderer *renderer);

typedef void *EGLDisplay;
typedef void *EGLContext;

EGLDisplay wlr_egl_get_display(struct wlr_egl *egl);
EGLContext wlr_egl_get_context(struct wlr_egl *egl);

bool wlr_texture_is_gles2(struct wlr_texture *texture);
void wlr_gles2_texture_get_attribs(struct wlr_texture *texture, struct wlr_gles2_texture_attribs *attribs);

struct wlr_buffer;
struct wlr_gles2_buffer {
    struct wlr_buffer *buffer;
    struct wlr_renderer *renderer;
};
uint32_t wlr_gles2_renderer_get_current_fbo(struct wlr_renderer *renderer);
uint32_t wlr_gles2_renderer_get_buffer_fbo(struct wlr_renderer *renderer, struct wlr_buffer *buffer);

struct wlr_texture *wlr_texture_from_buffer(struct wlr_renderer *renderer, struct wlr_buffer *buffer);
struct wlr_texture *wlr_texture_from_pixels(struct wlr_renderer *renderer,
    uint32_t fmt, uint32_t stride, uint32_t width, uint32_t height, const void *data);
void wlr_texture_destroy(struct wlr_texture *texture);

struct wlr_scene_buffer *wlr_scene_buffer_create(struct wlr_scene_tree *parent, struct wlr_buffer *buffer);
void wlr_scene_buffer_set_buffer(struct wlr_scene_buffer *scene_buffer, struct wlr_buffer *buffer);
void wlr_scene_buffer_set_dest_size(struct wlr_scene_buffer *scene_buffer, int width, int height);
void wlr_scene_buffer_set_source_box(struct wlr_scene_buffer *scene_buffer, const struct wlr_fbox *box);

struct wlr_render_pass *wlr_output_begin_render_pass(struct wlr_output *output,
    struct wlr_output_state *state, struct wlr_buffer_pass_options *render_options);
bool wlr_render_pass_submit(struct wlr_render_pass *render_pass);

void wlr_output_state_init(struct wlr_output_state *state);
void wlr_output_state_finish(struct wlr_output_state *state);
bool wlr_output_commit_state(struct wlr_output *output, const struct wlr_output_state *state);
bool wlr_output_test_state(struct wlr_output *output, const struct wlr_output_state *state);

enum libinput_config_tap_state {
    LIBINPUT_CONFIG_TAP_DISABLED = 0,
    LIBINPUT_CONFIG_TAP_ENABLED = 1
};

enum libinput_config_accel_profile {
    LIBINPUT_CONFIG_ACCEL_PROFILE_NONE = 0,
    LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT = 1,
    LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE = 2
};

enum libinput_config_scroll_method {
    LIBINPUT_CONFIG_SCROLL_NO_SCROLL = 0,
    LIBINPUT_CONFIG_SCROLL_2FG = 1,
    LIBINPUT_CONFIG_SCROLL_EDGE = 2,
    LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN = 4
};

uint32_t libinput_device_config_tap_get_finger_count(struct libinput_device *device);
int libinput_device_config_tap_set_enabled(struct libinput_device *device, enum libinput_config_tap_state enable);
int libinput_device_config_accel_is_available(struct libinput_device *device);
int libinput_device_config_accel_set_speed(struct libinput_device *device, double speed);
int libinput_device_config_accel_set_profile(struct libinput_device *device, enum libinput_config_accel_profile profile);
int libinput_device_config_scroll_has_natural_scroll(struct libinput_device *device);
int libinput_device_config_scroll_set_natural_scroll_enabled(struct libinput_device *device, int enable);
int libinput_device_config_left_handed_is_available(struct libinput_device *device);
int libinput_device_config_left_handed_set(struct libinput_device *device, int left_handed);

void wlr_output_state_set_scale(struct wlr_output_state *state, float scale);

typedef void (*wlr_scene_buffer_iterator_func_t)(
    struct wlr_scene_buffer *buffer, int sx, int sy, void *user_data);
void wlr_scene_node_for_each_buffer(struct wlr_scene_node *node,
    wlr_scene_buffer_iterator_func_t iterator, void *user_data);
void wlr_scene_buffer_set_dest_size(struct wlr_scene_buffer *scene_buffer,
    int width, int height);
struct wlr_scene_tree *wlr_scene_tree_from_node(struct wlr_scene_node *node);

void wlr_scene_subsurface_tree_set_clip(struct wlr_scene_node *node,
    struct wlr_box *clip);

// Phase 1 - Low Hanging Fruit
struct wlr_cursor_shape_manager_v1;
struct wlr_cursor_shape_manager_v1 *wlr_cursor_shape_manager_v1_create(
    struct wl_display *display, uint32_t version);

// Phase 2 - Easy protocols
struct wlr_pointer_constraints_v1;
struct wlr_pointer_constraints_v1 *wlr_pointer_constraints_v1_create(
    struct wl_display *display);

struct wlr_relative_pointer_manager_v1;
struct wlr_relative_pointer_manager_v1 *wlr_relative_pointer_manager_v1_create(
    struct wl_display *display);

struct wlr_xdg_activation_v1;
struct wlr_xdg_activation_v1 *wlr_xdg_activation_v1_create(
    struct wl_display *display);

struct wlr_idle_inhibit_manager_v1;
struct wlr_idle_inhibit_manager_v1 *wlr_idle_inhibit_v1_create(
    struct wl_display *display);

struct wlr_xdg_decoration_manager_v1;
struct wlr_xdg_decoration_manager_v1 *wlr_xdg_decoration_manager_v1_create(
    struct wl_display *display);

struct wlr_single_pixel_buffer_manager_v1;
struct wlr_single_pixel_buffer_manager_v1 *wlr_single_pixel_buffer_manager_v1_create(
    struct wl_display *display);
]])
    :build()



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
        local ok, fn = pcall(function() return ffi.C[full_name] end)
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
    self._callback = wayland.persistent_callback("wl_notify_func_t", callback)
    self._listener_arr[0].notify = self._callback
    self._user_data = user_data

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
    listener_arr[0].notify = wayland.persistent_callback("wl_notify_func_t", fn)
    table.insert(wayland._prevent_gc, listener_arr)
    return listener_arr
end

function wayland.destroy_listener(listener)
    if not listener or listener == ffi.NULL then
        return
    end

    local listener_arr = listener
    local listener_ptr = listener
    if ffi.istype("struct wl_listener[1]", listener) then
        listener_ptr = listener[0]
    end

    wayland.list_remove(listener_ptr.link)

    local callback = listener_ptr.notify
    for i = #wayland._prevent_gc, 1, -1 do
        local item = wayland._prevent_gc[i]
        if item == listener_arr or item == callback then
            table.remove(wayland._prevent_gc, i)
        end
    end

    if callback and callback ~= ffi.NULL then
        pcall(function()
            callback:free()
        end)
    end
    listener_ptr.notify = nil
end

function wayland.new_listener(callback, user_data)
    return wayland.Listener.new(callback, user_data)
end

return wayland
