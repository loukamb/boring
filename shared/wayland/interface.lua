-- Build `struct wl_interface` descriptions from protocol XML at runtime.
--
-- wayland-scanner normally generates these as C data in each program; libraries
-- only ship the core wl_* ones. Lua clients get any protocol's interfaces
-- from the installed XML instead:
--
--   local iface = interface.get("zwlr_layer_shell_v1", lib)
--   wl.registry_bind(registry, name, iface, 4)
--
-- Built interfaces live for the whole process (libwayland keeps pointers).

local ffi = require("ffi")
local registry = require("shared.wayland.registry")

local interface = {}

local built = {} -- name -> struct wl_interface cdata
local keep = {}  -- every cdata the interfaces point into

local CHAR = { int = "i", uint = "u", fixed = "f", string = "s", object = "o", new_id = "n", array = "a", fd = "h" }

local function cstr(s)
    local c = ffi.new("char[?]", #s + 1, s)
    keep[#keep + 1] = c
    return c
end

-- Signature and argument interfaces for one message, as libwayland wants
-- them: an untyped new_id expands to (string interface, uint version, new_id).
local function describe(msg, lookup)
    local sig, types = {}, {}
    if msg.since and msg.since > 1 then sig[1] = tostring(msg.since) end
    for _, arg in ipairs(msg.args) do
        if arg.type == "new_id" and not arg.interface then
            sig[#sig + 1] = "sun"
            types[#types + 1] = false
            types[#types + 1] = false
            types[#types + 1] = false
        else
            if arg.allow_null then sig[#sig + 1] = "?" end
            sig[#sig + 1] = assert(CHAR[arg.type], "unknown argument type " .. tostring(arg.type))
            local target = (arg.type == "object" or arg.type == "new_id") and arg.interface
            types[#types + 1] = target and lookup(target) or false
        end
    end
    return table.concat(sig), types
end

local function messages(list, lookup)
    local n = 0
    while list[n] do n = n + 1 end
    if n == 0 then return 0, nil end
    local array = ffi.new("struct wl_message[?]", n)
    keep[#keep + 1] = array
    for i = 0, n - 1 do
        local msg = list[i]
        local sig, types = describe(msg, lookup)
        local type_array = ffi.new("const struct wl_interface *[?]", math.max(#types, 1))
        for j, t in ipairs(types) do
            type_array[j - 1] = t or nil
        end
        keep[#keep + 1] = type_array
        array[i].name = cstr(msg.name)
        array[i].signature = cstr(sig)
        array[i].types = type_array
    end
    return n, array
end

--- The wl_interface for a protocol interface name.
---@param name string e.g. "zwlr_layer_surface_v1"
---@param lib table|nil symbol table; core interfaces (wl_surface, ...) come from it
function interface.get(name, lib)
    if built[name] then return built[name] end
    if lib then
        local exported = lib[name .. "_interface"]
        if exported ~= nil then
            built[name] = ffi.cast("const struct wl_interface *", exported)
            return built[name]
        end
    end

    local def, err = registry.get_interface(name)
    if not def then error(err, 2) end

    -- Register before filling in: interfaces may refer to each other.
    local iface = ffi.new("struct wl_interface")
    keep[#keep + 1] = iface
    built[name] = iface
    local function lookup(other) return interface.get(other, lib) end

    iface.name = cstr(name)
    iface.version = def.version
    iface.method_count, iface.methods = messages(def.requests, lookup)
    iface.event_count, iface.events = messages(def.events, lookup)
    return iface
end

return interface
