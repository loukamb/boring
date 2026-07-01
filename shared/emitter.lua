--- Simple event emitter for pub/sub patterns
---@class shared.emitter

--- @class EventEmitter
--- @field listeners table<string, function[]> Map of event names to callback arrays

local event_emitter = {}

---Create a new event emitter instance
---@return EventEmitter A new emitter with on/off/emit methods
function event_emitter.new()
    local emitter = { listeners = {} }

    ---Register a callback for an event
    ---@param event string Event name
    ---@param callback function Callback function to invoke
    function emitter:on(event, callback)
        if not self.listeners[event] then
            self.listeners[event] = {}
        end
        local listener = {
            event = event,
            callback = callback,
            emitter = self,
        }
        table.insert(self.listeners[event], listener)

        function listener:off()
            self.emitter:off(self.event, self)
        end

        return listener
    end

    ---Unregister a callback from an event
    ---@param event string Event name
    ---@param callback function|table The exact callback or listener handle to remove
    function emitter:off(event, callback)
        if not self.listeners[event] then
            return
        end
        for i, listener in ipairs(self.listeners[event]) do
            if listener == callback or listener.callback == callback then
                table.remove(self.listeners[event], i)
                break
            end
        end
    end

    ---Emit an event, calling all registered callbacks
    ---@param event string Event name
    ---@param ... any Arguments to pass to callbacks
    function emitter:emit(event, ...)
        if not self.listeners[event] then
            return
        end
        for _, listener in ipairs(self.listeners[event]) do
            local ok, err = pcall(listener.callback, ...)
            if not ok then
                local log = require("shared.log")
                log.error("Event '%s' listener error: %s", event, err)
            end
        end
    end

    return emitter
end

return event_emitter
