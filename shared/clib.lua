--- C Library builder for FFI declarations
--- Provides a fluent API for generating LuaJIT FFI bindings from C headers.
---@class shared.clib

local ffi = require("ffi")
local log = require("shared.log")

local clib = {}

--------------------------------------------------------------------------------
-- Scanner (preprocessor and cdef generator)
--------------------------------------------------------------------------------

local predefined_types = {
    ["va_list"] = true,
    ["__builtin_va_list"] = true,
    ["__gnuc_va_list"] = true,
    ["ptrdiff_t"] = true,
    ["size_t"] = true,
    ["wchar_t"] = true,
    ["int8_t"] = true,
    ["int16_t"] = true,
    ["int32_t"] = true,
    ["int64_t"] = true,
    ["uint8_t"] = true,
    ["uint16_t"] = true,
    ["uint32_t"] = true,
    ["uint64_t"] = true,
    ["intptr_t"] = true,
    ["uintptr_t"] = true,
    ["ssize_t"] = true,
}

local skip_patterns = {
    "_Float128",
    "_Float64x",
    "_Float32x",
    "_Float64",
    "_Float32",
    "__float128",
    "__m128",
    "__m256",
    "__m512",
    "__builtin_",
    "__REDIRECT",
}

local function remove_balanced_parens(str, start_pos)
    if str:sub(start_pos, start_pos) ~= "(" then
        return str, start_pos
    end
    local depth = 0
    local i = start_pos
    while i <= #str do
        local c = str:sub(i, i)
        if c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then
                return str:sub(1, start_pos - 1) .. str:sub(i + 1), start_pos
            end
        end
        i = i + 1
    end
    return str, start_pos
end

local function remove_attributes(code)
    local result = code

    local i = 1
    while i <= #result do
        local attr_start = result:find("__attribute__%s*%(", i)
        if not attr_start then break end
        local paren_start = result:find("%(", attr_start)
        if paren_start then
            result, _ = remove_balanced_parens(result, paren_start)
            result = result:sub(1, attr_start - 1) .. result:sub(paren_start)
        else
            i = attr_start + 1
        end
    end

    result = result:gsub("__alignof__%s*%b()", "8")
    result = result:gsub("__extension__%s*", "")
    result = result:gsub("__restrict", "")
    result = result:gsub("__inline__", "inline")
    result = result:gsub("__inline", "inline")
    result = result:gsub("__const", "const")
    result = result:gsub("__volatile", "volatile")
    result = result:gsub("__signed__", "signed")
    result = result:gsub("__asm__%s*%b()", "")
    result = result:gsub("__asm%s*%b()", "")
    result = result:gsub("__typeof__%s*%b()", "void")
    result = result:gsub("__builtin_offsetof%s*%b()", "0")
    result = result:gsub("%[%[%w+%]%]", "")
    result = result:gsub("%[%[%w+%s*%b()%]%]", "")
    result = result:gsub("%[static%s+%d+%]", "[4]")
    result = result:gsub("%[static%s+%w+%]", "[]")

    -- Strip C integer literal suffixes (L, LL, U, UL, ULL, etc)
    result = result:gsub("(%d)ULL", "%1")
    result = result:gsub("(%d)LL", "%1")
    result = result:gsub("(%d)UL", "%1")
    result = result:gsub("(%d)L", "%1")
    result = result:gsub("(%d)U", "%1")

    return result
end

local function is_static_inline(line)
    return line:match("^%s*static%s+inline") or
        line:match("^%s*static%s+__inline") or
        line:match("^%s*__attribute__%s*%([^)]*%)%s*static%s+inline")
end

local function is_predefined_typedef(line)
    for typename in pairs(predefined_types) do
        if line:match("typedef%s+.-%s+" .. typename .. "%s*;") or
            line:match("typedef%s+.-%s+" .. typename .. "%s*%[") then
            return true
        end
    end
    return false
end

