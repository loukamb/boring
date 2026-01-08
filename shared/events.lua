-- shared/events.lua
-- Simple event emitter for plugin hooks

local events_module = {}

---@class EventEmitter
---@field _listeners table<string, table[]>
local EventEmitter = {}
EventEmitter.__index = EventEmitter

---Create a new event emitter
---@return EventEmitter
function events_module.new()
    local self = setmetatable({
        _listeners = {},
    }, EventEmitter)
    return self
end

---Subscribe to an event
---@param event string Event name
---@param callback function Callback function
---@return table Listener handle with :off() method
function EventEmitter:on(event, callback)
    if not self._listeners[event] then
        self._listeners[event] = {}
    end
    
    local listener = {
        event = event,
        callback = callback,
        emitter = self,
    }
    
    function listener:off()
        local listeners = self.emitter._listeners[self.event]
        if listeners then
            for i, l in ipairs(listeners) do
                if l == self then
                    table.remove(listeners, i)
                    break
                end
            end
        end
    end
    
    table.insert(self._listeners[event], listener)
    return listener
end

---Emit an event
---@param event string Event name
---@param ... any Arguments to pass to listeners
function EventEmitter:emit(event, ...)
    local listeners = self._listeners[event]
    if not listeners then return end
    
    for _, listener in ipairs(listeners) do
        local ok, err = pcall(listener.callback, ...)
        if not ok then
            local log = require("shared.log")
            log.error("Event '%s' listener error: %s", event, err)
        end
    end
end

---Remove all listeners for an event (or all events)
---@param event string|nil Event name, or nil to clear all
function EventEmitter:clear(event)
    if event then
        self._listeners[event] = nil
    else
        self._listeners = {}
    end
end

return events_module
