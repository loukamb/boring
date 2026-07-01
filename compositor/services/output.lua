-- services/output_service.lua - Manage physical screens and coordinate space
-- Responsibility: output_layout, outputs list, output lifecycle

local wl = require("shared.wayland.server")
local proto = require("shared.wayland.registry")
local state = require("compositor.state")
local ffi = wl._ffi
local event_emitter = require("shared.emitter")

local core_service = require("compositor.services.core")

local WL_OUTPUT_TRANSFORM_NORMAL = 0
local WL_OUTPUT_TRANSFORM_90 = 1
local WL_OUTPUT_TRANSFORM_180 = 2
local WL_OUTPUT_TRANSFORM_270 = 3
local WL_OUTPUT_TRANSFORM_FLIPPED = 4
local WL_OUTPUT_TRANSFORM_FLIPPED_90 = 5
local WL_OUTPUT_TRANSFORM_FLIPPED_180 = 6
local WL_OUTPUT_TRANSFORM_FLIPPED_270 = 7

local function degrees_to_transform(degrees, flip)
    degrees = degrees or 0
    local base
    if degrees == 90 then
        base = WL_OUTPUT_TRANSFORM_90
    elseif degrees == 180 then
        base = WL_OUTPUT_TRANSFORM_180
    elseif degrees == 270 then
        base = WL_OUTPUT_TRANSFORM_270
    else
        base = WL_OUTPUT_TRANSFORM_NORMAL
    end
    if flip then
        base = base + WL_OUTPUT_TRANSFORM_FLIPPED
    end
    return base
end

local output_service = {
    -- Output management
    output_layout = nil,
    outputs = {},

    -- Scene references (set by surface_service)
    scene = nil,
    scene_layout = nil,

    -- Listeners
    listeners = {},

    -- Event emitter for service events
    events = event_emitter.new(),

    -- Local registry for output -> listener data mapping
    registry = wl.new_registry(),

    -- State
    initialized = false,
}

-- Handle output frame event
local function output_frame(listener, data)
    local output = output_service.registry:get(listener)
    if not output then return end

    -- render_service is loaded after output_service, require at runtime
    local render_service = require("compositor.services.render")
    render_service:render_output(output)
end

-- Handle output state request
local function output_request_state(listener, data)
    local output = output_service.registry:get(listener)
    if not output then return end

    local event = ffi.cast("const struct wlr_output_event_request_state*", data)
    wl.roots.output_commit_state(output.wlr_output, event.state)
end

-- Handle output destruction
local function output_destroy(listener, data)
    local output = output_service.registry:get(listener)
    if not output then return end


    -- Emit destroy event before cleanup
    output_service.events:emit("output:destroy", output)
    output_service.events:emit("output:remove", output.wlr_output)

    -- Remove listeners from their signals
    wl.list_remove(output.frame_listener[0].link)
    wl.list_remove(output.request_state_listener[0].link)
    wl.list_remove(output.destroy_listener[0].link)

    -- Remove from outputs list
    for i, o in ipairs(output_service.outputs) do
        if o == output then
            table.remove(output_service.outputs, i)
            break
        end
    end

    -- Clean up registry entries
    output_service.registry:remove(output.frame_listener)
    output_service.registry:remove(output.request_state_listener)
    output_service.registry:remove(output.destroy_listener)
end

local function server_new_output(listener, data)
    local wlr_output = ffi.cast("struct wlr_output*", data)
    local output_name = ffi.string(wlr_output.name)



    local config = state.resolve_monitor(output_name)

    wl.roots.output_init_render(wlr_output, core_service:get_allocator(), core_service:get_renderer())

    local output_state = ffi.new("struct wlr_output_state")
    wl.roots.output_state_init(output_state)
    wl.roots.output_state_set_enabled(output_state, true)

    local mode = wl.roots.output_preferred_mode(wlr_output)
    if mode ~= nil and mode ~= ffi.NULL then
        wl.roots.output_state_set_mode(output_state, mode)
    end

    if config.scale and config.scale > 0 then
        wl.roots.output_state_set_scale(output_state, config.scale)
    end

    if config.rotate then
        local degrees, flip = 0, false
        if type(config.rotate) == "number" then
            degrees = config.rotate
        elseif type(config.rotate) == "table" then
            degrees = config.rotate.degrees or 0
            flip = config.rotate.flip or false
        end
        local transform = degrees_to_transform(degrees, flip)
        wl.roots.output_state_set_transform(output_state, transform)
    end

    wl.roots.output_commit_state(wlr_output, output_state)
    wl.roots.output_state_finish(output_state)

    -- Create output tracking object
    local output = {
        wlr_output = wlr_output,
    }

    -- Set up listeners
    output.frame_listener = wl.create_listener(output_frame)
    output_service.registry:set(output.frame_listener, output)
    wl.signal_add(wlr_output.events.frame, output.frame_listener)

    output.request_state_listener = wl.create_listener(output_request_state)
    output_service.registry:set(output.request_state_listener, output)
    wl.signal_add(wlr_output.events.request_state, output.request_state_listener)

    output.destroy_listener = wl.create_listener(output_destroy)
    output_service.registry:set(output.destroy_listener, output)
    wl.signal_add(wlr_output.events.destroy, output.destroy_listener)

    table.insert(output_service.outputs, output)

    -- Add to output layout
    local l_output = wl.roots.output_layout_add_auto(output_service.output_layout, wlr_output)
    output.layout_output = l_output

    -- If scene is available, create scene output
    if output_service.scene then
        local scene_output = wl.roots.scene_output_create(output_service.scene, wlr_output)
        wl.roots.scene_output_layout_add_output(output_service.scene_layout, l_output, scene_output)
        output.scene_output = scene_output
    end

    -- Emit new_output event (also as output:add for plugins)
    output_service.events:emit("output:create", output)
    output_service.events:emit("output:add", output.wlr_output, output_name)
