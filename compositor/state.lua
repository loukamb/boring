-- compositor/state.lua
-- The loaded configuration: (re)loading the config file and resolving
-- settings for devices from it.

local config = require("compositor.config")

local state = {}

--- Load (or reload) the configuration file. Unmounts plugins mounted by the
--- previous load; the config mounts the ones it wants again.
function state.reload_config(path)
    if not path then
        local paths = require("compositor.config.paths")
        path = paths.find_config() or "default.lua"
    end
    state.path = path

    require("compositor.plugin").unmount_all()

    local instance = config.new()
    config._current = instance

    local fn, err = loadfile(path)
    assert(fn, "failed to load config: " .. tostring(err))
    local ok, run_err = config.execute(instance, fn, "config")
    assert(ok, "failed to run config: " .. tostring(run_err))
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
