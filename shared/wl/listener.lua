-- wl_listener without one C callback per listener.
--
-- Every listener is a `struct boring_listener { struct wl_listener base;
-- uint32_t id; }` whose notify points at one shared trampoline. The trampoline
-- reads the id and calls the Lua function registered for it. LuaJIT has a
-- fixed number of callback slots and each ffi.cast callback costs a slot, so
-- this keeps the number of listeners unbounded and connect/disconnect O(1).

local ffi = require("ffi")
local log = require("shared.log")
require("shared.ffi.server")

ffi.cdef [[
struct boring_listener {
    struct wl_listener base;
    uint32_t id;
};
]]

local listener = {}

local listener_ptr = ffi.typeof("struct boring_listener *")
local handlers = {} -- id -> function(data)
local casts = {}    -- id -> ctype for data, or nil for raw void*
local objects = {}  -- id -> boring_listener cdata (keeps it alive)
local free_ids = {}
local next_id = 1
local active = 0

local traceback = debug.traceback

local function dispatch(l, data)
    local id = ffi.cast(listener_ptr, l).id
    local fn = handlers[id]
    if fn == nil then
        return
    end
    local ct = casts[id]
    if ct then
        data = ffi.cast(ct, data)
    end
    -- An error must never unwind through libwayland.
    local ok, err = xpcall(fn, traceback, data)
    if not ok then
        log.error("listener error: %s", tostring(err))
    end
end

local trampoline = ffi.cast("wl_notify_func_t", dispatch)

local ctype_cache = {}
local function pointer_ctype(ctype)
    if ctype == nil then
        return nil
    end
    local ct = ctype_cache[ctype]
    if not ct then
        local name = ctype:find("%*%s*$") and ctype or (ctype .. " *")
        ct = ffi.typeof(name)
        ctype_cache[ctype] = ct
    end
    return ct
end

--- Connect `fn` to a wl_signal. `fn` receives the signal's data pointer, cast
--- to `ctype` (e.g. "struct wlr_output") when given.
---@param signal ffi.cdata* struct wl_signal (or a reference to one)
---@param fn fun(data: any)
---@param ctype string|nil
---@return integer id  pass to listener.disconnect
function listener.connect(signal, fn, ctype)
    assert(signal ~= nil, "listener.connect: signal is NULL")
    assert(type(fn) == "function", "listener.connect: expected a function")

    local id = table.remove(free_ids)
    if not id then
        id = next_id
        next_id = next_id + 1
    end

    local obj = ffi.new("struct boring_listener")
    obj.base.notify = trampoline
    obj.id = id
    handlers[id] = fn
    casts[id] = pointer_ctype(ctype)
    objects[id] = obj
    active = active + 1

    -- wl_signal_add: append to the signal's listener list.
    local link = obj.base.link
    local head = signal.listener_list
    link.prev = head.prev
    link.next = head
    head.prev.next = link
    head.prev = link

    return id
end

--- Disconnect a listener. Safe to call from inside its own callback and more
--- than once.
---@param id integer
function listener.disconnect(id)
    local obj = objects[id]
    if obj == nil then
        return
    end
    local link = obj.base.link
    if link.prev ~= nil then
        link.prev.next = link.next
        link.next.prev = link.prev
        link.prev = nil
        link.next = nil
    end
    handlers[id] = nil
    casts[id] = nil
    objects[id] = nil
    free_ids[#free_ids + 1] = id
    active = active - 1
end

--- Number of connected listeners (for tests and leak checks).
function listener.count()
    return active
end

--- Emit a wl_signal from Lua (wl_signal_emit is static inline in C). Iterates
--- safely: listeners may disconnect themselves while being notified.
function listener.emit(signal, data)
    local head = signal.listener_list
    local head_addr = ffi.cast("void *", head)
    local pos = head.next
    while ffi.cast("void *", pos) ~= head_addr do
        local next_pos = pos.next
        local l = ffi.cast("struct wl_listener *", pos)
        l.notify(l, data)
        pos = next_pos
    end
end

--- Initialise a struct wl_signal created from Lua (wl_signal_init is inline).
function listener.signal_init(signal)
    local head = signal.listener_list
    head.prev = head
    head.next = head
end

return listener
