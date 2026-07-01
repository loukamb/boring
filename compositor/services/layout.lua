--- Layout Service - Manage window layouts per-monitor
--- Supports multiple layout modes via pluggable layout implementations
---@class compositor.services.layout
local log = require("shared.log")
local state = require("compositor.state")

local layout_service = {
    -- Layout registry: name -> layout_implementation
    layouts = {},

    -- Per-monitor layout state: output_ptr -> monitor_state
    monitor_states = {},

    -- Default layout mode
    default_layout = "stacking",

    -- State
    initialized = false,
}

--------------------------------------------------------------------------------
-- Layout Interface Definition
--------------------------------------------------------------------------------
-- Each layout implementation must provide these methods:
--   :init(monitor_state) - Initialize layout for a monitor
--   :shutdown(monitor_state) - Cleanup layout state
--   :on_window_add(monitor_state, surface) - Handle new window
--   :on_window_remove(monitor_state, surface) - Handle window removal
--   :on_window_resize(monitor_state, surface, width, height) - Handle resize
--   :position_window(monitor_state, surface) - Calculate window position
--   :get_window_at(monitor_state, x, y) - Hit test at screen coordinates
--   :begin_move(monitor_state, surface, cursor_x, cursor_y) - Start window move
--   :update_move(monitor_state, cursor_x, cursor_y) - Update during move
--   :end_move(monitor_state) - End window move
--   :begin_resize(monitor_state, surface, cursor_x, cursor_y, edges) - Start resize
--   :update_resize(monitor_state, cursor_x, cursor_y) - Update during resize
--   :end_resize(monitor_state) - End resize
--
-- Optional methods:
--   :enter_fullscreen(monitor_state, surface) - Enter fullscreen mode
--   :exit_fullscreen(monitor_state) - Exit fullscreen mode

--------------------------------------------------------------------------------
-- Monitor State Structure
--------------------------------------------------------------------------------
-- Each monitor has its own layout state:
-- {
--     output = Output object,
--     layout_name = "stacking",
--     layout = layout_implementation reference,
--     config = { cell = 16, gap = 4, ... },
--     windows = { surface1, surface2, ... },
--     fullscreen_surface = nil,
--     -- Layout-specific state stored here by implementation
-- }

--------------------------------------------------------------------------------
-- Layout Registration
--------------------------------------------------------------------------------

function layout_service:register(name, implementation)
    if self.layouts[name] then
        log.warn("Layout '%s' already registered, overwriting", name)
    end
    self.layouts[name] = implementation
end

function layout_service:get_layout(name)
    return self.layouts[name]
end

function layout_service:list_layouts()
    local names = {}
    for name, _ in pairs(self.layouts) do
        table.insert(names, name)
    end
    return names
end

function layout_service:unregister(name)
    if self.layouts[name] then
        self.layouts[name] = nil

        return true
    end
    return false
end

--------------------------------------------------------------------------------
-- Monitor State Management
--------------------------------------------------------------------------------

function layout_service:create_monitor_state(output, config)
    local wl = require("shared.wayland.server")
    local ptr_key = wl.ptr_to_num(output:raw())

    local layout_name = config.mode or self.default_layout
    local layout = self.layouts[layout_name]

    if not layout then
        log.warn("Layout '%s' not found, falling back to '%s'", layout_name, self.default_layout)
        layout_name = self.default_layout
        layout = self.layouts[layout_name]
    end

    if not layout then
        log.error("No layout implementations available!")
        return nil
    end

    local monitor_state = {
        output = output,
        layout_name = layout_name,
        layout = layout,
        config = {
            cell = config.cell or 16,
            gap = config.gap or 4,
            gaps = config.gaps or { inner = 4, outer = 4, smart = true },
        },
        windows = {},
        fullscreen_surface = nil,
    }

    self.monitor_states[ptr_key] = monitor_state

    -- Initialize the layout for this monitor
    if layout.init then
        layout:init(monitor_state)
    end


    return monitor_state
end