end

-- Initialize the output service
function output_service:init()
    if self.initialized then
        return
    end


    -- Register implemented protocols
    proto.implement("wl_output")
    proto.implement("wl_shm")
    proto.implement("wl_shm_pool")
    proto.implement("wl_registry")

    -- Create output layout
    self.output_layout = wl.roots.output_layout_create(core_service:get_display())

    -- Create viewporter (Phase 1 - Low Hanging Fruit)
    self.viewporter = wl.roots.viewporter_create(core_service:get_display())
    if self.viewporter and self.viewporter ~= ffi.NULL then
        proto.implement("wp_viewporter")
        proto.implement("wp_viewport")
    end

    -- Create XDG output manager (Phase 1 - Low Hanging Fruit)
    self.xdg_output_manager = wl.roots.xdg_output_manager_v1_create(core_service:get_display(), self.output_layout)
    if self.xdg_output_manager and self.xdg_output_manager ~= ffi.NULL then
        proto.implement("zxdg_output_manager_v1")
        proto.implement("zxdg_output_v1")
    end

    -- Create gamma control manager (Phase 2 - Easy)
    self.gamma_control_manager = wl.roots.gamma_control_manager_v1_create(core_service:get_display())
    if self.gamma_control_manager and self.gamma_control_manager ~= ffi.NULL then
        proto.implement("zwlr_gamma_control_manager_v1")
        proto.implement("zwlr_gamma_control_v1")
    end

    -- Create screencopy manager (Phase 2 - Easy)
    self.screencopy_manager = wl.roots.screencopy_manager_v1_create(core_service:get_display())
    if self.screencopy_manager and self.screencopy_manager ~= ffi.NULL then
        proto.implement("zwlr_screencopy_manager_v1")
        proto.implement("zwlr_screencopy_frame_v1")
    end

    -- Listen for new outputs
    self.listeners.new_output = wl.create_listener(server_new_output)
    wl.signal_add(core_service:get_backend().events.new_output, self.listeners.new_output)

    self.initialized = true
end

-- Set the scene for scene output creation (called by surface_service)
function output_service:set_scene(scene, scene_layout)
    self.scene = scene
    self.scene_layout = scene_layout

    -- Create scene outputs for any existing outputs
    for _, output in ipairs(self.outputs) do
        if not output.scene_output then
            local scene_output = wl.roots.scene_output_create(scene, output.wlr_output)
            wl.roots.scene_output_layout_add_output(scene_layout, output.layout_output, scene_output)
            output.scene_output = scene_output
        end
    end
end

-- Get the output layout
function output_service:get_output_layout()
    return self.output_layout
end

-- Get all outputs
function output_service:get_outputs()
    return self.outputs
end

-- Get cursor limits (max layout box)
function output_service:get_cursor_limits()
    local box = ffi.new("struct wlr_box")
    wl.roots.output_layout_get_box(self.output_layout, nil, box)
    return box
end

-- Get output dimensions
function output_service:get_output_dimensions(wlr_output)
    local function effective_dimensions(output_ptr)
        if output_ptr and wl.roots.output_effective_resolution then
            local width = ffi.new("int[1]")
            local height = ffi.new("int[1]")
            wl.roots.output_effective_resolution(output_ptr, width, height)
            if width[0] > 0 and height[0] > 0 then
                return width[0], height[0]
            end
        end
        return nil, nil
    end

    -- Find the output in our list
    for _, output in ipairs(self.outputs) do
        if output.wlr_output == wlr_output then
            local width, height = effective_dimensions(output.wlr_output)
            return width or output.wlr_output.width, height or output.wlr_output.height
        end
    end
    -- If passed an output object directly
    if wlr_output.width then
        local width, height = effective_dimensions(wlr_output)
        return width or wlr_output.width, height or wlr_output.height
    end
    return nil, nil
end

-- Get output position in layout
function output_service:get_output_position(wlr_output)
    local box = ffi.new("struct wlr_box")
    wl.roots.output_layout_get_box(self.output_layout, wlr_output, box)
    return box.x, box.y
end

return output_service
