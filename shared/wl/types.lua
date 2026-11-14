-- Methods on wlroots objects through ffi.metatype.
--
-- For every wl_*/wlr_* struct, `obj:name(...)` calls the C function
-- `<prefix>name(obj, ...)`, where the prefix is the struct name plus "_":
--
--   tree.node:set_position(x, y)     -- wlr_scene_node_set_position(node, x, y)
--   toplevel:set_activated(true)     -- wlr_xdg_toplevel_set_activated(...)
--   output:effective_resolution(w, h)
--
-- Struct fields always win over methods. Methods are resolved on first use and
-- cached in a plain table, so after warm-up a method call is a table hit plus
-- a C call, which the JIT compiles straight through. Extra hand-written
-- methods (`extra` below) cover helpers that don't map 1:1 onto a C function.

local ffi = require("ffi")

local types = {}

-- struct name -> extra Lua methods (may be empty).
local extra = {}

extra.wlr_scene_tree = {}
extra.wlr_box = {
    contains = function(b, x, y)
        return x >= b.x and y >= b.y and x < b.x + b.width and y < b.y + b.height
    end,
}

--- Install method lookup on a struct type. `lib` resolves C symbol names.
local function install(name, lib)
    local prefix = name .. "_"
    local methods = {}
    for k, v in pairs(extra[name] or {}) do
        methods[k] = v
    end
    -- Lazy resolution: a missing method stays nil so `obj:typo()` fails with
    -- "attempt to call method 'typo' (a nil value)".
    setmetatable(methods, {
        __index = function(t, k)
            local fn = lib[prefix .. k]
            if fn ~= nil then
                rawset(t, k, fn)
            end
            return fn
        end,
    })
    ffi.metatype("struct " .. name, { __index = methods })
    return methods
end

local installed = false

--- Install metatypes on every wl_*/wlr_* struct the bindings define.
--- Call once, after the bindings load.
---@param lib table symbol table from shared.ffi.lib
function types.install(lib)
    if installed then
        return
    end
    installed = true
    for _, binding in ipairs({ require("shared.ffi.common"), require("shared.ffi.server") }) do
        for _, name in ipairs(binding.structs) do
            if name:match("^wlr?_") then
                types[name] = install(name, lib)
            end
        end
    end
end

return types
