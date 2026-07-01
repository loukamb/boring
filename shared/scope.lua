local wl = require("shared.wayland.server")
local log = require("shared.log")

local Scope = {}
Scope.__index = Scope

function Scope.new(name)
    return setmetatable({
        name = name or "scope",
        _closed = false,
        _deferred = {},
    }, Scope)
end

function Scope:defer(fn)
    assert(type(fn) == "function", "defer expects a function")
    if self._closed then
        fn()
        return nil
    end
    table.insert(self._deferred, fn)
    return fn
end

function Scope:listen(signal, callback, data)
    assert(signal ~= nil, "listen expects a signal")
    assert(type(callback) == "function", "listen expects a callback")

    local listener = wl.Listener.new(callback, data)
    listener:connect(signal)
    self:defer(function()
        listener:destroy()
    end)
    return listener
end

function Scope:subscribe(emitter, event, callback)
    assert(emitter and emitter.on, "subscribe expects an emitter")
    local handle = emitter:on(event, callback)
    self:defer(function()
        handle:off()
    end)
    return handle
end

function Scope:close()
    if self._closed then
        return
    end
    self._closed = true

    local first_error = nil
    for i = #self._deferred, 1, -1 do
        local ok, err = xpcall(self._deferred[i], debug.traceback)
        if not ok then
            first_error = first_error or err
            log.error("scope '%s' cleanup error: %s", self.name, tostring(err))
        end
        self._deferred[i] = nil
    end

    if first_error then
        error(first_error, 2)
    end
end

function Scope:closed()
    return self._closed
end

return Scope