local function has_problematic_types(line)
    for _, pattern in ipairs(skip_patterns) do
        if line:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

local function get_pkg_config_cflags(packages)
    if not packages or #packages == 0 then
        return ""
    end
    local pkg_list = table.concat(packages, " ")
    local handle = io.popen("pkg-config --cflags " .. pkg_list .. " 2>/dev/null")
    if not handle then return "" end
    local flags = handle:read("*l") or ""
    handle:close()
    return flags
end

local function get_pkg_config_modversions(packages)
    if not packages or #packages == 0 then
        return ""
    end

    local versions = {}
    for _, pkg in ipairs(packages) do
        local handle = io.popen("pkg-config --modversion " .. pkg .. " 2>/dev/null")
        local version = handle and handle:read("*l") or nil
        local ok = handle and handle:close()
        table.insert(versions, pkg .. "=" .. (ok and version or "missing"))
    end
    return table.concat(versions, "\n")
end

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--------------------------------------------------------------------------------
-- Builder class
--------------------------------------------------------------------------------

local Builder = {}
Builder.__index = Builder

---Create a new library builder
---@return table Builder instance
function clib.new()
    local self = setmetatable({}, Builder)
    self._sonames = {}
    self._packages = {}
    self._includes = {}
    self._defines = {}
    self._variables = {}
    self._shell_scripts = {}
    self._extra_cdef = {}
    self._on_preprocess = nil
    self._on_parse = nil
    self._declared_types = {}
    self._cache_name = nil -- Optional cache file name for cdef caching
    return self
end

---Add a shared library to load (.so file)
---@param name string Library soname (e.g., "wayland-server", "wlroots-0.19")
---@return table self
function Builder:soname(name)
    table.insert(self._sonames, name)
    return self
end

---Add a pkg-config package for cflags
---@param ... string Package names
---@return table self
function Builder:package(...)
    for _, pkg in ipairs({ ... }) do
        table.insert(self._packages, pkg)
    end
    return self
end

---Add a header file to include
---@param header string Header path (e.g., "<stdio.h>", '"local.h"')
---@return table self
function Builder:include(header)
    table.insert(self._includes, "#include " .. header)
    return self
end

---Add a C preprocessor define
---@param name string Macro name
---@param value string|nil Macro value (optional)
---@return table self
function Builder:define(name, value)
    if value and value ~= "" then
        table.insert(self._defines, "#define " .. name .. " " .. value)
    else
        table.insert(self._defines, "#define " .. name)
    end
    return self
end

---Set a shell variable for preprocessing
---@param name string Variable name
---@param value string Variable value or shell expression
---@return table self
function Builder:variable(name, value)
    table.insert(self._variables, name .. "=" .. value)
    return self
end

---Add shell script to run before preprocessing
---@param script string Shell script content
---@return table self
function Builder:shell(script)
    table.insert(self._shell_scripts, script)
    return self
end

---Add extra cdef content (not preprocessed)
---@param content string Raw FFI cdef content
---@return table self
function Builder:cdef(content)
    table.insert(self._extra_cdef, content)
    return self
end

---Set callback to modify headers before preprocessing
---@param fn function(headers: string): string
---@return table self
function Builder:on_preprocess(fn)
    self._on_preprocess = fn
    return self
end

---Set callback to modify cdef after parsing
---@param fn function(cdef: string): string
---@return table self
function Builder:on_parse(fn)
    self._on_parse = fn
    return self
end

---Enable cdef caching with the given name
---Cache is stored in ~/.config/boring/ffi-cache/<name>.cdef
---Cache is bypassed when BORING_DEBUG env var is set
---@param name string Cache file name (without extension)
---@return table self
function Builder:cache(name)
    self._cache_name = name
    return self
end

