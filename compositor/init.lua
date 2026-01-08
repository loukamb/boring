#!/usr/bin/env luajit
package.path = "./?/init.lua;./?.lua;" .. package.path

local log = require("shared.log")
local state = require("compositor.state")
local services = require("compositor.services")

local function main(args)
    state.reload_config(args.config, true)

    services.init(args)
    services.run()


    services.shutdown()
end

return function(args)
    local ok, err = xpcall(main, debug.traceback, args)
    if not ok then
        log.error("Fatal error: %s", err)
        os.exit(1)
    end
end
