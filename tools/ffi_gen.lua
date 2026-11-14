#!/usr/bin/env luajit
-- Generate the committed LuaJIT FFI bindings in shared/ffi/.
--
-- Run at development time, on a machine (or the dev VM) with the -devel
-- headers, pkg-config and gcc installed:
--
--   luajit tools/ffi_gen.lua          # or: scripts/vm ffi-gen
--
-- For each binding below, the listed headers are preprocessed and every
-- declaration that comes from a "root" header (wlroots, wayland, xkbcommon,
-- libinput, generated protocol headers), plus a few named libc functions, is
-- kept together with everything those transitively need. System headers only
-- contribute the types that are actually referenced. Declarations needed by
-- more than one binding are hoisted into shared/ffi/common.lua so the bindings
-- can be loaded into the same process.
--
-- The result is plain C that LuaJIT lays out itself, so the files work on any
-- architecture; regenerate them when bumping wlroots and review the diff.

package.path = "./?/init.lua;./?.lua;" .. package.path

local cdecl = require("tools.cdecl")
local wlscanner = require("tools.wlscanner")

local OUT_DIR = "shared/ffi"

--------------------------------------------------------------------------------
-- Binding specifications
--------------------------------------------------------------------------------

local server_protocols = {
    { "wayland-protocols", "stable/xdg-shell/xdg-shell.xml" },
    { "wlr-protocols", "unstable/wlr-layer-shell-unstable-v1.xml" },
    { "wayland-protocols", "staging/cursor-shape/cursor-shape-v1.xml" },
    { "wayland-protocols", "unstable/pointer-constraints/pointer-constraints-unstable-v1.xml" },
    { "wayland-protocols", "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" },
    { "wayland-protocols", "unstable/relative-pointer/relative-pointer-unstable-v1.xml" },
    { "wlr-protocols", "unstable/wlr-output-power-management-unstable-v1.xml" },
}

local client_protocols = {
    { "wlr-protocols", "unstable/wlr-layer-shell-unstable-v1.xml" },
    { "wayland-protocols", "stable/xdg-shell/xdg-shell.xml" },
}