---Generate cdef from headers
---@return string Generated cdef
function Builder:_generate_cdef()
    self._declared_types = {}

    -- Build headers string
    local headers_parts = {}
    for _, def in ipairs(self._defines) do
        table.insert(headers_parts, def)
    end
    for _, inc in ipairs(self._includes) do
        table.insert(headers_parts, inc)
    end
    local headers_str = table.concat(headers_parts, "\n")

    if self._on_preprocess then
        headers_str = self._on_preprocess(headers_str)
    end

    -- Build shell setup
    local setup_parts = {}
    for _, var in ipairs(self._variables) do
        table.insert(setup_parts, var)
    end
    for _, script in ipairs(self._shell_scripts) do
        table.insert(setup_parts, script)
    end
    local setup_cmd = table.concat(setup_parts, "\n")
    if setup_cmd ~= "" then
        setup_cmd = setup_cmd .. "\n"
    end

    local pkg_cflags = get_pkg_config_cflags(self._packages)
    local extra_includes = ""
    if #self._shell_scripts > 0 or #self._variables > 0 then
        extra_includes = '-I"$DIR"'
    end

    local err_path = os.tmpname()
    local gcc_cmd = string.format(
        [[set -e
exec 2>%s
%sgcc -E -P -x c - %s %s -I/usr/include <<'EOF'
%s
EOF
]], shell_quote(err_path), setup_cmd, pkg_cflags, extra_includes, headers_str)


    local handle = io.popen(gcc_cmd)
    if not handle then
        error("clib: Failed to run gcc preprocessor")
    end
    local preprocessed = handle:read("*a")
    local ok, reason, status = handle:close()
    local err_file = io.open(err_path, "r")
    local stderr = err_file and err_file:read("*a") or ""
    if err_file then
        err_file:close()
    end
    os.remove(err_path)

    if not ok then
        error(string.format("clib: Preprocessor failed (%s %s): %s", tostring(reason), tostring(status), stderr))
    end

    if not preprocessed or preprocessed == "" then
        error("clib: Preprocessor produced no output" .. (stderr ~= "" and (": " .. stderr) or ""))
    end



    preprocessed = remove_attributes(preprocessed)

    local lines = {}
    for line in preprocessed:gmatch("[^\n]+") do
        table.insert(lines, line)
    end

    local output = {}
    local in_static_inline = false
    local brace_depth = 0

    for _, line in ipairs(lines) do
        if line:match("^#") then
            goto continue
        end

        if line:match("^%s*$") then
            goto continue
        end

        if is_static_inline(line) then
            in_static_inline = true
            brace_depth = 0
        end

        if in_static_inline then
            for c in line:gmatch(".") do
                if c == "{" then brace_depth = brace_depth + 1 end
                if c == "}" then brace_depth = brace_depth - 1 end
            end
            if brace_depth <= 0 and line:match("}") then
                in_static_inline = false
            end
            goto continue
        end

        if is_predefined_typedef(line) then
            goto continue
        end

        if has_problematic_types(line) then
            goto continue
        end

        if self:_should_skip_forward_decl(line) then
            goto continue
        end

        self:_mark_type_declared(line)

        if line:match("^%s*inline%s+") then
            in_static_inline = true
            brace_depth = 0
            goto continue
        end

        table.insert(output, line)

        ::continue::
    end

    local generated = table.concat(output, "\n")

    generated = generated:gsub("__attribute%s*%b()", "")
    generated = generated:gsub("__asm%s*%b()", "")
    generated = generated:gsub("__volatile%s*%b()", "")
    generated = generated:gsub(";;", ";")
    generated = generated:gsub("struct%s+(%w+)%s*{%s*}", "struct %1 { int _dummy; }")

    if self._on_parse then
        generated = self._on_parse(generated)
    end


    return generated
end

function Builder:_should_skip_forward_decl(line)
    local kind = line:match("^%s*(struct%s+%S+)%s*;")
    if not kind then
        kind = line:match("^%s*(union%s+%S+)%s*;")
    end
    if not kind then
        kind = line:match("^%s*(enum%s+%S+)%s*;")
    end
    if kind then
        if self._declared_types[kind] then
            return true
        end
        self._declared_types[kind] = "forward"
        return false
    end
    return false
