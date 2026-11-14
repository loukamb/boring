#!/usr/bin/env luajit
-- The compositor program: `luajit switch.lua compositor [--config=path]`.
--
-- Order matters: the server and every protocol exist before the config
-- runs, so config and plugins can use the whole `boring` API; the backend
-- starts afterwards, so outputs and input devices are configured from the
-- loaded config as they appear.

local log = require("shared.log")
local registry = require("shared.wayland.registry")
local server_mod = require("compositor.server")
local state = require("compositor.state")
local api = require("compositor.api")
local process = require("compositor.process")

local modules = {
    require("compositor.output"),
    require("compositor.input"),
    require("compositor.pointer"),
    require("compositor.xdg_shell"),
    require("compositor.layer_shell"),
    require("compositor.protocols"),
}

local CORE_INTERFACES = {
    "wl_compositor", "wl_surface", "wl_region", "wl_callback", "wl_buffer",
    "wl_shm", "wl_shm_pool", "wl_output", "wl_registry", "wl_display",
}

local function main(args)
    if args.protocols then
        -- Only listing protocols: no outputs or input needed.
        require("ffi").C.setenv("WLR_BACKENDS", "headless", 1)
    end
    local server = server_mod.new()
    process.setup(server)

    for _, name in ipairs(CORE_INTERFACES) do registry.implement(name) end
    for _, m in ipairs(modules) do
        for _, name in ipairs(m.setup(server) or {}) do
            registry.implement(name)
        end
    end

    if args.protocols then
        local filter = args.protocols ~= true and args.protocols or nil
        print(registry.report(filter))
        server_mod.destroy(server)
        return
    end

    api.create(server)
    state.reload_config(args.config)

    server_mod.start(server)
    if args.startup then process.spawn(args.startup) end
    server.events:emit("ready")
    state.execute_startup_verbs()

    server_mod.run(server)

    server.events:emit("shutdown")
    require("compositor.plugin").unmount_all()
    process.stop_all()
    server_mod.destroy(server)
end

return function(args)
    local ok, err = xpcall(main, debug.traceback, args)
    if not ok then
        log.error("fatal: %s", err)
        os.exit(1)
    end
end
