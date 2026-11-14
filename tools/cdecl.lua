-- Minimal C declaration parser for generating LuaJIT FFI bindings.
--
-- Input is `gcc -E` output (with line markers). Output is a list of top-level
-- declarations, each knowing the file it came from, the names it defines and
-- the names it references. This is just enough C to filter and order header
-- declarations; it is not a compiler. Used by tools/ffi_gen.lua at dev time
-- only, never at runtime.

local cdecl = {}

local keywords = {}
for word in ([[
    auto break case char const continue default do double else enum extern
    float for goto if inline int long register restrict return short signed
    sizeof static struct switch typedef union unsigned void volatile while
    _Bool _Complex _Atomic _Noreturn _Thread_local __attribute__ __asm__
    __alignof__ __typeof__ __restrict __signed__ __const __volatile__
    __inline __inline__ __extension__ __restrict__ __thread
]]):gmatch("%S+") do
    keywords[word] = true
end
cdecl.keywords = keywords

-- Types LuaJIT knows natively. Their typedefs in system headers are dropped,
-- and references to them need no declaration.
local builtin_types = {}
for word in ([[
    va_list __builtin_va_list __gnuc_va_list ptrdiff_t size_t ssize_t wchar_t
    int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t
    intptr_t uintptr_t bool
]]):gmatch("%S+") do
    builtin_types[word] = true
end
cdecl.builtin_types = builtin_types

-- Tokens dropped outright.
local noise = {
    __extension__ = true, __restrict = true, __restrict__ = true, restrict = true,
    __inline = true, __inline__ = true, inline = true, _Noreturn = true,
}

-- Attribute items LuaJIT understands and that affect layout; everything else
-- inside __attribute__((...)) is dropped.
local kept_attributes = {
    aligned = true, __aligned__ = true, packed = true, __packed__ = true,
}

local punctuators = {
    "...", "<<=", ">>=", "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=",
    "&&", "||", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "##",
}

local function is_ident(tok)
    return tok:match("^[%a_][%w_]*$") ~= nil
end
cdecl.is_ident = is_ident

