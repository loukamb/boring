-- Runtime output configuration by clients:
--   wlr-output-management    (kanshi, wdisplays, wlr-randr)
--   wlr-output-power-management  (DPMS: turning screens off and on)
--
-- The current configuration is republished whenever outputs come, go or
-- change; applied configurations are tested and committed output by output.

local ffi = require("ffi")
local wl = require("shared.wl")
local log = require("shared.log")
local layout = require("compositor.layout")

local lib = wl.lib

local output_management = {}

local function output_for(server, wlr_output)
    for _, o in ipairs(server.outputs) do
        if o.wlr == wlr_output then return o end
    end
end

function output_management.setup(server)
    local manager = lib.wlr_output_manager_v1_create(server.display)

    local function publish()
        local config = lib.wlr_output_configuration_v1_create()
        for _, o in ipairs(server.outputs) do
            local head = lib.wlr_output_configuration_head_v1_create(config, o.wlr)
            local b = o:box()
            head.state.x, head.state.y = b.x, b.y
        end
        lib.wlr_output_manager_v1_set_configuration(manager, config)
    end
    server.events:on("output:add", publish)
    server.events:on("output:remove", function() publish() end)
    server.events:on("output:change", publish)

    -- Apply (or just test) a configuration from a client.
    local function apply(config, test_only)
        local ok = true
        for head in wl.list.each(config.heads, "struct wlr_output_configuration_head_v1", "link") do
            local st = ffi.new("struct wlr_output_state")
            lib.wlr_output_state_init(st)
            lib.wlr_output_head_v1_state_apply(head.state, st)
            local wlr_output = head.state.output
            if test_only then
                ok = ok and wlr_output:test_state(st)
            else
                ok = ok and wlr_output:commit_state(st)
                if head.state.enabled then
                    lib.wlr_output_layout_add(server.output_layout, wlr_output, head.state.x, head.state.y)
                else
                    lib.wlr_output_layout_remove(server.output_layout, wlr_output)
                end
                local o = output_for(server, wlr_output)
                if o then
                    o.usable = o:box()
                    server.events:emit("output:change", o)
                    layout.usable_area_changed(server, o)
                end
            end
            lib.wlr_output_state_finish(st)
        end
        if ok then
            lib.wlr_output_configuration_v1_send_succeeded(config)
        else
            log.warn("output configuration %s failed", test_only and "test" or "apply")
            lib.wlr_output_configuration_v1_send_failed(config)
        end
        lib.wlr_output_configuration_v1_destroy(config)
        if not test_only then publish() end
    end

    server.scope:listen(manager.events.apply, function(config) apply(config, false) end,
        "struct wlr_output_configuration_v1")
    server.scope:listen(manager.events.test, function(config) apply(config, true) end,
        "struct wlr_output_configuration_v1")

    -- DPMS.
    local power = lib.wlr_output_power_manager_v1_create(server.display)
    server.scope:listen(power.events.set_mode, function(event)
        local st = ffi.new("struct wlr_output_state")
        lib.wlr_output_state_init(st)
        st:set_enabled(event.mode == ffi.C.ZWLR_OUTPUT_POWER_V1_MODE_ON)
        event.output:commit_state(st)
        lib.wlr_output_state_finish(st)
    end, "struct wlr_output_power_v1_set_mode_event")

    return { "zwlr_output_manager_v1", "zwlr_output_head_v1", "zwlr_output_mode_v1",
        "zwlr_output_configuration_v1", "zwlr_output_configuration_head_v1",
        "zwlr_output_power_manager_v1", "zwlr_output_power_v1" }
end

return output_management
