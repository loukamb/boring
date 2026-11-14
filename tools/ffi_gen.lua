#!/usr/bin/env luajit
-- Generate the committed LuaJIT FFI bindings in shared/ffi/.
--
-- Run at development time, on a machine (or the dev VM) with the -devel
-- headers, pkg-config, gcc and wayland-scanner installed:
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
        protocols = { kind = "server-header", list = server_protocols },
        headers = {
            "<time.h>", "<unistd.h>", "<stdlib.h>",
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
            "<wlr/xwayland.h>",
            "<xkbcommon/xkbcommon.h>",
            "<libinput.h>",
        },
        -- Every declaration from these headers is a root.
        root_files = {
            "/wlr/", "/wayland%-server", "/wayland%-util%.h$", "/xkbcommon/",
            "/libinput%.h$", "%-protocol%.h$",
        },
        -- Plus these individual symbols from system headers.
        root_symbols = { "fork", "execl", "setenv", "getpid", "clock_gettime" },
    },
    {
        name = "client",
        packages = { "wayland-client" },
        defines = {},
        protocols = { kind = "client-header", list = client_protocols },
        headers = {
            "<unistd.h>", "<stdlib.h>", "<sys/mman.h>",
            "<wayland-client.h>",
        },
        root_files = { "/wayland%-client", "/wayland%-util%.h$", "%-protocol%.h$" },
        root_symbols = {
            "fork", "execl", "setenv", "getpid",
            "mmap", "munmap", "close", "shm_open", "shm_unlink", "ftruncate",
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
        run(string.format("wayland-scanner %s %s %s", binding.protocols.kind, sh_quote(xml), sh_quote(header)))
        lines[#lines + 1] = '#include "' .. header .. '"'
    end

    local src = tmp .. "/" .. binding.name .. ".c"
    local f = assert(io.open(src, "w"))
    f:write(table.concat(lines, "\n"), "\n")
    f:close()

    local cflags = run("pkg-config --cflags " .. table.concat(binding.packages, " ")):gsub("\n", " ")
    -- -I tmp: wlroots headers include the generated protocol headers by name.
    return run(string.format("gcc -E %s -I%s %s", cflags, sh_quote(tmp), sh_quote(src)))
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

    local wanted = {}
    local queue = {}
    local function want(i)
        if i and not wanted[i] then
            wanted[i] = true
            queue[#queue + 1] = i
        end
    end

    local root_symbols = {}
    for _, s in ipairs(binding.root_symbols) do root_symbols["id:" .. s] = true end

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
    local body = {}
    for _, d in ipairs(decls) do
        body[#body + 1] = cdecl.format(d)
    end
    local f = assert(io.open(path, "w"))
    f:write(comment, "\n")
    f:write('local ffi = require("ffi")\n')
    if prelude then f:write(prelude, "\n") end
    f:write("\nffi.cdef [[\n", table.concat(body, "\n"), "\n]]\n")
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
