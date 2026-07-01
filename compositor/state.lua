-- compositor/state.lua
-- Simplified state module - uses config.registry() for resolution

local config = require("compositor.config")
local event_emitter = require("shared.emitter")

local state = {
    events = event_emitter.new(),
}

local function isArray(t)
    if type(t) ~= "table" then return false end
    local len = #t
    if len == 0 then return false end
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > len or math.floor(k) ~= k then
            return false
        end
    end
    return true
end

local function emitOnDiffs(old, new, parent)
    parent = parent or "config"
    old = old or {}

    if isArray(new) or isArray(old) then
        local maxLen = math.max(#old, #new)
        for i = 1, maxLen do
            local oldVal = old[i]
            local newVal = new[i]
            if type(newVal) == "table" and type(oldVal) == "table" then
                emitOnDiffs(oldVal, newVal, string.format("%s[%d]", parent, i))
            elseif oldVal ~= newVal then
                state.events:emit(string.format("mutation:%s[%d]", parent, i), newVal)
            end
        end
        return
    end

    for key, value in pairs(new) do
        local oldVal = old[key]
        if type(value) == "table" then
            emitOnDiffs(oldVal, value, string.format("%s.%s", parent, key))
        else
            if oldVal ~= value then
                state.events:emit(string.format("mutation:%s.%s", parent, key), value)
            end
        end
    end
end

function state.reload_config(pathToConfig, doNotEmit)
    if not pathToConfig then
        local paths = require("compositor.config.paths")
        pathToConfig = paths.find_config() or "default.lua"
    end

    local plugin_module = require("compositor.plugin")
    plugin_module.unmount_all()

    -- Create new runtime instance and set as current
    local runtime = config.new()
    config._current = runtime

    local fn, err = loadfile(pathToConfig)
    assert(fn, "Failed to load config: " .. (err or "unknown error"))

    local ok, load_err = config.execute(runtime, fn, "config")
    assert(ok, "Failed to execute config: " .. (load_err or "unknown error"))

    if not doNotEmit then
        emitOnDiffs(state._prev_registry, runtime.registry)
    end
    state._prev_registry = runtime.registry
end

-- Execute queued run/run_once verbs (called after compositor is ready)
function state.execute_startup_verbs()
    if config._current then
        config.execute_run_verbs(config._current)
    end
end

--------------------------------------------------------------------------------
-- Legacy resolution helpers (deprecated - use config.registry() instead)
-- These are kept for backward compatibility during transition
--------------------------------------------------------------------------------

function state.resolve_monitor(name)
    return config.registry("monitors"):resolve(name)
end

function state.resolve_keyboard(name)
    return config.registry("keyboards"):resolve(name)
end

function state.resolve_mouse(name)
    return config.registry("mice"):resolve(name)
end

function state.get_monitor_rules()
    return config.registry("monitors"):mutable_rules()
end

function state.get_keyboard_rules()
    return config.registry("keyboards"):mutable_rules()
end

function state.get_mouse_rules()
    return config.registry("mice"):mutable_rules()
end

return state