end

function Builder:_mark_type_declared(line)
    local kind = line:match("^%s*(struct%s+%S+)%s*{") or
        line:match("^%s*(union%s+%S+)%s*{") or
        line:match("^%s*(enum%s+%S+)%s*{")
    if kind then
        self._declared_types[kind] = "full"
    end
end

---Build the library and return a callable namespace
---@return table Library namespace
function Builder:build()
    local generated_cdef

    -- Cache handling
    local use_cache = self._cache_name ~= nil and os.getenv("BORING_DEBUG") == nil
    local cache_dir = os.getenv("HOME") .. "/.config/boring/ffi-cache"
    local cache_path = cache_dir .. "/" .. (self._cache_name or "default") .. ".cdef"
    local input_hash = nil

    if use_cache then
        -- Compute hash of all inputs that affect cdef generation
        local hash_mod = require("shared.hash")
        local hash_input = table.concat(self._includes, "\n") .. "\n" ..
            table.concat(self._defines, "\n") .. "\n" ..
            table.concat(self._packages, "\n") .. "\n" ..
            get_pkg_config_cflags(self._packages) .. "\n" ..
            get_pkg_config_modversions(self._packages) .. "\n" ..
            table.concat(self._variables, "\n") .. "\n" ..
            table.concat(self._extra_cdef, "\n") .. "\n" ..
            table.concat(self._shell_scripts, "\n")
        input_hash = hash_mod.short(hash_input)

        -- Try to read from cache
        local cache_file = io.open(cache_path, "r")
        if cache_file then
            local first_line = cache_file:read("*l")
            local cached_hash = first_line and first_line:match("^%-%- hash: (%x+)")
            if cached_hash == input_hash then
                -- Cache hit - read the rest
                generated_cdef = cache_file:read("*a")
                cache_file:close()
            else
                cache_file:close()
            end
        end
    end

    -- Generate cdef if not cached
    if not generated_cdef then
        generated_cdef = self:_generate_cdef()

        -- Write to cache if enabled
        if use_cache and input_hash then
            -- Create cache directory
            os.execute("mkdir -p " .. cache_dir)
            local cache_file = io.open(cache_path, "w")
            if cache_file then
                cache_file:write("-- hash: " .. input_hash .. "\n")
                cache_file:write(generated_cdef)
                cache_file:close()
            end
        end
    end

    -- Load libraries
    local libs = {}
    for _, soname in ipairs(self._sonames) do
        local lib_ok, lib = pcall(ffi.load, soname .. ".so")
        if lib_ok then
            table.insert(libs, lib)
        else
            log.warn("clib: Failed to load %s: %s", soname, lib)
        end
    end

    local ok, err = pcall(function()
        ffi.cdef(generated_cdef)
    end)
    if not ok then
        log.error("clib: Failed to apply generated cdef: %s", err)
        error("clib: cdef error: " .. err)
    end

    -- Apply extra cdef
    for _, extra in ipairs(self._extra_cdef) do
        ok, err = pcall(function()
            ffi.cdef(extra)
        end)
        if not ok then
            log.warn("clib: Extra cdef warning (may be harmless): %s", err)
        end
    end

    -- Create namespace with metatable for symbol lookup
    local namespace = {
        _libs = libs,
        _C = ffi.C,
        ffi = ffi,
    }

    setmetatable(namespace, {
        __index = function(self, key)
            -- Try each loaded library
            for _, lib in ipairs(self._libs) do
                local ok, fn = pcall(function() return lib[key] end)
                if ok and fn ~= nil then
                    rawset(self, key, fn)
                    return fn
                end
            end
            -- Fall back to ffi.C
            local ok, fn = pcall(function() return ffi.C[key] end)
            if ok then
                rawset(self, key, fn)
                return fn
            end
            return nil
        end
    })


    return namespace
end

return clib
