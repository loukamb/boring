local event_emitter = {}

local EventEmitter = {}
EventEmitter.__index = EventEmitter

local ListenerHandle = {}
ListenerHandle.__index = ListenerHandle

function ListenerHandle:off()
    if self._closed then
        return
    end
    self._closed = true
    self.emitter:off(self.event, self)
end

function event_emitter.new()
    return setmetatable({ _listeners = {} }, EventEmitter)
end

function EventEmitter:on(event, callback)
    assert(type(event) == "string", "event name must be a string")
    assert(type(callback) == "function", "event callback must be a function")

    local listeners = self._listeners[event]
    if not listeners then
        listeners = {}
        self._listeners[event] = listeners
    end

    local listener = setmetatable({
        event = event,
        callback = callback,
        emitter = self,
        _closed = false,
    }, ListenerHandle)

    table.insert(listeners, listener)
    return listener
end

function EventEmitter:off(event, callback)
    local listeners = self._listeners[event]
    if not listeners then
        return
    end

    for i, listener in ipairs(listeners) do
        if listener == callback or listener.callback == callback then
            listener._closed = true
            table.remove(listeners, i)
            if #listeners == 0 then
                self._listeners[event] = nil
            end
            return
        end
    end
end

function EventEmitter:emit(event, ...)
    local listeners = self._listeners[event]
    if not listeners then
        return
    end

    local snapshot = {}
    for i, listener in ipairs(listeners) do
        snapshot[i] = listener
    end

    for _, listener in ipairs(snapshot) do
        if not listener._closed then
            local ok, err = xpcall(listener.callback, debug.traceback, ...)
            if not ok then
                local log = require("shared.log")
                log.error("Event '%s' listener error: %s", event, err)
            end
        end
    end
end

function EventEmitter:clear(event)
    if event then
        local listeners = self._listeners[event]
        if listeners then
            for _, listener in ipairs(listeners) do
                listener._closed = true
            end
        end
        self._listeners[event] = nil
        return
    end

    for _, listeners in pairs(self._listeners) do
        for _, listener in ipairs(listeners) do
            listener._closed = true
        end
    end
    self._listeners = {}
end

event_emitter.EventEmitter = EventEmitter

return event_emitter
