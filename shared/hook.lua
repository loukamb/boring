-- shared/hook.lua
-- Priority-based hook system for plugin behavior overrides
-- Unlike events (notifications), hooks can CANCEL default behavior

local hook_module = {}

---@class Hook
---@field _handlers table<string, table[]>
local Hook = {}
Hook.__index = Hook

---Create a new hook registry
---@return Hook
function hook_module.new()
    local self = setmetatable({
        _handlers = {},
    }, Hook)
    return self
end

---Register a hook handler
---@param name string Hook name
---@param callback function Handler function, return true to cancel default
---@param priority number|nil Priority (higher runs first, default 0)
---@return table Handle with :off() method
function Hook:on(name, callback, priority)
    priority = priority or 0
    
    if not self._handlers[name] then
        self._handlers[name] = {}
    end
    
    local handler = {
        name = name,
        callback = callback,
        priority = priority,
        hook = self,
    }
    
    function handler:off()
        local handlers = self.hook._handlers[self.name]
        if handlers then
            for i, h in ipairs(handlers) do
                if h == self then
                    table.remove(handlers, i)
                    break
                end
            end
        end
    end
    
    -- Insert sorted by priority (higher first)
    local handlers = self._handlers[name]
    local inserted = false
    for i, h in ipairs(handlers) do
        if priority > h.priority then
            table.insert(handlers, i, handler)
            inserted = true
            break
        end
    end
    if not inserted then
        table.insert(handlers, handler)
    end
    
    return handler
end

---Run all handlers for a hook
---@param name string Hook name
---@param ... any Arguments to pass to handlers
---@return boolean cancelled True if any handler cancelled default behavior
function Hook:run(name, ...)
    local handlers = self._handlers[name]
    if not handlers then return false end
    
    for _, handler in ipairs(handlers) do
        local ok, result = pcall(handler.callback, ...)
        if not ok then
            local log = require("shared.log")
            log.error("Hook '%s' handler error: %s", name, result)
        elseif result == true then
            return true  -- Cancelled
        end
    end
    
    return false
end

---Check if any handlers are registered for a hook
---@param name string Hook name
---@return boolean
function Hook:has(name)
    local handlers = self._handlers[name]
    return handlers and #handlers > 0
end

---Remove all handlers for a hook (or all hooks)
---@param name string|nil Hook name, or nil to clear all
function Hook:clear(name)
    if name then
        self._handlers[name] = nil
    else
        self._handlers = {}
    end
end

return hook_module
