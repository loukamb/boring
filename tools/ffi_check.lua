#!/usr/bin/env luajit
-- Check that the generated bindings in shared/ffi lay out structs exactly like
-- the C compiler does. Run after tools/ffi_gen.lua (scripts/vm ffi-gen does).
--
-- Compiles a small C program against the real headers that prints sizeof and
-- offsetof for the structs boring touches most, and compares with LuaJIT.

package.path = "./?/init.lua;./?.lua;" .. package.path

local ffi = require("ffi")
require("shared.ffi.server")

local checks = {
    { "wl_listener", { "link", "notify" } },
    { "wl_signal", { "listener_list" } },
    { "wlr_backend", { "events" } },
    { "wlr_output", { "events", "data", "width", "renderer", "name" } },
    { "wlr_output_layout", { "outputs", "events" } },
    { "wlr_input_device", { "type", "name", "events", "data" } },
    { "wlr_keyboard", { "keymap", "modifiers", "events", "num_keycodes", "keycodes" } },
    { "wlr_keyboard_key_event", { "time_msec", "keycode", "update_state", "state" } },
    { "wlr_pointer_motion_absolute_event", { "pointer", "time_msec", "x", "y" } },
    { "wlr_pointer_button_event", { "pointer", "time_msec", "button", "state" } },
    { "wlr_cursor", { "x", "y", "events" } },
    { "wlr_seat", { "keyboard_state", "pointer_state", "events", "data" } },
    { "wlr_scene_node", { "type", "parent", "link", "enabled", "x", "y", "events", "data" } },
    { "wlr_scene_tree", { "node", "children" } },
    { "wlr_scene_rect", { "node", "width", "height", "color" } },
    { "wlr_scene_buffer", { "node", "buffer", "events" } },
    { "wlr_surface", { "resource", "current", "pending", "events", "data" } },
    { "wlr_xdg_surface", { "surface", "role", "initialized", "initial_commit", "events", "data", "geometry" } },
    { "wlr_xdg_toplevel", { "base", "events", "title", "app_id", "current", "pending", "requested" } },
    { "wlr_xdg_popup", { "base", "parent", "events" } },
    { "wlr_xdg_toplevel_decoration_v1", { "toplevel", "events", "requested_mode", "current" } },
    { "wlr_layer_surface_v1", { "surface", "output", "current", "pending", "initial_commit", "events", "data" } },
    { "wlr_xwayland_surface", { "window_id", "surface", "title", "events", "data", "override_redirect", "x", "y" } },
    { "wlr_foreign_toplevel_handle_v1", { "events", "data" } },
    { "wlr_box", { "x", "y", "width", "height" } },
}

local headers = {
    "wlr/backend.h", "wlr/types/wlr_output.h", "wlr/types/wlr_output_layout.h",
    "wlr/types/wlr_input_device.h", "wlr/types/wlr_keyboard.h", "wlr/types/wlr_pointer.h",
    "wlr/types/wlr_cursor.h", "wlr/types/wlr_seat.h", "wlr/types/wlr_scene.h",
    "wlr/types/wlr_compositor.h", "wlr/types/wlr_xdg_shell.h", "wlr/types/wlr_xdg_decoration_v1.h",
    "wlr/types/wlr_layer_shell_v1.h", "wlr/xwayland.h",
    "wlr/types/wlr_foreign_toplevel_management_v1.h",
}

local function sh(cmd)
    local p = assert(io.popen("{ " .. cmd .. "; } 2>&1; echo \"\n__exit=$?\""))
    local out = p:read("*a")
    p:close()
    local body, code = out:match("^(.*)\n__exit=(%d+)\n?$")
    if code ~= "0" then
        io.stderr:write("ffi_check: command failed: ", cmd, "\n", body, "\n")
        os.exit(1)
    end
    return body
end

local tmp = sh("mktemp -d"):gsub("%s+$", "")
local proto_dir = sh("pkg-config --variable=pkgdatadir wlr-protocols 2>/dev/null || echo /usr/share/wlr-protocols"):gsub("%s+$", "")
sh(string.format("wayland-scanner server-header %s/unstable/wlr-layer-shell-unstable-v1.xml %s/wlr-layer-shell-unstable-v1-protocol.h",
    proto_dir, tmp))

local c = { "#define WLR_USE_UNSTABLE", "#include <stddef.h>", "#include <stdio.h>" }
for _, h in ipairs(headers) do c[#c + 1] = "#include <" .. h .. ">" end
c[#c + 1] = "int main(void) {"

local expected = {}
for _, chk in ipairs(checks) do
    local s = chk[1]
    c[#c + 1] = string.format('printf("%s %%zu\\n", sizeof(struct %s));', s, s)
    expected[#expected + 1] = string.format("%s %d", s, ffi.sizeof("struct " .. s))
    for _, field in ipairs(chk[2]) do
        if ffi.offsetof("struct " .. s, field) == nil then
            io.stderr:write(string.format("ffi_check: struct %s has no field %s in the bindings\n", s, field))
            os.exit(1)
        end
        c[#c + 1] = string.format('printf("%s.%s %%zu\\n", offsetof(struct %s, %s));', s, field, s, field)
        expected[#expected + 1] = string.format("%s.%s %d", s, field, ffi.offsetof("struct " .. s, field))
    end
end
c[#c + 1] = "return 0; }"

local f = assert(io.open(tmp .. "/layout.c", "w"))
f:write(table.concat(c, "\n"), "\n")
f:close()

local cflags = sh("pkg-config --cflags wlroots-0.20 pixman-1 wayland-server xkbcommon"):gsub("\n", " ")
sh(string.format("gcc %s -I%s %s/layout.c -o %s/layout", cflags, tmp, tmp, tmp))
local actual = sh(tmp .. "/layout")
sh("rm -rf " .. tmp)

local mismatches = 0
local i = 0
for line in actual:gmatch("[^\n]+") do
    i = i + 1
    if line ~= expected[i] then
        mismatches = mismatches + 1
        print(string.format("MISMATCH  C: %-50s  LuaJIT: %s", line, tostring(expected[i])))
    end
end

if mismatches > 0 or i ~= #expected then
    print(string.format("ffi_check: %d mismatches in %d checks", mismatches, #expected))
    os.exit(1)
end
print(string.format("ffi_check: %d layout checks match the C compiler", #expected))
