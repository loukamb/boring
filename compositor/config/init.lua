-- compositor/config/init.lua
-- Configuration runtime: runs config files (and plugins) in a sandboxed
-- environment providing `boring`, `monitor`, `input`, `actions`, `plugin`,
-- `color`, `run` and `run_once`.

local rules = require("compositor.config.rules")
local plugin_module = require("compositor.plugin")
local color = require("shared.color")

local runtime = {}

-- The instance whose config was loaded last (what the compositor uses).
runtime._current = nil

-- The instance whose config is executing right now (for `monitor.new` etc.).
local executing = nil

local function list_of(key)
    local instance = executing or runtime._current
    assert(instance, "configuration used before it was loaded")
    return instance.registry[key].rules
end

runtime.deep_merge = rules.deep_merge
runtime.resolve_rules = rules.resolve

--- Resolve settings for a device from the loaded config.
function runtime.resolve(key, name)
    if not runtime._current then return {} end
    return rules.resolve(runtime._current.registry[key].rules, name)
end

runtime.default_environment = {
    color = color,
    monitor = rules.namespace("monitor", "monitors", rules.validate_monitor, list_of),
    input = {
        keyboard = rules.namespace("keyboard", "keyboards", rules.validate_keyboard, list_of),
        mouse = rules.namespace("mouse", "mice", rules.validate_mouse, list_of),
    },
    actions = require("compositor.config.actions"),
    plugin = function(name)
        return plugin_module.handle(require("compositor.api").current().server, name)
    end,
}

--- Run `fn` with `instance` as the configuration being defined.
function runtime.execute(instance, fn, mode)
    instance.registry.mode = mode
    local previous = executing
    executing = instance
    setfenv(fn, instance.env)
    local results = { pcall(fn) }
    executing = previous
    instance.registry.mode = nil
    if not results[1] then
        return false, results[2]
    end
    return unpack(results)
end

-- run_once blocks already executed (persists across reloads).
local executed_run_once = {}

function runtime.new()
    local instance = {
        env = {},
        registry = {
            monitors = { rules = {} },
            keyboards = { rules = {} },
            mice = { rules = {} },
            run_verbs = {},      -- verbs to run every time the config loads
            run_once_verbs = {}, -- verbs to run only the first time
        },
    }

    for k, v in pairs(runtime.default_environment) do
        instance.env[k] = v
    end
    instance.env.boring = require("compositor.api").current()

    function instance.env.run(verbs)
        if type(verbs) == "function" then verbs = { verbs } end
        for _, verb in ipairs(verbs) do
            table.insert(instance.registry.run_verbs, verb)
        end
    end

    function instance.env.run_once(verbs, id)
        if type(verbs) == "function" then verbs = { verbs } end
        if not id then
            local info = debug.getinfo(2, "Sl")
            id = string.format("%s:%d", info.short_src or "config", info.currentline or 0)
        end
        if not executed_run_once[id] then
            for _, verb in ipairs(verbs) do
                table.insert(instance.registry.run_once_verbs, { verb = verb, id = id })
            end
        end
    end

    -- The sandbox falls back to globals; `require` also understands @boring/.
    local function custom_require(name)
        return plugin_module.require(require("compositor.api").current().server, name)
    end
    setmetatable(instance.env, {
        __index = function(_, key)
            if key == "require" then return custom_require end
            return _G[key]
        end,
    })
    return instance
end

function runtime.execute_run_verbs(instance)
    local log = require("shared.log")
    for _, verb in ipairs(instance.registry.run_verbs) do
        local ok, err = pcall(verb)
        if not ok then log.error("run verb failed: %s", err) end
    end
    local ran = {}
    for _, item in ipairs(instance.registry.run_once_verbs) do
        if not executed_run_once[item.id] then
            local ok, err = pcall(item.verb)
            if not ok then log.error("run_once verb failed: %s", err) end
            ran[item.id] = true
        end
    end
    for id in pairs(ran) do executed_run_once[id] = true end
end

function runtime.reset_run_once()
    executed_run_once = {}
end

return runtime