local bindings = {
    {
        name = "server",
        packages = { "wlroots-0.20", "wayland-server", "xkbcommon", "libinput", "pixman-1" },
        defines = { WLR_USE_UNSTABLE = "" },
        protocols = { side = "server", list = server_protocols },
        headers = {
            "<wayland-server-core.h>",
            "<wlr/util/log.h>",
            "<wlr/backend.h>",
            "<wlr/backend/libinput.h>",
            "<wlr/render/allocator.h>",
            "<wlr/render/wlr_renderer.h>",
            "<wlr/render/egl.h>",
            "<wlr/render/gles2.h>",
            "<wlr/types/wlr_buffer.h>",
            "<wlr/interfaces/wlr_buffer.h>",
            "<wlr/types/wlr_cursor.h>",
            "<wlr/types/wlr_compositor.h>",
            "<wlr/types/wlr_data_device.h>",
            "<wlr/types/wlr_input_device.h>",
            "<wlr/types/wlr_keyboard.h>",
            "<wlr/types/wlr_output.h>",
            "<wlr/types/wlr_output_layout.h>",
            "<wlr/types/wlr_pointer.h>",
            "<wlr/types/wlr_scene.h>",
            "<wlr/types/wlr_seat.h>",
            "<wlr/types/wlr_subcompositor.h>",
            "<wlr/types/wlr_xcursor_manager.h>",
            "<wlr/types/wlr_xdg_shell.h>",
            "<wlr/types/wlr_layer_shell_v1.h>",
            "<wlr/types/wlr_foreign_toplevel_management_v1.h>",
            "<wlr/types/wlr_fractional_scale_v1.h>",
            "<wlr/types/wlr_viewporter.h>",
            "<wlr/types/wlr_xdg_output_v1.h>",
            "<wlr/types/wlr_gamma_control_v1.h>",
            "<wlr/types/wlr_screencopy_v1.h>",
            "<wlr/types/wlr_single_pixel_buffer_v1.h>",
            "<wlr/types/wlr_xdg_activation_v1.h>",
            "<wlr/types/wlr_idle_inhibit_v1.h>",
            "<wlr/types/wlr_xdg_decoration_v1.h>",
            "<wlr/types/wlr_cursor_shape_v1.h>",
            "<wlr/types/wlr_pointer_constraints_v1.h>",
            "<wlr/types/wlr_relative_pointer_v1.h>",
            "<wlr/types/wlr_primary_selection.h>",
            "<wlr/types/wlr_primary_selection_v1.h>",
            "<wlr/types/wlr_virtual_keyboard_v1.h>",
            "<wlr/types/wlr_virtual_pointer_v1.h>",
            "<wlr/types/wlr_session_lock_v1.h>",
            "<wlr/types/wlr_text_input_v3.h>",
            "<wlr/types/wlr_input_method_v2.h>",
            "<wlr/types/wlr_ext_image_capture_source_v1.h>",
            "<wlr/types/wlr_ext_image_copy_capture_v1.h>",
            "<wlr/types/wlr_xdg_toplevel_icon_v1.h>",
            "<wlr/types/wlr_xdg_dialog_v1.h>",
            "<wlr/types/wlr_presentation_time.h>",
            "<wlr/types/wlr_linux_dmabuf_v1.h>",
            "<wlr/types/wlr_idle_notify_v1.h>",
            "<wlr/types/wlr_ext_foreign_toplevel_list_v1.h>",
            "<wlr/types/wlr_ext_workspace_v1.h>",
            "<wlr/types/wlr_alpha_modifier_v1.h>",
            "<wlr/types/wlr_content_type_v1.h>",
            "<wlr/types/wlr_keyboard_shortcuts_inhibit_v1.h>",
            "<wlr/types/wlr_output_power_management_v1.h>",
            "<wlr/types/wlr_data_control_v1.h>",
            "<wlr/types/wlr_ext_data_control_v1.h>",
            "<wlr/types/wlr_xdg_system_bell_v1.h>",
            "<wlr/types/wlr_pointer_gestures_v1.h>",
            "<wlr/types/wlr_tearing_control_v1.h>",
            "<wlr/types/wlr_output_management_v1.h>",
            "<wlr/types/wlr_xdg_foreign_registry.h>",
            "<wlr/types/wlr_xdg_foreign_v1.h>",
            "<wlr/types/wlr_xdg_foreign_v2.h>",
            "<wlr/xwayland.h>",
            "<xkbcommon/xkbcommon.h>",
            "<libinput.h>",
        },
        -- Every declaration from these headers is a root.
        root_files = {
            "/wlr/", "/wayland%-server", "/wayland%-util%.h$", "/xkbcommon/",
            "/libinput%.h$", "%-protocol%.h$", "/wayland%-protocols/.*%-enum%.h$",
        },
        -- Plus these individual symbols from system headers.
        root_symbols = {},
    },
    {
        name = "client",
        packages = { "wayland-client" },
        defines = {},
        protocols = { side = "client", list = client_protocols },
        headers = {
            "<wayland-client.h>",
        },
        root_files = { "/wayland%-client", "/wayland%-util%.h$", "%-protocol%.h$" },
        root_symbols = {},
    },
    {
        -- D-Bus client libraries (shared/dbus): sd-bus (libsystemd, and the
        -- same API in libelogind and libbasu) and libdbus. Declarations
        -- only; shared/dbus loads whichever is installed.
        name = "dbus",
        packages = { "libsystemd", "dbus-1" },
        defines = {},
        protocols = { side = "client", list = {} },
        headers = { "<systemd/sd-bus.h>", "<dbus/dbus.h>" },
        root_files = { "/systemd/sd%-bus", "/dbus%-1%.0/dbus/", "/dbus%-arch%-deps%.h$" },
        root_symbols = {},
        -- sd_bus_vtable has a 56-bit bitfield and its flags enum a 64-bit
        -- value; boring registers objects with sd_bus_add_object instead.
        skip = { "struct:sd_bus_vtable", "id:_SD_BUS_VTABLE_CAPABILITY_MASK" },
    },
    {
        -- The libc functions boring calls. Only arch-independent types: e.g.
        -- statx rather than stat, whose layout differs between architectures.
        name = "libc",
        packages = {},
        defines = { _GNU_SOURCE = "" },
        protocols = { side = "client", list = {} },
        headers = {
            "<unistd.h>", "<stdlib.h>", "<fcntl.h>", "<poll.h>", "<dirent.h>",
            "<signal.h>", "<time.h>", "<sys/inotify.h>", "<sys/stat.h>",
            "<sys/wait.h>", "<sys/mman.h>", "<sys/socket.h>", "<sys/un.h>", "<errno.h>", "<string.h>",
        },
        root_files = {},
        root_symbols = {
            -- processes and environment
            "fork", "execl", "execvp", "_exit", "kill", "waitpid", "getpid", "chdir", "getcwd",
            "getenv", "setenv", "unsetenv", "sigemptyset", "sigprocmask", "setsid",
            -- files
            "open", "read", "write", "close", "fcntl", "poll", "statx",
            "opendir", "readdir", "closedir",
            "inotify_init1", "inotify_add_watch", "inotify_rm_watch", "struct inotify_event",
            -- shared memory
            "mmap", "munmap", "shm_open", "shm_unlink", "ftruncate",
            -- time
            "clock_gettime",
            -- Unix sockets (ipc)
            "socket", "bind", "listen", "accept4", "connect", "shutdown", "unlink", "chmod",
            "getuid", "struct sockaddr_un",
            -- memory wlroots frees (clipboard mime types), directories
            "strdup", "free", "mkdir",
        },
        -- Integer macros, evaluated by the C compiler and emitted as enum constants.
        constants = {
            "IN_ACCESS", "IN_MODIFY", "IN_ATTRIB", "IN_CLOSE_WRITE", "IN_CLOSE_NOWRITE",
            "IN_OPEN", "IN_MOVED_FROM", "IN_MOVED_TO", "IN_CREATE", "IN_DELETE",
            "IN_DELETE_SELF", "IN_MOVE_SELF", "IN_UNMOUNT", "IN_Q_OVERFLOW", "IN_IGNORED",
            "IN_ISDIR", "IN_NONBLOCK", "IN_CLOEXEC",
            "O_RDONLY", "O_RDWR", "O_CREAT", "O_EXCL", "O_NONBLOCK", "O_CLOEXEC",
            "F_GETFL", "F_SETFL", "POLLIN", "POLLOUT", "POLLERR", "POLLHUP",
            "SIGTERM", "SIGKILL", "SIGINT", "SIGCHLD", "SIG_SETMASK", "WNOHANG",
            "S_IFMT", "S_IFDIR", "S_IFREG", "AT_FDCWD", "STATX_TYPE", "STATX_MODE",
            "PROT_READ", "PROT_WRITE", "MAP_SHARED", "CLOCK_MONOTONIC",
            "AF_UNIX", "SOCK_STREAM", "SOCK_CLOEXEC", "SOCK_NONBLOCK", "SHUT_WR",
            "EAGAIN", "EINTR",
        },
    },
}

