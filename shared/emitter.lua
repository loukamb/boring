-- Named events for Lua code (plugins, services). Not for wl_signals; those
-- go through shared.wl.listener.
--
--   local e = emitter.new()
--   local handle = e:on("focus", function(surface) ... end)
--   e:emit("focus", surface)
--   handle:off()
--
-- An emitter is a plain table with shared functions; no metatable.

local log = require("shared.log")

local emitter = {}

local function off(e, event, fn)
    local list = e._listeners[event]
    if not list then
        return
    end
    for i = 1, #list do
        local entry = list[i]
        if entry == fn or entry.fn == fn then
            entry.removed = true
            table.remove(list, i)
            if #list == 0 then
                e._listeners[event] = nil
            end
            return
        end
    end
end

local function on(e, event, fn)
    assert(type(event) == "string", "event name must be a string")
    assert(type(fn) == "function", "event callback must be a function")
    local list = e._listeners[event]
    if not list then
        list = {}
        e._listeners[event] = list
    end
    local entry = { fn = fn, removed = false }
    entry.off = function() off(e, event, entry) end
    list[#list + 1] = entry
    return entry
end

local function emit(e, event, ...)
    local list = e._listeners[event]
    if not list then
        return
    end
    -- Snapshot: callbacks may add or remove listeners.
    local n = #list
    local snapshot = { unpack(list, 1, n) }
    for i = 1, n do
        local entry = snapshot[i]
        if not entry.removed then
            local ok, err = xpcall(entry.fn, debug.traceback, ...)
            if not ok then
                log.error("event '%s' listener error: %s", event, tostring(err))
            end
        end
    end
end

local function clear(e, event)
    local function mark(list)
        for _, entry in ipairs(list) do entry.removed = true end
    end
    if event then
        if e._listeners[event] then mark(e._listeners[event]) end
        e._listeners[event] = nil
        return
    end
    for _, list in pairs(e._listeners) do mark(list) end
    e._listeners = {}
end

function emitter.new()
    return {
        _listeners = {},
        on = on,
        off = off,
        emit = emit,
        clear = clear,
    }
end

return emitter
