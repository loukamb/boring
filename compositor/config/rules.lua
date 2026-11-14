-- Configuration rules: `monitor.new{...}`, `input.keyboard.new{...}`,
-- `input.mouse.new{...}`.
--
-- A rule is a plain table of settings with a `name` ("*" matches every
-- device). Resolving a device merges all matching rules: wildcard rules
-- first, then exact ones, so exact names win regardless of order.

local rules = {}

--- Deep copy of base with override merged in (tables merge, values replace).
function rules.deep_merge(base, override)
    local result = {}
    for k, v in pairs(base) do
        result[k] = type(v) == "table" and rules.deep_merge(v, {}) or v
    end
    for k, v in pairs(override) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = rules.deep_merge(result[k], v)
        else
            result[k] = v
        end
    end
    return result
end

-- Rule functions (shared; rules carry references to them, no metatable).
local function get_name(r) return r._name end
local function is_enabled(r) return r._enabled end
local function enable(r) r._enabled = true end
local function disable(r) r._enabled = false end
local function matches(r, name) return r._name == "*" or r._name == name end

--- Create a rule from user options.
function rules.new(kind, opts)
    local r = {
        _kind = kind,
        _name = opts.name or "*",
        _enabled = true,
        name = opts.name or "*",
        get_name = get_name,
        is_enabled = is_enabled,
        enable = enable,
        disable = disable,
        matches = matches,
    }
    for k, v in pairs(opts) do
        if k ~= "name" then r[k] = v end
    end
    return r
end

--- Merge every enabled rule matching `name` into one settings table.
function rules.resolve(list, name)
    local result = {}
    local function apply(r)
        if not (r._enabled and matches(r, name)) then return end
        for k, v in pairs(r) do
            if type(k) == "string" and k:sub(1, 1) ~= "_" and k ~= "name" and type(v) ~= "function" then
                if type(v) == "table" and type(result[k]) == "table" then
                    result[k] = rules.deep_merge(result[k], v)
                else
                    result[k] = v
                end
            end
        end
    end
    for _, r in ipairs(list) do
        if r._name == "*" then apply(r) end
    end
    for _, r in ipairs(list) do
        if r._name ~= "*" then apply(r) end
    end
    return result
end

--- Set a default, or check the type of a value the user gave.
function rules.default(tbl, key, expected_type, default)
    if tbl[key] == nil then
        tbl[key] = default
    elseif type(tbl[key]) ~= expected_type then
        error(string.format("%s must be a %s", key, expected_type), 3)
    end
end

--- A configuration namespace: { new, get, all, resolve } over one rule list.
---@param kind string "monitor", "keyboard", "mouse"
---@param key string registry key: "monitors", "keyboards", "mice"
---@param validate function|nil normalises options in place
---@param list_of function returns the current rule list for `key`
function rules.namespace(kind, key, validate, list_of)
    return {
        new = function(opts)
            assert(type(opts) == "table" and opts.name, kind .. ".new needs a name")
            if validate then validate(opts) end
            local r = rules.new(kind, opts)
            table.insert(list_of(key), r)
            return r
        end,
        get = function(name)
            for _, r in ipairs(list_of(key)) do
                if r._name == name then return r end
            end
        end,
        all = function()
            local copy = {}
            for i, r in ipairs(list_of(key)) do copy[i] = r end
            return copy
        end,
        resolve = function(name)
            return rules.resolve(list_of(key), name)
        end,
    }
end

-- Validation per kind -------------------------------------------------------

function rules.validate_monitor(o)
    if o.mode == "preferred" then
        o.width, o.height, o.refresh_rate = nil, nil, nil
    elseif o.mode then
        local w, h, r = o.mode:match("^(%d+)x(%d+)@(%d+)$")
        if w then
            o.width, o.height, o.refresh_rate = tonumber(w), tonumber(h), tonumber(r)
        end
    end
    rules.default(o, "x", "number", nil)
    rules.default(o, "y", "number", nil)
    rules.default(o, "scale", "number", 1)
    if o.rotate == nil then
        o.rotate = 0
    elseif type(o.rotate) == "table" then
        rules.default(o.rotate, "degrees", "number", 0)
        rules.default(o.rotate, "flip", "boolean", false)
    end
end

function rules.validate_keyboard(o)
    if o["repeat"] then
        rules.default(o["repeat"], "delay", "number", 300)
        rules.default(o["repeat"], "rate", "number", 30)
    else
        o["repeat"] = { delay = 300, rate = 30 }
    end
    o.shortcuts = o.shortcuts or {}
end

function rules.validate_mouse(o)
    rules.default(o, "handedness", "string", "right")
    if o.scroll then
        rules.default(o.scroll, "speed", "number", 25)
        rules.default(o.scroll, "natural", "boolean", false)
    else
        o.scroll = { speed = 25, natural = false }
    end
end

return rules