--------------------------------------------------------------------------------
-- Shell helpers
--------------------------------------------------------------------------------

local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Run a shell command and return its stdout. LuaJIT's popen():close() doesn't
-- report the exit status, so the command echoes it on a marker line; stderr
-- goes to a file so warnings never mix into the output we parse.
local function run(cmd)
    local err_path = os.tmpname()
    local p = assert(io.popen(string.format("{ %s; } 2>%s; echo \"\n__exit=$?\"", cmd, sh_quote(err_path))))
    local out = p:read("*a")
    p:close()
    local ef = io.open(err_path, "r")
    local stderr = ef and ef:read("*a") or ""
    if ef then ef:close() end
    os.remove(err_path)

    local body, code = out:match("^(.*)\n__exit=(%d+)\n?$")
    if code ~= "0" then
        error(string.format("command failed (exit %s): %s\n%s", tostring(code), cmd, stderr), 0)
    end
    return body
end

local function pkg_var(pkg, var)
    local p = io.popen("pkg-config --variable=" .. var .. " " .. pkg .. " 2>/dev/null")
    local v = p and p:read("*l")
    if p then p:close() end
    return (v and v ~= "") and v or nil
end

local function modversion(pkg)
    local p = io.popen("pkg-config --modversion " .. pkg .. " 2>/dev/null")
    local v = p and p:read("*l")
    if p then p:close() end
    return v or "?"
end

local function protocol_dir(pkg)
    return pkg_var(pkg, "pkgdatadir") or ("/usr/share/" .. pkg)
end

--------------------------------------------------------------------------------
-- Generation
--------------------------------------------------------------------------------

