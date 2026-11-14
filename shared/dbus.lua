-- D-Bus through whichever client library is installed (ARCHITECTURE.md,
-- "D-Bus"): sd-bus (libsystemd, libelogind or libbasu) first, libdbus
-- otherwise. boring doesn't implement the protocol.
--
--   local dbus = require("shared.dbus")
--   local bus, err = dbus.session({ watch = function(fd, fn) ... return stop end })
--   if not bus then log.warn("no D-Bus: %s", err) end
--   bus:own("org.example.Thing")
--   bus:export("/org/example/Thing", "org.example.Thing", {
--       Hello = { "s", "s", function(name) return "hello " .. name end },  -- in, out, fn
--   })
--   bus:emit("/org/example/Thing", "org.example.Thing", "Changed", "us", 1, "x")
--   bus.backend   -- "sd-bus (libsystemd.so.0)", "libdbus (libdbus-1.so.3)"
--
-- `watch(fd, fn)` hooks the connection into an event loop (fn when fd is
-- readable; returns a function that stops). Values: basic types, arrays
-- (Lua lists), dicts (a{..}: Lua tables), variants (their value; a{sv}
-- values that aren't basic or arrays of basics come back nil), structs
-- (lists). Methods that error reply org.freedesktop.DBus.Error.Failed.

local bit = require("bit")
local ffi = require("ffi")
require("shared.ffi.dbus")

local dbus = {}

local SD_BUS_LIBS = { "libsystemd.so.0", "libelogind.so.0", "libbasu.so.0" }
local LIBDBUS_LIBS = { "libdbus-1.so.3" }

local function load_any(names)
    for _, name in ipairs(names) do
        local ok, lib = pcall(ffi.load, name)
        if ok then return lib, name end
    end
end

--------------------------------------------------------------------------------
-- Signatures
--------------------------------------------------------------------------------

-- The complete type starting at `pos`, and the position after it.
local function next_type(sig, pos)
    local c = sig:sub(pos, pos)
    if c == "a" then
        local _, after = next_type(sig, pos + 1)
        return sig:sub(pos, after - 1), after
    elseif c == "(" or c == "{" then
        local close = c == "(" and ")" or "}"
        local p = pos + 1
        while sig:sub(p, p) ~= close do
            if p > #sig then error("bad signature " .. sig) end
            local _, after = next_type(sig, p)
            p = after
        end
        return sig:sub(pos, p), p + 1
    end
    return c, pos + 1
end

--- The complete types of a signature, as a list.
function dbus.split(sig)
    local out, pos = {}, 1
    while pos <= #sig do
        local t
        t, pos = next_type(sig, pos)
        out[#out + 1] = t
    end
    return out
end

local BASIC = {
    y = "uint8_t[1]", n = "int16_t[1]", q = "uint16_t[1]", i = "int32_t[1]", u = "uint32_t[1]",
    x = "int64_t[1]", t = "uint64_t[1]", d = "double[1]", h = "int32_t[1]",
    s = "const char *[1]", o = "const char *[1]", g = "const char *[1]",
}
local STRING = { s = true, o = true, g = true }

local function from_box(t, box)
    if STRING[t] then return box[0] ~= nil and ffi.string(box[0]) or "" end
    if t == "b" then return box[0] ~= 0 end
    return tonumber(box[0])
end

-- The variant signature for a Lua value.
local function variant_type(v)
    local tv = type(v)
    if tv == "string" then return "s" end
    if tv == "boolean" then return "b" end
    if tv == "number" then return (v == math.floor(v) and v >= -2147483648 and v <= 2147483647) and "i" or "d" end
    if tv == "table" and type(v[1]) == "string" then return "as" end
    return nil
end

-- Is this a type the readers return (anything else in a variant is skipped)?
local function readable(t)
    if BASIC[t] or t == "b" then return true end
    if t:sub(1, 1) == "a" then return readable(t:sub(2)) end
    return false
end

--------------------------------------------------------------------------------
-- sd-bus
--------------------------------------------------------------------------------

local sd = {}

function sd.read(lib, m, t)
    local c = t:sub(1, 1)
    if BASIC[t] or t == "b" then
        local box = ffi.new(t == "b" and "int[1]" or BASIC[t])
        if lib.sd_bus_message_read_basic(m, t:byte(), box) <= 0 then return nil end
        return from_box(t, box)
    elseif c == "a" then
        local elem = t:sub(2)
        if lib.sd_bus_message_enter_container(m, ("a"):byte(), elem) <= 0 then return nil end
        local out = {}
        if elem:sub(1, 1) == "{" then
            local inner = elem:sub(2, -2)
            local kt, after = next_type(inner, 1)
            local vt = inner:sub(after)
            while lib.sd_bus_message_enter_container(m, ("e"):byte(), inner) > 0 do
                local k = sd.read(lib, m, kt)
                local v = sd.read(lib, m, vt)
                lib.sd_bus_message_exit_container(m)
                if k ~= nil then out[k] = v end
            end
        else
            while lib.sd_bus_message_at_end(m, 0) == 0 do
                out[#out + 1] = sd.read(lib, m, elem)
            end
        end
        lib.sd_bus_message_exit_container(m)
        return out
    elseif c == "v" then
        local type_out, contents = ffi.new("char[1]"), ffi.new("const char *[1]")
        if lib.sd_bus_message_peek_type(m, type_out, contents) <= 0 then return nil end
        local inner = ffi.string(contents[0])
        lib.sd_bus_message_enter_container(m, ("v"):byte(), inner)
        local v = nil
        if readable(inner) then v = sd.read(lib, m, inner) else lib.sd_bus_message_skip(m, inner) end
        lib.sd_bus_message_exit_container(m)
        return v
    elseif c == "(" then
        local inner = t:sub(2, -2)
        lib.sd_bus_message_enter_container(m, ("r"):byte(), inner)
        local out = {}
        for _, it in ipairs(dbus.split(inner)) do out[#out + 1] = sd.read(lib, m, it) end
        lib.sd_bus_message_exit_container(m)
        return out
    end
    lib.sd_bus_message_skip(m, t)
    return nil
end

function sd.write(lib, m, t, v)
    local c = t:sub(1, 1)
    if STRING[t] then
        lib.sd_bus_message_append_basic(m, t:byte(), tostring(v or ""))
    elseif BASIC[t] or t == "b" then
        local box = ffi.new(t == "b" and "int[1]" or BASIC[t])
        box[0] = t == "b" and (v and 1 or 0) or (v or 0)
        lib.sd_bus_message_append_basic(m, t:byte(), box)
    elseif c == "a" then
        local elem = t:sub(2)
        lib.sd_bus_message_open_container(m, ("a"):byte(), elem)
        if elem:sub(1, 1) == "{" then
            local inner = elem:sub(2, -2)
            local kt, after = next_type(inner, 1)
            local vt = inner:sub(after)
            for k, x in pairs(v or {}) do
                lib.sd_bus_message_open_container(m, ("e"):byte(), inner)
                sd.write(lib, m, kt, k)
                sd.write(lib, m, vt, x)
                lib.sd_bus_message_close_container(m)
            end
        else
            for _, x in ipairs(v or {}) do sd.write(lib, m, elem, x) end
        end
        lib.sd_bus_message_close_container(m)
    elseif c == "v" then
        local vt = variant_type(v) or "s"
        lib.sd_bus_message_open_container(m, ("v"):byte(), vt)
        sd.write(lib, m, vt, vt == "s" and tostring(v) or v)
        lib.sd_bus_message_close_container(m)
    elseif c == "(" then
        local inner = t:sub(2, -2)
        lib.sd_bus_message_open_container(m, ("r"):byte(), inner)
        for i, it in ipairs(dbus.split(inner)) do sd.write(lib, m, it, v[i]) end
        lib.sd_bus_message_close_container(m)
    end
end

--------------------------------------------------------------------------------
-- libdbus
--------------------------------------------------------------------------------

local ld = {}

-- Read the value at `iter` and move past it.
function ld.read(lib, iter, t)
    local c = t:sub(1, 1)
    local v = nil
    if BASIC[t] or t == "b" then
        local box = ffi.new(t == "b" and "uint32_t[1]" or BASIC[t])
        lib.dbus_message_iter_get_basic(iter, box)
        v = from_box(t, box)
    elseif c == "a" then
        local elem = t:sub(2)
        local sub = ffi.new("DBusMessageIter")
        lib.dbus_message_iter_recurse(iter, sub)
        v = {}
        if elem:sub(1, 1) == "{" then
            local inner = elem:sub(2, -2)
            local kt, after = next_type(inner, 1)
            local vt = inner:sub(after)
            while lib.dbus_message_iter_get_arg_type(sub) == ("e"):byte() do
                local entry = ffi.new("DBusMessageIter")
                lib.dbus_message_iter_recurse(sub, entry)
                local k = ld.read(lib, entry, kt)
                local x = ld.read(lib, entry, vt)
                if k ~= nil then v[k] = x end
                lib.dbus_message_iter_next(sub)
            end
        else
            while lib.dbus_message_iter_get_arg_type(sub) ~= 0 do v[#v + 1] = ld.read(lib, sub, elem) end
        end
    elseif c == "v" then
        local sub = ffi.new("DBusMessageIter")
        lib.dbus_message_iter_recurse(iter, sub)
        local sig = lib.dbus_message_iter_get_signature(sub)
        local inner = ffi.string(sig)
        lib.dbus_free(sig)
        if readable(inner) then v = ld.read(lib, sub, inner) end
    elseif c == "(" then
        local sub = ffi.new("DBusMessageIter")
        lib.dbus_message_iter_recurse(iter, sub)
        v = {}
        for _, it in ipairs(dbus.split(t:sub(2, -2))) do v[#v + 1] = ld.read(lib, sub, it) end
    end
    lib.dbus_message_iter_next(iter)
    return v
end

function ld.write(lib, iter, t, v)
    local c = t:sub(1, 1)
    if STRING[t] then
        -- `str` keeps the Lua string alive while libdbus copies it.
        local str = tostring(v or "")
        local box = ffi.new("const char *[1]")
        box[0] = str
        lib.dbus_message_iter_append_basic(iter, t:byte(), box)
    elseif BASIC[t] or t == "b" then
        local box = ffi.new(t == "b" and "uint32_t[1]" or BASIC[t])
        box[0] = t == "b" and (v and 1 or 0) or (v or 0)
        lib.dbus_message_iter_append_basic(iter, t:byte(), box)
    elseif c == "a" then
        local elem = t:sub(2)
        local sub = ffi.new("DBusMessageIter")
        lib.dbus_message_iter_open_container(iter, ("a"):byte(), elem, sub)
        if elem:sub(1, 1) == "{" then
            local inner = elem:sub(2, -2)
            local kt, after = next_type(inner, 1)
            local vt = inner:sub(after)
            for k, x in pairs(v or {}) do
                local entry = ffi.new("DBusMessageIter")
                lib.dbus_message_iter_open_container(sub, ("e"):byte(), nil, entry)
                ld.write(lib, entry, kt, k)
                ld.write(lib, entry, vt, x)
                lib.dbus_message_iter_close_container(sub, entry)
            end
        else
            for _, x in ipairs(v or {}) do ld.write(lib, sub, elem, x) end
        end
        lib.dbus_message_iter_close_container(iter, sub)
    elseif c == "v" then
        local vt = variant_type(v) or "s"
        local sub = ffi.new("DBusMessageIter")
        lib.dbus_message_iter_open_container(iter, ("v"):byte(), vt, sub)
        ld.write(lib, sub, vt, vt == "s" and tostring(v) or v)
        lib.dbus_message_iter_close_container(iter, sub)
    elseif c == "(" then
        local sub = ffi.new("DBusMessageIter")
        lib.dbus_message_iter_open_container(iter, ("r"):byte(), nil, sub)
        for i, it in ipairs(dbus.split(t:sub(2, -2))) do ld.write(lib, sub, it, v[i]) end
        lib.dbus_message_iter_close_container(iter, sub)
    end
end

--------------------------------------------------------------------------------
-- Connections
--------------------------------------------------------------------------------

local FAILED = "org.freedesktop.DBus.Error.Failed"
local UNKNOWN = "org.freedesktop.DBus.Error.UnknownMethod"
local INTROSPECTABLE = "org.freedesktop.DBus.Introspectable"

-- Introspection XML for an object's interfaces.
local function introspect(interfaces)
    local out = { '<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"',
        ' "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">', "<node>",
        '  <interface name="' .. INTROSPECTABLE .. '"><method name="Introspect">'
        .. '<arg name="xml" type="s" direction="out"/></method></interface>' }
    for name, methods in pairs(interfaces) do
        out[#out + 1] = '  <interface name="' .. name .. '">'
        for method, spec in pairs(methods) do
            if type(spec) == "table" then
                out[#out + 1] = '    <method name="' .. method .. '">'
                for _, t in ipairs(dbus.split(spec[1])) do out[#out + 1] = '      <arg type="' .. t .. '" direction="in"/>' end
                for _, t in ipairs(dbus.split(spec[2])) do out[#out + 1] = '      <arg type="' .. t .. '" direction="out"/>' end
                out[#out + 1] = "    </method>"
            end
        end
        out[#out + 1] = "  </interface>"
    end
    out[#out + 1] = "</node>"
    return table.concat(out, "\n")
end

-- What a method call should get back: ok, out signature, values (or an
-- error name and message).
local function call_method(objects, path, iface, member, read_args)
    local interfaces = objects[path]
    if not interfaces then return false, UNKNOWN, "no object at " .. tostring(path) end
    if iface == INTROSPECTABLE and member == "Introspect" then
        return true, "s", { introspect(interfaces) }
    end
    local spec = nil
    if iface then
        spec = interfaces[iface] and interfaces[iface][member]
    else
        for _, methods in pairs(interfaces) do spec = spec or methods[member] end
    end
    if type(spec) ~= "table" then return false, UNKNOWN, "no method " .. tostring(member) end
    local args = read_args(dbus.split(spec[1]))
    local results = { xpcall(spec[3], debug.traceback, unpack(args, 1, #dbus.split(spec[1]))) }
    if not results[1] then return false, FAILED, tostring(results[2]) end
    table.remove(results, 1)
    return true, spec[2], results
end

-- sd-bus connection -------------------------------------------------------------

local sd_handler = nil
local sd_buses = {} -- address of the sd_bus -> connection

local function sd_open(opts)
    local lib, name = load_any(SD_BUS_LIBS)
    if not lib then return nil end
    local out = ffi.new("sd_bus *[1]")
    local r = lib.sd_bus_open_user(out)
    if r < 0 then return nil, string.format("sd-bus (%s): no session bus (error %d)", name, -r) end
    local bus = out[0]
    local conn = { backend = "sd-bus (" .. name .. ")", objects = {}, slots = {} }

    local function pump()
        while lib.sd_bus_process(bus, nil) > 0 do end
        lib.sd_bus_flush(bus)
    end

    if not sd_handler then
        sd_handler = ffi.cast("sd_bus_message_handler_t", function(m)
            local c = sd_buses[tostring(ffi.cast("uintptr_t", lib.sd_bus_message_get_bus(m)))]
            if not c then return 0 end
            local function str(p) return p ~= nil and ffi.string(p) or nil end
            local ok, out_sig, results = call_method(c.objects, str(lib.sd_bus_message_get_path(m)),
                str(lib.sd_bus_message_get_interface(m)), str(lib.sd_bus_message_get_member(m)),
                function(types)
                    local args = {}
                    for i, t in ipairs(types) do args[i] = sd.read(lib, m, t) end
                    return args
                end)
            if not ok then
                lib.sd_bus_reply_method_errorf(m, out_sig, "%s", results)
                return 1
            end
            local reply = ffi.new("sd_bus_message *[1]")
            if lib.sd_bus_message_new_method_return(m, reply) >= 0 then
                for i, t in ipairs(dbus.split(out_sig)) do sd.write(lib, reply[0], t, results[i]) end
                lib.sd_bus_send(nil, reply[0], nil)
                lib.sd_bus_message_unref(reply[0])
            end
            return 1
        end)
    end
    sd_buses[tostring(ffi.cast("uintptr_t", bus))] = conn

    function conn.own(_, bus_name)
        local result = lib.sd_bus_request_name(bus, bus_name, 0)
        pump()
        if result < 0 then return false, "error " .. -result end
        return true
    end

    function conn.export(_, path, iface, methods)
        if not conn.objects[path] then
            conn.objects[path] = {}
            local slot = ffi.new("sd_bus_slot *[1]")
            lib.sd_bus_add_object(bus, slot, path, sd_handler, nil)
            conn.slots[#conn.slots + 1] = slot[0]
        end
        conn.objects[path][iface] = methods
    end

    function conn.emit(_, path, iface, member, sig, ...)
        local m = ffi.new("sd_bus_message *[1]")
        if lib.sd_bus_message_new_signal(bus, m, path, iface, member) < 0 then return false end
        local values = { ... }
        for i, t in ipairs(dbus.split(sig or "")) do sd.write(lib, m[0], t, values[i]) end
        lib.sd_bus_send(bus, m[0], nil)
        lib.sd_bus_message_unref(m[0])
        lib.sd_bus_flush(bus)
        return true
    end

    local stop = opts.watch(lib.sd_bus_get_fd(bus), pump)
    pump()

    function conn.close()
        if conn.closed then return end
        conn.closed = true
        stop()
        for _, slot in ipairs(conn.slots) do lib.sd_bus_slot_unref(slot) end
        sd_buses[tostring(ffi.cast("uintptr_t", bus))] = nil
        lib.sd_bus_flush_close_unref(bus)
    end
    return conn
end

-- libdbus connection -------------------------------------------------------------

local ld_callbacks = nil
local ld_conns = {} -- address of the DBusConnection -> connection

local function ld_open(opts)
    local lib, name = load_any(LIBDBUS_LIBS)
    if not lib then return nil end
    local err = ffi.new("DBusError")
    lib.dbus_error_init(err)
    local c_conn = lib.dbus_bus_get_private(ffi.C.DBUS_BUS_SESSION, err)
    if c_conn == nil then
        local msg = err.message ~= nil and ffi.string(err.message) or "unknown error"
        lib.dbus_error_free(err)
        return nil, string.format("libdbus (%s): no session bus (%s)", name, msg)
    end
    -- libdbus would exit() the process when the bus goes away.
    lib.dbus_connection_set_exit_on_disconnect(c_conn, 0)
    local conn = { backend = "libdbus (" .. name .. ")", objects = {}, watches = {} }
    local key = tostring(ffi.cast("uintptr_t", c_conn))
    ld_conns[key] = conn

    local function dispatch()
        while lib.dbus_connection_dispatch(c_conn) == ffi.C.DBUS_DISPATCH_DATA_REMAINS do end
        lib.dbus_connection_flush(c_conn)
    end

    if not ld_callbacks then
        ld_callbacks = {}
        ld_callbacks.add = ffi.cast("DBusAddWatchFunction", function(watch, data)
            local c = ld_conns[tostring(ffi.cast("uintptr_t", data))]
            if not c then return 1 end
            local wkey = tostring(ffi.cast("uintptr_t", watch))
            if lib.dbus_watch_get_enabled(watch) ~= 0
                and bit.band(lib.dbus_watch_get_flags(watch), ffi.C.DBUS_WATCH_READABLE) ~= 0 then
                c.watches[wkey] = c.watch(lib.dbus_watch_get_unix_fd(watch), function()
                    lib.dbus_watch_handle(watch, ffi.C.DBUS_WATCH_READABLE)
                    c.dispatch()
                end)
            end
            return 1
        end)
        ld_callbacks.remove = ffi.cast("DBusRemoveWatchFunction", function(watch, data)
            local c = ld_conns[tostring(ffi.cast("uintptr_t", data))]
            local wkey = tostring(ffi.cast("uintptr_t", watch))
            if c and c.watches[wkey] then
                c.watches[wkey]()
                c.watches[wkey] = nil
            end
        end)
        ld_callbacks.toggled = ffi.cast("DBusWatchToggledFunction", function(watch, data)
            ld_callbacks.remove(watch, data)
            ld_callbacks.add(watch, data)
        end)
        ld_callbacks.message = ffi.cast("DBusObjectPathMessageFunction", function(cc, msg)
            local c = ld_conns[tostring(ffi.cast("uintptr_t", cc))]
            if not c or lib.dbus_message_get_type(msg) ~= 1 --[[ METHOD_CALL ]] then
                return ffi.C.DBUS_HANDLER_RESULT_NOT_YET_HANDLED
            end
            local function str(p) return p ~= nil and ffi.string(p) or nil end
            local ok, out_sig, results = call_method(c.objects, str(lib.dbus_message_get_path(msg)),
                str(lib.dbus_message_get_interface(msg)), str(lib.dbus_message_get_member(msg)),
                function(types)
                    local iter, args = ffi.new("DBusMessageIter"), {}
                    if lib.dbus_message_iter_init(msg, iter) ~= 0 then
                        for i, t in ipairs(types) do args[i] = ld.read(lib, iter, t) end
                    end
                    return args
                end)
            local reply
            if ok then
                reply = lib.dbus_message_new_method_return(msg)
                local iter = ffi.new("DBusMessageIter")
                lib.dbus_message_iter_init_append(reply, iter)
                for i, t in ipairs(dbus.split(out_sig)) do ld.write(lib, iter, t, results[i]) end
            else
                reply = lib.dbus_message_new_error(msg, out_sig, results)
            end
            lib.dbus_connection_send(cc, reply, nil)
            lib.dbus_message_unref(reply)
            return ffi.C.DBUS_HANDLER_RESULT_HANDLED
        end)
        ld_callbacks.vtable = ffi.new("DBusObjectPathVTable")
        ld_callbacks.vtable.message_function = ld_callbacks.message
    end
    conn.watch = opts.watch
    conn.dispatch = dispatch
    lib.dbus_connection_set_watch_functions(c_conn, ld_callbacks.add, ld_callbacks.remove, ld_callbacks.toggled,
        ffi.cast("void *", c_conn), nil)

    function conn.own(_, bus_name)
        local e = ffi.new("DBusError")
        lib.dbus_error_init(e)
        local result = lib.dbus_bus_request_name(c_conn, bus_name, 4 --[[ DO_NOT_QUEUE ]], e)
        if lib.dbus_error_is_set(e) ~= 0 then
            local msg = ffi.string(e.message)
            lib.dbus_error_free(e)
            return false, msg
        end
        if result ~= 1 and result ~= 4 then return false, "the name is taken" end
        return true
    end

    function conn.export(_, path, iface, methods)
        if not conn.objects[path] then
            conn.objects[path] = {}
            lib.dbus_connection_register_object_path(c_conn, path, ld_callbacks.vtable, nil)
        end
        conn.objects[path][iface] = methods
    end

    function conn.emit(_, path, iface, member, sig, ...)
        local msg = lib.dbus_message_new_signal(path, iface, member)
        if msg == nil then return false end
        local iter = ffi.new("DBusMessageIter")
        lib.dbus_message_iter_init_append(msg, iter)
        local values = { ... }
        for i, t in ipairs(dbus.split(sig or "")) do ld.write(lib, iter, t, values[i]) end
        lib.dbus_connection_send(c_conn, msg, nil)
        lib.dbus_message_unref(msg)
        lib.dbus_connection_flush(c_conn)
        return true
    end

    function conn.close()
        if conn.closed then return end
        conn.closed = true
        for _, stop in pairs(conn.watches) do stop() end
        conn.watches = {}
        ld_conns[key] = nil
        lib.dbus_connection_close(c_conn)
        lib.dbus_connection_unref(c_conn)
    end

    dispatch()
    return conn
end

--------------------------------------------------------------------------------

--- Connect to the session bus with the first library that works. Returns a
--- connection, or nil and why not. opts.backend = "sd-bus" | "libdbus"
--- forces one.
function dbus.session(opts)
    if not os.getenv("DBUS_SESSION_BUS_ADDRESS") and not os.getenv("XDG_RUNTIME_DIR") then
        return nil, "no session bus (neither DBUS_SESSION_BUS_ADDRESS nor XDG_RUNTIME_DIR is set)"
    end
    local reasons = {}
    for _, backend in ipairs({ { "sd-bus", sd_open }, { "libdbus", ld_open } }) do
        if not opts.backend or opts.backend == backend[1] then
            local conn, err = backend[2](opts)
            if conn then return conn end
            reasons[#reasons + 1] = err or (backend[1] .. ": library not installed")
        end
    end
    return nil, table.concat(reasons, "; ")
end

return dbus