-- Tokenize one line of C. Appends to `out`, tagging each token with `file`.
local function tokenize_line(line, file, out)
    local i, n = 1, #line
    while i <= n do
        local c = line:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c:match("[%a_]") then
            local j = line:find("[^%w_]", i) or n + 1
            out[#out + 1] = { line:sub(i, j - 1), file }
            i = j
        elseif c:match("%d") or (c == "." and line:sub(i + 1, i + 1):match("%d")) then
            local j = line:find("[^%w%.]", i) or n + 1
            local num = line:sub(i, j - 1)
            -- Integer suffixes (1U, 2UL, 0x3ULL): LuaJIT doesn't need them.
            if not num:find("[%.pP]") and not num:find("^0[xX]") then
                num = num:gsub("[uUlL]+$", "")
            elseif num:find("^0[xX]") then
                num = num:gsub("([%x])[uUlL]+$", "%1")
            end
            out[#out + 1] = { num, file }
            i = j
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = line:sub(j, j)
                if d == "\\" then
                    j = j + 2
                elseif d == c then
                    break
                else
                    j = j + 1
                end
            end
            out[#out + 1] = { line:sub(i, j), file }
            i = j + 1
        else
            local tok = c
            for _, p in ipairs(punctuators) do
                if line:sub(i, i + #p - 1) == p then
                    tok = p
                    break
                end
            end
            out[#out + 1] = { tok, file }
            i = i + #tok
        end
    end
end

--- Tokenize preprocessor output. Line markers (`# 12 "file.h" 1`) set the file
--- that following tokens are attributed to.
---@param text string
---@return table tokens  list of { text, file }
function cdecl.tokenize(text)
    local tokens = {}
    local file = "<input>"
    for line in text:gmatch("[^\n]*") do
        local marker = line:match('^#%s*%d+%s+"(.-)"') or line:match('^#%s*line%s+%d+%s+"(.-)"')
        if marker then
            file = marker
        elseif not line:match("^%s*#") then
            tokenize_line(line, file, tokens)
        end
    end
    return tokens
end

-- Index just past the group that opens at tokens[i] ("(", "[" or "{").
local closer = { ["("] = ")", ["["] = "]", ["{"] = "}" }
local function skip_group(tokens, i)
    local open = tokens[i][1]
    local close = closer[open]
    local depth = 0
    for j = i, #tokens do
        local t = tokens[j][1]
        if t == open then
            depth = depth + 1
        elseif t == close then
            depth = depth - 1
            if depth == 0 then
                return j + 1
            end
        end
    end
    error("cdecl: unbalanced " .. open .. " in " .. tostring(tokens[i][2]))
end

-- Split a comma-separated token list at depth 0.
local function split_commas(toks)
    local parts, cur, depth = {}, {}, 0
    for _, t in ipairs(toks) do
        if t == "(" or t == "[" or t == "{" then
            depth = depth + 1
        elseif t == ")" or t == "]" or t == "}" then
            depth = depth - 1
        end
        if t == "," and depth == 0 then
            parts[#parts + 1] = cur
            cur = {}
        else
            cur[#cur + 1] = t
        end
    end
    parts[#parts + 1] = cur
    return parts
end

--- Remove compiler noise: unknown attributes, `__extension__`, `restrict`,
--- C23 `[[...]]` attributes and `_Static_assert`. Keeps `aligned`/`packed`
--- attributes (they change layout) and `__asm__("sym")` (symbol renames).
---@param tokens table list of { text, file }
---@return table tokens
function cdecl.clean(tokens)
    local out = {}
    local i = 1
    while i <= #tokens do
        local tok = tokens[i]
        local t = tok[1]
        if noise[t] then
            i = i + 1
        elseif t == "__attribute__" or t == "__attribute" then
            local after = skip_group(tokens, i + 1)
            -- Inner items live between "((" and "))".
            local inner = {}
            for j = i + 3, after - 3 do
                inner[#inner + 1] = tokens[j][1]
            end
            local kept = {}
            for _, item in ipairs(split_commas(inner)) do
                if kept_attributes[item[1]] then
                    kept[#kept + 1] = table.concat(item, " ")
                end
            end
            if #kept > 0 then
                local file = tok[2]
                out[#out + 1] = { "__attribute__", file }
                out[#out + 1] = { "(", file }
                out[#out + 1] = { "(", file }
                -- Re-tokenize the kept items (they're simple: `aligned ( 8 )`).
                for k, item in ipairs(kept) do
                    if k > 1 then out[#out + 1] = { ",", file } end
                    tokenize_line(item, file, out)
                end
                out[#out + 1] = { ")", file }
                out[#out + 1] = { ")", file }
            end
            i = after
        elseif t == "__asm" or t == "asm" then
            out[#out + 1] = { "__asm__", tok[2] }
            i = i + 1
        elseif t == "_Static_assert" or t == "static_assert" then
            -- Drop through the terminating ';'.
            i = skip_group(tokens, i + 1)
            if tokens[i] and tokens[i][1] == ";" then i = i + 1 end
        elseif t == "[" and tokens[i + 1] and tokens[i + 1][1] == "[" then
            i = skip_group(tokens, i)
        elseif t == "static" and out[#out] and out[#out][1] == "[" then
            -- C99 `float m[static 9]` parameter: same as `float m[9]`.
            i = i + 1
        elseif t == "__const" then
            out[#out + 1] = { "const", tok[2] }
            i = i + 1
        elseif t == "__signed__" then
            out[#out + 1] = { "signed", tok[2] }
            i = i + 1
        elseif t == "__volatile__" then
            out[#out + 1] = { "volatile", tok[2] }
            i = i + 1
        else
            out[#out + 1] = tok
            i = i + 1
        end
    end
    return out
end

--- Split cleaned tokens into top-level declarations. Function definitions
--- (`static inline` helpers in headers) are dropped entirely.
---@param tokens table
---@return table decls  list of { tokens = {string...}, file = string }
function cdecl.split(tokens)
    local decls = {}
    local cur, file = {}, nil
    local i = 1
    while i <= #tokens do
        local t, f = tokens[i][1], tokens[i][2]
        if #cur == 0 then file = f end
        if t == "{" then
            local prev = cur[#cur]
            if prev == ")" then
                -- Function body: discard the whole definition.
                i = skip_group(tokens, i)
                cur = {}
            else
                local stop = skip_group(tokens, i)
                for j = i, stop - 1 do cur[#cur + 1] = tokens[j][1] end
                i = stop
            end
        elseif t == "(" or t == "[" then
            local stop = skip_group(tokens, i)
            for j = i, stop - 1 do cur[#cur + 1] = tokens[j][1] end
            i = stop
        elseif t == ";" then
            if #cur > 0 then
                decls[#decls + 1] = { tokens = cur, file = file }
            end
            cur = {}
            i = i + 1
        else
            cur[#cur + 1] = t
            i = i + 1
        end
    end
    return decls
end

-- Copy of `toks` without brace bodies and without __attribute__/__asm__ groups.
local function strip_bodies(toks)
    local out = {}
    local i = 1
    while i <= #toks do
        local t = toks[i]
        if t == "{" or ((t == "__attribute__" or t == "__asm__") and toks[i + 1] == "(") then
            local depth = 0
            local open = (t == "{") and "{" or "("
            local close = closer[open]
            local j = (t == "{") and i or i + 1
            while j <= #toks do
                if toks[j] == open then
                    depth = depth + 1
                elseif toks[j] == close then
                    depth = depth - 1
                    if depth == 0 then break end
                end
                j = j + 1
            end
            i = j + 1
        else
            out[#out + 1] = t
            i = i + 1
        end
    end
    return out
end

-- The identifier a declarator declares: `x`, `*x`, `x[3]`, `f(args)`,
-- `(*fp)(args)`, `(*f(args))(int)`.
local function declarator_name(toks)
    for i, t in ipairs(toks) do
        if t == "(" and (toks[i + 1] == "*" or toks[i + 1] == "^") then
            for j = i + 1, #toks do
                local u = toks[j]
                if is_ident(u) and not keywords[u] then
                    return u
                end
            end
        end
        if t == "(" or t == "[" then
            break
        end
    end
    local name
    for _, t in ipairs(toks) do
        if t == "(" or t == "[" or t == ":" then break end
        if is_ident(t) and not keywords[t] then name = t end
    end
    return name
end

--- Analyse one declaration: what it defines and what it references.
--- Keys are "struct:X", "union:X", "enum:X" for tags and "id:X" for
--- everything in the ordinary namespace (typedefs, functions, variables,
--- enumerators).
---@param decl table { tokens, file }
function cdecl.analyse(decl)
    local toks = decl.tokens
    local defines, refs = {}, {}
    decl.defines, decl.refs = defines, refs
    decl.kind = "decl"

    if toks[1] == "static" then
        decl.kind = "static" -- static data/functions can't be bound
        return decl
    end

    -- Tags: `struct X {` defines X; `struct X` elsewhere references X.
    for i = 1, #toks - 1 do
        local t = toks[i]
        if (t == "struct" or t == "union" or t == "enum") and is_ident(toks[i + 1]) then
            local key = t .. ":" .. toks[i + 1]
            if toks[i + 2] == "{" then
                defines[key] = "full"
            else
                refs[key] = true
            end
        end
    end

    -- Forward declaration: `struct X;`
    if #toks == 2 and (toks[1] == "struct" or toks[1] == "union" or toks[1] == "enum") then
        decl.kind = "forward"
        defines[toks[1] .. ":" .. toks[2]] = "forward"
        refs[toks[1] .. ":" .. toks[2]] = nil
        return decl
    end

    -- Enumerators: identifiers right after `{` or `,` inside an enum body.
    for i = 1, #toks do
        if toks[i] == "enum" then
            local j = i + 1
            if is_ident(toks[j]) then j = j + 1 end
            if toks[j] == "{" then
                local depth = 0
                for k = j, #toks do
                    local t = toks[k]
                    if t == "{" or t == "(" then
                        depth = depth + 1
                    elseif t == "}" or t == ")" then
                        depth = depth - 1
                        if depth == 0 then break end
                    elseif depth == 1 and (toks[k - 1] == "{" or toks[k - 1] == ",") and is_ident(t) then
                        defines["id:" .. t] = "enumerator"
                    end
                end
            end
        end
    end

    -- Declarators (typedef names, functions, variables).
    local outer = strip_bodies(toks)
    if outer[1] == "typedef" then decl.kind = "typedef" end
    local parts = split_commas(outer)
    for idx, part in ipairs(parts) do
        local name = declarator_name(part)
        -- `struct X { ... };` has no declarator; its "name" would be the tag.
        local is_tag_only = idx == 1 and #part == 2 and
            (part[1] == "struct" or part[1] == "union" or part[1] == "enum")
        if name and not is_tag_only then
            -- Skip the tag identifier of `struct X;`-like leftovers.
            defines["id:" .. name] = decl.kind == "typedef" and "typedef" or "symbol"
        end
    end

    -- References: every identifier that isn't a keyword or defined here.
    for i, t in ipairs(toks) do
        local prev = toks[i - 1]
        if is_ident(t) and not keywords[t] and not builtin_types[t]
            and prev ~= "struct" and prev ~= "union" and prev ~= "enum"
            and not defines["id:" .. t] then
            refs["id:" .. t] = true
        end
    end
    for key in pairs(defines) do refs[key] = nil end

    -- Parameter names and struct field names show up as references too; they
    -- just won't resolve to anything, which callers must tolerate.
    return decl
end

--- Parse preprocessor output into analysed declarations.
function cdecl.parse(text)
    local decls = cdecl.split(cdecl.clean(cdecl.tokenize(text)))
    for _, d in ipairs(decls) do
        cdecl.analyse(d)
    end
    return decls
end

--- Is this declaration a typedef of a type LuaJIT already knows?
function cdecl.is_builtin_typedef(decl)
    if decl.kind ~= "typedef" then return false end
    for key in pairs(decl.defines) do
        local name = key:match("^id:(.*)")
        if name and builtin_types[name] then return true end
    end
    return false
end

--- Render a declaration as readable C.
function cdecl.format(decl)
    local out = {}
    local indent = 0
    local enum_stack = {}
    local line_start = true
    local prev

    local function emit(s)
        if line_start then
            out[#out + 1] = string.rep("    ", indent)
            line_start = false
        elseif prev and not (s == "," or s == ";" or s == ")" or s == "]" or s == "[")
            and not (prev == "(" or prev == "[" or prev == "*")
            and not (s == "(" and (is_ident(prev) and not keywords[prev] or prev == ")" or prev == "]")) then
            out[#out + 1] = " "
        end
        out[#out + 1] = s
        prev = s
    end
    local function newline()
        out[#out + 1] = "\n"
        line_start = true
        prev = nil
    end

    local toks = decl.tokens
    for i, t in ipairs(toks) do
        if t == "{" then
            local is_enum = toks[i - 1] == "enum" or toks[i - 2] == "enum"
            enum_stack[#enum_stack + 1] = is_enum
            emit("{")
            newline()
            indent = indent + 1
        elseif t == "}" then
            local was_enum = table.remove(enum_stack)
            if not line_start then newline() end
            indent = indent - 1
            emit("}")
            if was_enum then end
        elseif t == ";" then
            emit(";")
            newline()
        elseif t == "," and enum_stack[#enum_stack] then
            emit(",")
            newline()
        else
            emit(t)
        end
    end
    emit(";")
    return table.concat(out)
end

return cdecl