function layout_service:get_monitor_state(output)
    local wl = require("shared.wayland.server")
    local ptr_key = wl.ptr_to_num(output:raw())
    return self.monitor_states[ptr_key]
end

function layout_service:get_monitor_state_by_ptr(output_ptr)
    local wl = require("shared.wayland.server")
    local ptr_key = wl.ptr_to_num(output_ptr)
    return self.monitor_states[ptr_key]
end

function layout_service:remove_monitor_state(output)
    local wl = require("shared.wayland.server")
    local ptr_key = wl.ptr_to_num(output:raw())
    local monitor_state = self.monitor_states[ptr_key]

    if monitor_state and monitor_state.layout and monitor_state.layout.shutdown then
        monitor_state.layout:shutdown(monitor_state)
    end

    self.monitor_states[ptr_key] = nil
end

function layout_service:get_all_monitor_states()
    local states = {}
    for _, ms in pairs(self.monitor_states) do
        table.insert(states, ms)
    end
    return states
end

--------------------------------------------------------------------------------
-- Layout Delegation Methods
--------------------------------------------------------------------------------

function layout_service:on_window_add(surface, output)
    local monitor_state = output and self:get_monitor_state(output) or self:get_primary_monitor_state()
    if not monitor_state then
        log.warn("No monitor state for window add")
        return
    end

    table.insert(monitor_state.windows, surface)
    surface:set_monitor_state(monitor_state)

    if monitor_state.layout and monitor_state.layout.on_window_add then
        monitor_state.layout:on_window_add(monitor_state, surface)
    end
end

function layout_service:on_window_remove(surface)
    local monitor_state = surface:monitor_state()
    if not monitor_state then return end

    if monitor_state.fullscreen_surface == surface then
        monitor_state.fullscreen_surface = nil
        surface._pre_fullscreen = nil
    end

    -- Remove from windows list
    for i, w in ipairs(monitor_state.windows) do
        if w == surface then
            table.remove(monitor_state.windows, i)
            break
        end
    end

    if monitor_state.layout and monitor_state.layout.on_window_remove then
        monitor_state.layout:on_window_remove(monitor_state, surface)
    end

    surface:set_monitor_state(nil)
end

function layout_service:on_window_resize(surface, width, height)
    local monitor_state = surface:monitor_state()
    if not monitor_state then return end

    if monitor_state.layout and monitor_state.layout.on_window_resize then
        monitor_state.layout:on_window_resize(monitor_state, surface, width, height)
    end
end

function layout_service:split_focused(layout)
    local surface_service = require("compositor.services.surface")
    local surface = surface_service:get_focused_window()
    local monitor_state = surface and surface:monitor_state() or self:get_primary_monitor_state()
    if not monitor_state or not monitor_state.layout then
        return false
    end

    if monitor_state.layout.split then
        return monitor_state.layout:split(monitor_state, surface, layout)
    end

    local method = layout == "vertical" and monitor_state.layout.split_vertical
        or monitor_state.layout.split_horizontal
    if method then
        return method(monitor_state.layout, monitor_state, surface)
    end
    return false
end

function layout_service:position_window(surface)
    local monitor_state = surface:monitor_state()
    if not monitor_state then return end

    if monitor_state.layout and monitor_state.layout.position_window then
        monitor_state.layout:position_window(monitor_state, surface)
    end
end

function layout_service:get_window_at(monitor_state, x, y)
    if not monitor_state then return nil end

    if monitor_state.layout and monitor_state.layout.get_window_at then
        return monitor_state.layout:get_window_at(monitor_state, x, y)
    end
    return nil
end

--------------------------------------------------------------------------------
-- Interactive Move/Resize Delegation
--------------------------------------------------------------------------------

function layout_service:begin_move(surface, cursor_x, cursor_y)
    local monitor_state = surface:monitor_state()
    if not monitor_state then return false end

    if monitor_state.layout and monitor_state.layout.begin_move then
        return monitor_state.layout:begin_move(monitor_state, surface, cursor_x, cursor_y)
    end
    return false
