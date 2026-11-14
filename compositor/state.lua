-- compositor/state.lua
-- The loaded configuration: (re)loading the config file and resolving
-- settings for devices from it.

local config = require("compositor.config")
local log = require("shared.log")

local state = {}

--- Load (or reload) the configuration file. Unmounts plugins mounted by the
--- previous load; the config mounts the ones it wants again.
---
--- The first load fails hard. A reload with a broken config (syntax error)
--- is refused and the running config stays in place.
function state.reload_config(path)
    local first = state.path == nil
    path = path or state.path
    if not path then
        local paths = require("compositor.config.paths")
        path = paths.find_config() or "default.lua"
    end

    local fn, err = loadfile(path)
    if not fn then
        if first then error("failed to load config: " .. tostring(err), 0) end
        log.error("not reloading, the config has errors: %s", tostring(err))
        return false
    end
    state.path = path

    require("compositor.plugin").unmount_all()
    local instance = config.new()
    config._current = instance
    local ok, run_err = config.execute(instance, fn, "config")
    if not ok then
        if first then error("failed to run config: " .. tostring(run_err), 0) end
        log.error("config failed while reloading: %s", tostring(run_err))
        return false
    end
    if not first then log.info("reloaded %s", path) end
    return true
end

--- Run the config's run/run_once verbs (once the compositor is up).
function state.execute_startup_verbs()
    if config._current then
        config.execute_run_verbs(config._current)
    end
end

function state.resolve_monitor(name) return config.resolve("monitors", name) end
function state.resolve_keyboard(name) return config.resolve("keyboards", name) end
function state.resolve_mouse(name) return config.resolve("mice", name) end

return state
