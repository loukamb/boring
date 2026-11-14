-- Methods on wlroots objects through ffi.metatype.
--
-- For each struct below, `obj:name(...)` calls the C function
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

local structs = {
    "wl_display", "wl_event_loop", "wl_client", "wl_resource",
    "wlr_backend", "wlr_renderer", "wlr_allocator", "wlr_compositor",
    "wlr_output", "wlr_output_layout", "wlr_output_state",
    "wlr_scene", "wlr_scene_node", "wlr_scene_tree", "wlr_scene_rect", "wlr_scene_buffer",
    "wlr_scene_output", "wlr_scene_output_layout",
    "wlr_seat", "wlr_cursor", "wlr_xcursor_manager", "wlr_keyboard", "wlr_input_device",
    "wlr_surface", "wlr_xdg_shell", "wlr_xdg_surface", "wlr_xdg_toplevel", "wlr_xdg_popup",
    "wlr_xdg_toplevel_decoration_v1", "wlr_layer_surface_v1",
    "wlr_xwayland", "wlr_xwayland_surface",
    "wlr_foreign_toplevel_handle_v1", "wlr_buffer", "wlr_texture", "wlr_box",
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

--- Install metatypes for all structs. Call once, after the bindings load.
---@param lib table symbol table from shared.ffi.lib
function types.install(lib)
    if installed then
        return
    end
    installed = true
    for _, name in ipairs(structs) do
        types[name] = install(name, lib)
    end
end

return types