end

function layout_service:update_move(surface, cursor_x, cursor_y)
    local monitor_state = surface:monitor_state()
    if not monitor_state then return end

    if monitor_state.layout and monitor_state.layout.update_move then
        monitor_state.layout:update_move(monitor_state, cursor_x, cursor_y)
    end
end

function layout_service:end_move(surface)
    local monitor_state = surface:monitor_state()
    if not monitor_state then return end

    if monitor_state.layout and monitor_state.layout.end_move then
        monitor_state.layout:end_move(monitor_state)
    end
end

function layout_service:begin_resize(surface, cursor_x, cursor_y, edges)
    local monitor_state = surface:monitor_state()
    if not monitor_state then return false end

    if monitor_state.layout and monitor_state.layout.begin_resize then
        return monitor_state.layout:begin_resize(monitor_state, surface, cursor_x, cursor_y, edges)
    end
    return false
end

function layout_service:update_resize(surface, cursor_x, cursor_y)
    local monitor_state = surface:monitor_state()
    if not monitor_state then return end

    if monitor_state.layout and monitor_state.layout.update_resize then
        monitor_state.layout:update_resize(monitor_state, cursor_x, cursor_y)
    end
end

function layout_service:end_resize(surface)
    local monitor_state = surface:monitor_state()
    if not monitor_state then return end

    if monitor_state.layout and monitor_state.layout.end_resize then
        monitor_state.layout:end_resize(monitor_state)
    end
end

-- Fullscreen Delegation
--------------------------------------------------------------------------------

function layout_service:enter_fullscreen(surface)
    local monitor_state = surface:monitor_state()
    if not monitor_state then return false end

    if monitor_state.layout and monitor_state.layout.enter_fullscreen then
        return monitor_state.layout:enter_fullscreen(monitor_state, surface)
    end
    return false
end

function layout_service:exit_fullscreen(monitor_state)
    if not monitor_state then return false end

    if monitor_state.layout and monitor_state.layout.exit_fullscreen then
        return monitor_state.layout:exit_fullscreen(monitor_state)
    end
    return false
end

function layout_service:is_fullscreen(monitor_state)
    return monitor_state and monitor_state.fullscreen_surface ~= nil
end

--------------------------------------------------------------------------------
-- Helper Methods
--------------------------------------------------------------------------------

function layout_service:get_primary_monitor_state()
    -- Return the first monitor state (primary)
    for _, ms in pairs(self.monitor_states) do
        return ms
    end
    return nil
end

function layout_service:get_monitor_state_at(x, y)
    local output_service = require("compositor.services.output")
    local outputs = output_service:get_outputs()

    for _, output in ipairs(outputs) do
        local ms = self:get_monitor_state(output)
        if ms then
            -- Check if x, y is within this output's bounds
            -- For now, return first monitor (multi-monitor support can be added later)
            return ms
        end
    end

    return self:get_primary_monitor_state()
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function layout_service:init()
    if self.initialized then
        return
    end


    -- Listen for output events to create/destroy monitor states
    local output_service = require("compositor.services.output")
    output_service.events:on("output:create", function(output)
        local output_name = output.name
        local config = state.resolve_monitor(output_name)
        local layout_config = config.layout or {}
        self:create_monitor_state(output, layout_config)
    end)

    output_service.events:on("output:destroy", function(output)
        self:remove_monitor_state(output)
    end)

    -- Create monitor states for any existing outputs
    for _, output in ipairs(output_service:get_outputs()) do
        local output_name = output.name
        local config = state.resolve_monitor(output_name)
        local layout_config = config.layout or {}
        self:create_monitor_state(output, layout_config)
    end

    self.initialized = true
end

function layout_service:shutdown()
    for _, ms in pairs(self.monitor_states) do
        if ms.layout and ms.layout.shutdown then
            ms.layout:shutdown(ms)
        end
    end
    self.monitor_states = {}
    self.initialized = false
end

return layout_service