local function preprocess(binding, tmp)
    local lines = {}
    for name, value in pairs(binding.defines) do
        lines[#lines + 1] = "#define " .. name .. " " .. value
    end
    for _, h in ipairs(binding.headers) do
        lines[#lines + 1] = "#include " .. h
    end
    for _, proto in ipairs(binding.protocols.list) do
        local xml = protocol_dir(proto[1]) .. "/" .. proto[2]
        local header = tmp .. "/" .. xml:match("([^/]+)%.xml$") .. "-protocol.h"
        local f = assert(io.open(header, "w"))
        f:write(wlscanner.header_from_file(xml, binding.protocols.side))
        f:close()
        lines[#lines + 1] = '#include "' .. header .. '"'
    end

    local src = tmp .. "/" .. binding.name .. ".c"
    local f = assert(io.open(src, "w"))
    f:write(table.concat(lines, "\n"), "\n")
    f:close()

    local cflags = #binding.packages > 0
        and run("pkg-config --cflags " .. table.concat(binding.packages, " ")):gsub("\n", " ")
        or ""
    -- -I tmp: wlroots headers include the generated protocol headers by name.
    return run(string.format("gcc -E %s -I%s %s", cflags, sh_quote(tmp), sh_quote(src)))
end

-- Evaluate integer macros with the C compiler; returns parsed declarations for
-- `enum { NAME = value, ... };`.
local function constants_decls(binding, tmp)
    if not binding.constants or #binding.constants == 0 then return {} end
    local c = {}
    for name, value in pairs(binding.defines) do c[#c + 1] = "#define " .. name .. " " .. value end
    for _, h in ipairs(binding.headers) do c[#c + 1] = "#include " .. h end
    c[#c + 1] = "#include <stdio.h>"
    c[#c + 1] = "int main(void) {"
    for _, name in ipairs(binding.constants) do
        c[#c + 1] = string.format('printf("%s %%lld\\n", (long long)(%s));', name, name)
    end
    c[#c + 1] = "return 0; }"
    local src = tmp .. "/" .. binding.name .. "-constants.c"
    local f = assert(io.open(src, "w"))
    f:write(table.concat(c, "\n"), "\n")
    f:close()
    run(string.format("gcc %s -o %s/constants", sh_quote(src), sh_quote(tmp)))
    local out = run(tmp .. "/constants")

    local entries = {}
    for name, value in out:gmatch("(%S+) (%-?%d+)") do
        local n = tonumber(value)
        if n < -2147483648 or n > 2147483647 then
            error(string.format("constant %s = %s doesn't fit an enum", name, value), 0)
        end
        entries[#entries + 1] = string.format("%s = %s", name, value)
    end
    return cdecl.parse('# 1 "<constants>"\nenum { ' .. table.concat(entries, ", ") .. " };\n")
end

local function matches_any(s, patterns)
    for _, p in ipairs(patterns) do
        if s:find(p) then return true end
    end
    return false
end

-- Pick the declarations a binding needs, in source order.
local function select_decls(binding, decls)
    -- Who defines what. Only types and constants satisfy references; a
    -- declaration never needs a function prototype.
    local full_def, any_def, type_def = {}, {}, {}
    for i, d in ipairs(decls) do
        for key, how in pairs(d.defines) do
            any_def[key] = any_def[key] or i
            if how == "full" then
                full_def[key] = full_def[key] or i
            elseif how == "typedef" or how == "enumerator" then
                type_def[key] = type_def[key] or i
            end
        end
    end

    -- Declarations LuaJIT can't take (e.g. 64-bit bitfields) and the
    -- binding doesn't need: pointers to a skipped struct stay incomplete.
    local skip = {}
    for _, key in ipairs(binding.skip or {}) do skip[key] = true end
    local function skipped(d)
        for key in pairs(d.defines) do
            if skip[key] then return true end
        end
        return false
    end

    local wanted = {}
    local queue = {}
    local function want(i)
        if i and not wanted[i] and not skipped(decls[i]) then
            wanted[i] = true
            queue[#queue + 1] = i
        end
    end

    local root_symbols = {}
    for _, s in ipairs(binding.root_symbols) do
        local tag, name = s:match("^(%a+) ([%w_]+)$")
        root_symbols[tag and (tag .. ":" .. name) or ("id:" .. s)] = true
    end

    for i, d in ipairs(decls) do
        if d.kind ~= "static" then
            if matches_any(d.file, binding.root_files) then
                want(i)
            else
                for key in pairs(d.defines) do
                    if root_symbols[key] then want(i) end
                end
            end
        end
    end

    while #queue > 0 do
        local d = decls[table.remove(queue)]
        for key in pairs(d.refs) do
            if key:match("^id:") then
                want(type_def[key])
            else
                want(full_def[key] or any_def[key])
            end
        end
    end

    -- Emit in order, once per definition.
    local seen, out = {}, {}
    for i, d in ipairs(decls) do
        if wanted[i] and not cdecl.is_builtin_typedef(d) then
            local new = false
            for key, how in pairs(d.defines) do
                local prev = seen[key]
                if not prev or (prev == "forward" and how == "full") then
                    new = true
                end
            end
            if next(d.defines) == nil then new = true end
            if new then
                for key, how in pairs(d.defines) do
                    if seen[key] ~= "full" then seen[key] = how end
                end
                out[#out + 1] = d
            end
        end
    end
    return out
end

local function header_comment(title, versions)
    local lines = {
        "-- " .. title,
        "--",
        "-- GENERATED by tools/ffi_gen.lua. Do not edit; regenerate instead.",
        "-- Generated from:",
    }
    for _, v in ipairs(versions) do
        lines[#lines + 1] = "--   " .. v
    end
    return table.concat(lines, "\n") .. "\n"
end

local function write_binding(path, comment, prelude, decls)
    local body, structs = {}, {}
    for _, d in ipairs(decls) do
        body[#body + 1] = cdecl.format(d)
        for key, how in pairs(d.defines) do
            local name = key:match("^struct:(.+)$")
            if name and how == "full" then structs[#structs + 1] = string.format("%q", name) end
        end
    end
    table.sort(structs)
    local f = assert(io.open(path, "w"))
    f:write(comment, "\n")
    f:write('local ffi = require("ffi")\n')
    if prelude then f:write(prelude, "\n") end
    f:write("\nffi.cdef [[\n", table.concat(body, "\n"), "\n]]\n")
    -- The structs this file defines (shared/wl/types.lua gives them methods).
    f:write("\nreturn {\n    structs = {\n")
    for i = 1, #structs, 4 do
        f:write("        ", table.concat(structs, ", ", i, math.min(i + 3, #structs)), ",\n")
    end
    f:write("    },\n}\n")
    f:close()
    print(string.format("wrote %s (%d declarations)", path, #decls))
end

local function main()
    local tmp = run("mktemp -d"):gsub("%s+$", "")
    local ok, err = pcall(function()
        local selected = {}
        for _, b in ipairs(bindings) do
            local decls = cdecl.parse(preprocess(b, tmp))
            selected[b.name] = select_decls(b, decls)
            for _, d in ipairs(constants_decls(b, tmp)) do
                table.insert(selected[b.name], d)
            end
        end

        -- Hoist declarations every binding has (by identical text) into common.
        local text_count, text_of = {}, {}
        for _, b in ipairs(bindings) do
            local here = {}
            for _, d in ipairs(selected[b.name]) do
                local text = table.concat(d.tokens, " ")
                text_of[d] = text
                if not here[text] then
                    here[text] = true
                    text_count[text] = (text_count[text] or 0) + 1
                end
            end
        end

        local common, common_seen = {}, {}
        local per_binding = {}
        for _, b in ipairs(bindings) do
            local own = {}
            for _, d in ipairs(selected[b.name]) do
                local text = text_of[d]
                if text_count[text] > 1 then
                    if not common_seen[text] then
                        common_seen[text] = true
                        common[#common + 1] = d
                    end
                else
                    own[#own + 1] = d
                end
            end
            per_binding[b.name] = own
        end

        -- A full struct/enum defined differently in two bindings would make
        -- them impossible to load together.
        local owner = {}
        for _, b in ipairs(bindings) do
            for _, d in ipairs(per_binding[b.name]) do
                for key, how in pairs(d.defines) do
                    if how == "full" or how == "enumerator" then
                        if owner[key] and owner[key] ~= b.name then
                            error(string.format("%s is defined differently in %s and %s",
                                key, owner[key], b.name), 0)
                        end
                        owner[key] = b.name
                    end
                end
            end
        end

        local all_pkgs, seen_pkg = {}, {}
        for _, b in ipairs(bindings) do
            for _, p in ipairs(b.packages) do
                if not seen_pkg[p] then
                    seen_pkg[p] = true
                    all_pkgs[#all_pkgs + 1] = p .. " " .. modversion(p)
                end
            end
        end
        all_pkgs[#all_pkgs + 1] = "wayland-protocols " .. modversion("wayland-protocols")

        write_binding(OUT_DIR .. "/common.lua",
            header_comment("Declarations shared by the server and client bindings.", all_pkgs),
            nil, common)
        for _, b in ipairs(bindings) do
            local versions = {}
            for _, p in ipairs(b.packages) do versions[#versions + 1] = p .. " " .. modversion(p) end
            if #versions == 0 then
                versions[1] = run("getconf GNU_LIBC_VERSION 2>/dev/null || echo libc"):gsub("%s+$", "")
            end
            write_binding(OUT_DIR .. "/" .. b.name .. ".lua",
                header_comment(b.name:gsub("^%l", string.upper) .. " binding.", versions),
                'require("shared.ffi.common")', per_binding[b.name])
        end
    end)
    run("rm -rf " .. sh_quote(tmp))
    if not ok then
        io.stderr:write("ffi_gen: ", tostring(err), "\n")
        os.exit(1)
    end
end

main()
