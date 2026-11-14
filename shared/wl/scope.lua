-- Lifetimes: everything registered through a scope is undone when it closes.
--
-- A scope is a plain table; its functions are shared, not per-scope closures,
-- and there is no metatable. Use it with method syntax:
--
--   local s = scope.new("toplevel")
--   s:listen(xdg_toplevel.events.destroy, function() s:close() end)
--   s:subscribe(emitter, "focus", on_focus)
--   s:defer(function() ... end)
--   s:close()  -- runs deferred work in reverse order, once

local listener = require("shared.wl.listener")
local log = require("shared.log")

local scope = {}

local function defer(s, fn)
    if s.closed then
        fn()
        return
    end
    local d = s._deferred
    d[#d + 1] = fn
end

local function listen(s, signal, fn, ctype)
    local id = listener.connect(signal, fn, ctype)
    defer(s, function() listener.disconnect(id) end)
    return id
end

local function subscribe(s, emitter, event, fn)
    local handle = emitter:on(event, fn)
    defer(s, function() handle:off() end)
    return handle
end

local function close(s)
    if s.closed then
        return
    end
    s.closed = true
    local d = s._deferred
    for i = #d, 1, -1 do
        local ok, err = xpcall(d[i], debug.traceback)
        if not ok then
            log.error("scope '%s' cleanup error: %s", s.name, tostring(err))
        end
        d[i] = nil
    end
end

local new

local function child(s, name)
    local c = new(name or s.name)
    defer(s, function() close(c) end)
    return c
end

--- Create a scope.
---@param name string|nil used in error messages
function new(name)
    return {
        name = name or "scope",
        closed = false,
        _deferred = {},
        defer = defer,
        listen = listen,
        subscribe = subscribe,
        child = child,
        close = close,
    }
end
scope.new = new

return scope
