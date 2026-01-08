-- compositor/config/init.lua
-- Main runtime module for compositor configuration
-- This is the refactored version of shared/runtime.lua

local ConfigObject = require("compositor.config.object")
local Registry = require("compositor.config.registry")
local monitor_config = require("compositor.config.monitor")
local input_config = require("compositor.config.input")
local action_config = require("compositor.config.action")
local plugin_module = require("compositor.plugin")
local color = require("shared.color")

local runtime = {}

-- Current runtime instance (set during config loading)
runtime._current = nil

--------------------------------------------------------------------------------
-- Runtime helpers (passed to configurators)
--------------------------------------------------------------------------------

local function readonly(table)
    return setmetatable({}, {
        __index = table,
        __newindex = function(_, key, value)
            error("Attempt to modify a readonly table")
        end,
    })
end

local function assert_if_type(tbl, key, expected_type, default)
    if tbl[key] ~= nil then
        assert(type(tbl[key]) == expected_type, string.format("%s must be a %s", key, expected_type))
    else
        tbl[key] = default
    end
end

local function create_config_object(type_name, registry_key, opts, validators)
    assert(opts.name, type_name .. " name is required")

    if validators then
        validators(opts)
    end

    local obj = ConfigObject.new(type_name, opts)
    local rules = _runtime.registry[registry_key]
    if not rules then
        rules = { rules = {}, resolved = {} }
        _runtime.registry[registry_key] = rules
    end
    table.insert(rules.rules, obj)
    return obj
end

local function resolve_config(registry_key, target_name)
    local data = _runtime.registry[registry_key]
    if not data or not data.rules then
        return {}
    end
    return runtime.resolve_rules(data.rules, target_name)
end

-- Helpers table passed to configurators
local helpers = {
    readonly = readonly,
    assert_if_type = assert_if_type,
    create_config_object = create_config_object,
    resolve_config = resolve_config,
}

--------------------------------------------------------------------------------
-- Rule resolution utilities
--------------------------------------------------------------------------------

function runtime.deep_merge(base, override)
    local result = {}
    for k, v in pairs(base) do
        if type(v) == "table" then
            result[k] = runtime.deep_merge(v, {})
        else
            result[k] = v
        end
    end
    for k, v in pairs(override) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = runtime.deep_merge(result[k], v)
        else
            result[k] = v
        end
    end
    return result
end

function runtime.resolve_rules(rules, target_name)
    local result = {}
    for _, rule in ipairs(rules) do
        if rule:is_enabled() and rule:matches(target_name) then
            for k, v in pairs(rule) do
                if k:sub(1, 1) ~= "_" then
                    if type(v) == "table" and type(result[k]) == "table" then
                        result[k] = runtime.deep_merge(result[k], v)
                    else
                        result[k] = v
                    end
                end
            end
        end
    end
    return result
end

--------------------------------------------------------------------------------
-- Registry accessor
--------------------------------------------------------------------------------

---Get a registry instance for the given key
---@param key string Registry key (e.g., "monitors", "keyboards", "mice")
---@return table Registry instance
function runtime.registry(key)
    assert(runtime._current, "runtime.registry() called before config was loaded")
    return Registry.new(runtime._current, key)
end

--------------------------------------------------------------------------------
-- Default environment (built from configurators)
--------------------------------------------------------------------------------

runtime.default_environment = {
    color = color,
    monitor = monitor_config.get_configurator(helpers),
    input = input_config.get_configurator(helpers),
    actions = action_config.get_configurator(helpers),
    plugin = plugin_module.get_plugin_function(),
}

--------------------------------------------------------------------------------
-- Runtime execution
--------------------------------------------------------------------------------

function runtime.execute(instance, fn, mode)
    instance.registry.mode = mode

    local prev_runtime = _G._runtime
    _G._runtime = instance

    local prev_env = getfenv(fn)
    setfenv(fn, instance.env)

    local results = { pcall(fn) }
    setfenv(fn, prev_env)
    _G._runtime = prev_runtime
    instance.registry.mode = nil

    local status = table.remove(results, 1)
    if not status then
        return false, results[1]
    else
        return true, unpack(results)
    end
end

-- Track which run_once blocks have been executed (persists across reloads)
local executed_run_once = {}

function runtime.new()
    local instance = {
        env = {},
        registry = {
            monitors = { rules = {}, resolved = {} },
            keyboards = { rules = {}, resolved = {} },
            mice = { rules = {}, resolved = {} },
            run_verbs = {},      -- verbs to run every time
            run_once_verbs = {}, -- verbs to run only once
        }
    }

    for k, v in pairs(runtime.default_environment) do
        instance.env[k] = v
    end
    instance.env._runtime = instance

    -- run: execute verbs every time the config is loaded
    instance.env.run = function(verbs)
        if type(verbs) == "function" then
            verbs = { verbs }
        end
        for _, verb in ipairs(verbs) do
            table.insert(instance.registry.run_verbs, verb)
        end
    end

    -- run_once: execute verbs only the first time (not on reload)
    instance.env.run_once = function(verbs, id)
        if type(verbs) == "function" then
            verbs = { verbs }
        end
        -- Generate an ID based on the call location if not provided
        if not id then
            local info = debug.getinfo(2, "Sl")
            id = string.format("%s:%d", info.short_src or "config", info.currentline or 0)
        end

        -- Only queue if not already executed
        if not executed_run_once[id] then
            for _, verb in ipairs(verbs) do
                table.insert(instance.registry.run_once_verbs, { verb = verb, id = id })
            end
        end
    end

    -- Custom require that handles @boring/ paths
    local custom_require = plugin_module.create_custom_require(require)
    setmetatable(instance.env, {
        __index = function(_, key)
            if key == "require" then
                return custom_require
            end
            return _G[key]
        end
    })
    return instance
end

-- Execute the queued run verbs
function runtime.execute_run_verbs(instance)
    local log = require("shared.log")

    -- Execute run verbs (every time)
    for _, verb in ipairs(instance.registry.run_verbs or {}) do
        local ok, err = pcall(verb)
        if not ok then
            log.error("run verb failed: %s", err)
        end
    end

    -- Execute run_once verbs (only first time)
    for _, item in ipairs(instance.registry.run_once_verbs or {}) do
        if not executed_run_once[item.id] then
            local ok, err = pcall(item.verb)
            if not ok then
                log.error("run_once verb failed: %s", err)
            end
            executed_run_once[item.id] = true
        end
    end
end

-- Reset run_once tracking (useful for testing)
function runtime.reset_run_once()
    executed_run_once = {}
end

return runtime
