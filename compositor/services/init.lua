-- services/init.lua - Service loader
-- Initializes all services in the correct order

local proto               = require("shared.wayland.registry")
local state               = require("compositor.state")
local process             = require("compositor.process")
local color               = require("shared.color")
local plugin_module       = require("compositor.plugin")
local core_service        = require("compositor.services.core")
local output_service      = require("compositor.services.output")
local layout_service      = require("compositor.services.layout")
local surface_service     = require("compositor.services.surface")
local input_service       = require("compositor.services.input")
local render_service      = require("compositor.services.render")

local wallpaper_processes = {}

local function launch_wallpapers()
    local rules = state.get_monitor_rules()

    for i, rule in ipairs(rules) do
        if rule:is_enabled() and rule.background then
            local wallpaper_args = {}
            local name = rule.get_name and rule:get_name() or rule.name
            if name then
                table.insert(wallpaper_args, "--output=" .. name)
            end
            local bg = rule.background
            if type(bg) == "string" then
                if bg:sub(1, 1) == "#" then
                    table.insert(wallpaper_args, "--color=" .. bg)
                else
                    table.insert(wallpaper_args, "--image=" .. bg)
                end
            elseif type(bg) == "table" then
                if bg.path then
                    table.insert(wallpaper_args, "--image=" .. bg.path)
                    if bg.scale then
                        table.insert(wallpaper_args, "--scale=" .. bg.scale)
                    end
                elseif bg.r and bg.g and bg.b then
                    local c = color.rgb(bg.r, bg.g, bg.b)
                    table.insert(wallpaper_args, "--color=" .. color.to_hex(c))
                end
            end

            local key = name or tostring(i)
            if wallpaper_processes[key] then
                wallpaper_processes[key]:set_args(wallpaper_args)
                wallpaper_processes[key]:restart()
            else
                local p = process.new({
                    program = "clients.wallpaper",
                    args = wallpaper_args,
                })
                p:start_local()
                wallpaper_processes[key] = p
            end
        end
    end
end

-- Initialize services in dependency order
local function init(args)
    core_service:init()
    output_service:init()
    layout_service:init() -- Must be after output_service, before surface_service
    surface_service:init()
    input_service:init()
    render_service:init()

    -- Handle --protocols flag: print report and exit
    -- --protocols prints all, --protocols=implemented or --protocols=missing filters
    if args.protocols then
        local filter = args.protocols ~= true and args.protocols or nil
        print(proto.report(filter))
        os.exit(0)
    end

    -- Start the compositor
    core_service:start(args.startup)

    -- Emit ready event for plugins that need services to be initialized
    core_service.events:emit("compositor:ready")

    -- Launch wallpaper clients for monitors with backgrounds
    launch_wallpapers()

    -- Execute run/run_once verbs from config (now that WAYLAND_DISPLAY is set)
    state.execute_startup_verbs()
end

-- Run the event loop
local function run()
    core_service:run()
end

-- Cleanup
local function shutdown()
    -- Stop wallpaper processes
    for _, p in pairs(wallpaper_processes) do
        p:stop()
    end

    plugin_module.unmount_all()
    surface_service:shutdown()
    input_service:shutdown()
    output_service:shutdown()
    render_service:shutdown()
    layout_service:shutdown()
    core_service:shutdown()
end

return {
    init = init,
    run = run,
    shutdown = shutdown,
    reload_wallpapers = launch_wallpapers,
}
