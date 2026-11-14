-- Outputs: configure new monitors from the config, render frames, track
-- their place in the layout.
--
-- An output record is a plain table:
--   { name, wlr, scene_output, layout_output, scope, usable = {x,y,width,height},
-- Events: output:add(o), output:change(o) (mode/scale/transform), output:remove(o).
--     box(o), size(o) }
-- `usable` is the area left after layer-shell exclusive zones (panels), in
-- layout coordinates; layouts should arrange windows inside it.

local bit = require("bit")
local wl = require("shared.wl")
local log = require("shared.log")
local state = require("compositor.state")
local layout = require("compositor.layout")

local ffi, lib, C = wl.ffi, wl.lib, wl.C

local output = {}

local function degrees_to_transform(degrees, flip)
    local base = ({ [90] = C.WL_OUTPUT_TRANSFORM_90, [180] = C.WL_OUTPUT_TRANSFORM_180,
        [270] = C.WL_OUTPUT_TRANSFORM_270 })[degrees or 0] or C.WL_OUTPUT_TRANSFORM_NORMAL
    if flip then
        base = base + C.WL_OUTPUT_TRANSFORM_FLIPPED
    end
    return base
end

local function find_mode(wlr_output, width, height, refresh)
    for mode in wl.list.each(wlr_output.modes, "struct wlr_output_mode", "link") do
        if mode.width == width and mode.height == height
            and (not refresh or refresh == 0 or mode.refresh == refresh * 1000) then
            return mode
        end
    end
    return nil
end

local box_scratch = ffi.new("struct wlr_box")

--- Output position and size in layout coordinates.
local function box(o)
    lib.wlr_output_layout_get_box(o.server.output_layout, o.wlr, box_scratch)
    return { x = box_scratch.x, y = box_scratch.y, width = box_scratch.width, height = box_scratch.height }
end

--- Size in layout coordinates (accounts for scale and rotation).
local function size(o)
    local b = box(o)
    return b.width, b.height
end

-- Apply the monitor config to an output state. Returns false if the config
-- couldn't be committed, in which case we retry with the preferred mode.
local function commit(wlr_output, config, use_config_mode)
    local st = ffi.new("struct wlr_output_state")
    lib.wlr_output_state_init(st)
    st:set_enabled(true)

    local mode = nil
    if use_config_mode and config.width and config.height and config.mode ~= "preferred" then
        mode = find_mode(wlr_output, config.width, config.height, config.refresh_rate)
        if not mode then
            st:set_custom_mode(config.width, config.height, (config.refresh_rate or 0) * 1000)
        end
    else
        mode = lib.wlr_output_preferred_mode(wlr_output)
    end
    if mode ~= nil then st:set_mode(mode) end

    if config.scale and config.scale > 0 then st:set_scale(config.scale) end
    if config.rotate then
        local degrees, flip = config.rotate, false
        if type(config.rotate) == "table" then
            degrees, flip = config.rotate.degrees or 0, config.rotate.flip or false
        end
        st:set_transform(degrees_to_transform(degrees, flip))
    end

    local ok = wlr_output:test_state(st) and wlr_output:commit_state(st)
    lib.wlr_output_state_finish(st)
    return ok
end

local now = ffi.new("struct timespec")

local function new_output(server, wlr_output)
    local name = wl.string(wlr_output.name)
    local config = state.resolve_monitor(name)

    wlr_output:init_render(server.allocator, server.renderer)
    if not commit(wlr_output, config, true) then
        log.warn("output %s: configured mode failed, using the preferred mode", name)
        if not commit(wlr_output, config, false) then
            log.error("output %s: couldn't enable", name)
        end
    end

    local o = {
        name = name,
        wlr = wlr_output,
        server = server,
        scope = server.scope:child("output " .. name),
        box = box,
        size = size,
    }

    if config.x ~= nil or config.y ~= nil then
        o.layout_output = lib.wlr_output_layout_add(server.output_layout, wlr_output, config.x or 0, config.y or 0)
    else
        o.layout_output = lib.wlr_output_layout_add_auto(server.output_layout, wlr_output)
    end
    o.scene_output = lib.wlr_scene_output_create(server.scene, wlr_output)
    lib.wlr_scene_output_layout_add_output(server.scene_layout, o.layout_output, o.scene_output)
    o.usable = box(o)

    o.scope:listen(wlr_output.events.frame, function()
        local scene_output = o.scene_output
        if not scene_output:commit(nil) then
            return
        end
        C.clock_gettime(C.CLOCK_MONOTONIC, now)
        scene_output:send_frame_done(now)
    end)

    -- Mode, scale or transform changed: the output's box did too.
    local geometry_bits = bit.bor(C.WLR_OUTPUT_STATE_MODE, C.WLR_OUTPUT_STATE_SCALE, C.WLR_OUTPUT_STATE_TRANSFORM)
    o.scope:listen(wlr_output.events.commit, function(event)
        if bit.band(event.state.committed, geometry_bits) ~= 0 then
            server.events:emit("output:change", o)
        end
    end, "struct wlr_output_event_commit")

    o.scope:listen(wlr_output.events.request_state, function(event)
        wlr_output:commit_state(event.state)
    end, "struct wlr_output_event_request_state")

    o.scope:listen(wlr_output.events.destroy, function()
        server.events:emit("output:remove", o)
        layout.remove_monitor(server, o)
        for i, x in ipairs(server.outputs) do
            if x == o then
                table.remove(server.outputs, i)
                break
            end
        end
        o.scope:close()
    end)

    table.insert(server.outputs, o)
    layout.add_monitor(server, o, config.layout)
    server.events:emit("output:add", o)
end

function output.setup(server)
    server.scope:listen(server.backend.events.new_output, function(wlr_output)
        new_output(server, wlr_output)
    end, "struct wlr_output")
end

--- The output record at a point in layout coordinates.
function output.at(server, x, y)
    local wlr_output = lib.wlr_output_layout_output_at(server.output_layout, x, y)
    if wlr_output == nil then return nil end
    for _, o in ipairs(server.outputs) do
        if o.wlr == wlr_output then return o end
    end
end

output._private = {
    degrees_to_transform = degrees_to_transform,
    find_mode = find_mode,
}

return output
