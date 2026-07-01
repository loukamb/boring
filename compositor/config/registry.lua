-- compositor/config/registry.lua
-- Dynamic config registry for managing configuration objects

local ConfigObject = require("compositor.config.object")

local Registry = {}
Registry.__index = Registry

---Create a new registry instance
---@param runtime table Reference to runtime instance
---@param key string Registry key (e.g., "monitors", "keyboards", "mice")
---@return table Registry instance
function Registry.new(runtime, key)
    local self = setmetatable({}, Registry)
    self._runtime = runtime
    self._key = key
    return self
end

---Get the data table for this registry
---@return table|nil
function Registry:_data()
    local registry = self._runtime and self._runtime.registry
    return registry and registry[self._key]
end

---Ensure data table exists
---@return table
function Registry:_ensure_data()
    if not self._runtime.registry[self._key] then
        self._runtime.registry[self._key] = { rules = {}, resolved = {} }
    end
    return self._runtime.registry[self._key]
end

---Get all rules (readonly)
---@return table
function Registry:rules()
    local data = self:_data()
    if not data or not data.rules then
        return {}
    end
    -- Return a readonly proxy
    return setmetatable({}, {
        __index = data.rules,
        __newindex = function()
            error("Attempt to modify readonly rules table")
        end,
        __len = function()
            return #data.rules
        end,
        __ipairs = function()
            return ipairs(data.rules)
        end,
        __pairs = function()
            return pairs(data.rules)
        end,
    })
end

---Get all rules (mutable, for internal use)
---@return table
function Registry:mutable_rules()
    local data = self:_data()
    return data and data.rules or {}
end

---Get a specific rule by name
---@param name string
---@return table|nil
function Registry:get(name)
    local data = self:_data()
    if not data or not data.rules then
        return nil
    end
    for _, rule in ipairs(data.rules) do
        if rule:get_name() == name then
            return rule
        end
    end
    return nil
end

---Resolve configuration for a target (merges matching rules)
---@param target_name string
---@return table Merged configuration
function Registry:resolve(target_name)
    local data = self:_data()
    if not data or not data.rules then
        return {}
    end
    return self:_resolve_rules(data.rules, target_name)
end

---Add a new config object
---@param opts table Configuration options
---@param validators function|nil Optional validator function
---@return table ConfigObject
function Registry:add(opts, validators)
    assert(opts.name, "Config object name is required")
    
    if validators then
        validators(opts)
    end
    
    local obj = ConfigObject.new(self._key:gsub("s$", ""), opts)  -- "monitors" -> "monitor"
    local data = self:_ensure_data()
    table.insert(data.rules, obj)
    return obj
end

---Remove a rule by name
---@param name string
---@return boolean True if removed
function Registry:remove(name)
    local data = self:_data()
    if not data or not data.rules then
        return false
    end
    for i, rule in ipairs(data.rules) do
        if rule:get_name() == name then
            table.remove(data.rules, i)
            return true
        end
    end
    return false
end

---Clear all rules
function Registry:clear()
    local data = self:_data()
    if data then
        data.rules = {}
        data.resolved = {}
    end
end

---Get count of rules
---@return number
function Registry:count()
    local data = self:_data()
    return data and data.rules and #data.rules or 0
end

---Iterate over rules
---@return function Iterator
function Registry:iter()
    local data = self:_data()
    local rules = data and data.rules or {}
    return ipairs(rules)
end

---Deep merge two tables
---@param base table
---@param override table
---@return table
function Registry:_deep_merge(base, override)
    local result = {}
    for k, v in pairs(base) do
        if type(v) == "table" then
            result[k] = self:_deep_merge(v, {})
        else
            result[k] = v
        end
    end
    for k, v in pairs(override) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = self:_deep_merge(result[k], v)
        else
            result[k] = v
        end
    end
    return result
end

---Resolve rules for a target name
---@param rules table
---@param target_name string
---@return table
function Registry:_resolve_rules(rules, target_name)
    local result = {}
    local function apply_rule(rule)
        if rule:is_enabled() and rule:matches(target_name) then
            for k, v in pairs(rule) do
                if k:sub(1, 1) ~= "_" then
                    if type(v) == "table" and type(result[k]) == "table" then
                        result[k] = self:_deep_merge(result[k], v)
                    else
                        result[k] = v
                    end
                end
            end
        end
    end

    for _, rule in ipairs(rules) do
        if rule:get_name() == "*" then
            apply_rule(rule)
        end
    end
    for _, rule in ipairs(rules) do
        if rule:get_name() ~= "*" then
            apply_rule(rule)
        end
    end
    return result
end

return Registry
