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
        table.insert(self.listeners[event], callback)
    end

    ---Unregister a callback from an event
    ---@param event string Event name
    ---@param callback function The exact callback function to remove
    function emitter:off(event, callback)
        if not self.listeners[event] then
            return
        end
        for i, cb in ipairs(self.listeners[event]) do
            if cb == callback then
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
        for _, callback in ipairs(self.listeners[event]) do
            callback(...)
        end
    end

    return emitter
end

return event_emitter
