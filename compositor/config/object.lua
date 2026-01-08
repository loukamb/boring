-- compositor/config/object.lua
-- ConfigObject class for configuration rules

local ConfigObject = {}
ConfigObject.__index = ConfigObject

---@param type_name string
---@param opts table
---@return table
function ConfigObject.new(type_name, opts)
    local obj = setmetatable({
        _type = type_name,
        _enabled = true,
        _name = opts.name or "*",
    }, ConfigObject)

    for k, v in pairs(opts) do
        if k ~= "name" then
            obj[k] = v
        end
    end

    return obj
end

---@param opts table
---@return table changes
function ConfigObject:update(opts)
    local changes = {}
    for k, v in pairs(opts) do
        if self[k] ~= v then
            changes[k] = { old = self[k], new = v }
            if type(v) == "table" and type(self[k]) == "table" then
                for tk, tv in pairs(v) do
                    self[k][tk] = tv
                end
            else
                self[k] = v
            end
        end
    end
    return changes
end

---@return boolean
function ConfigObject:disable()
    if self._enabled then
        self._enabled = false
        return true
    end
    return false
end

---@return boolean
function ConfigObject:enable()
    if not self._enabled then
        self._enabled = true
        return true
    end
    return false
end

---@return boolean
function ConfigObject:is_enabled()
    return self._enabled
end

---@return string
function ConfigObject:get_name()
    return self._name
end

---@return string
function ConfigObject:get_type()
    return self._type
end

---@param name string
---@return boolean
function ConfigObject:matches(name)
    if self._name == "*" then
        return true
    end
    return self._name == name
end

return ConfigObject
