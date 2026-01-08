-- compositor/config/action/zoom.lua
-- Zoom-related actions

local M = {}

---@param helpers table Runtime helpers
---@return table Zoom actions
function M.get_actions(helpers)
    return {
        -- Mouse scroll zoom action (string identifier for special handling)
        zoom = "zoom",

        ---Zoom in via keyboard
        zoom_in_keyboard = function()
            local layout_service = require("compositor.services.layout")
            local input_service = require("compositor.services.input")
            local cursor = input_service:get_cursor()
            if cursor then
                local monitor_state = layout_service:get_monitor_state_at(cursor.x, cursor.y)
                if monitor_state then
                    layout_service:zoom(monitor_state, 1, cursor.x, cursor.y)
                end
            end
        end,

        ---Zoom out via keyboard
        zoom_out_keyboard = function()
            local layout_service = require("compositor.services.layout")
            local input_service = require("compositor.services.input")
            local cursor = input_service:get_cursor()
            if cursor then
                local monitor_state = layout_service:get_monitor_state_at(cursor.x, cursor.y)
                if monitor_state then
                    layout_service:zoom(monitor_state, -1, cursor.x, cursor.y)
                end
            end
        end,

        ---Reset zoom to 1x
        zoom_reset = function()
            local layout_service = require("compositor.services.layout")
            local monitor_state = layout_service:get_primary_monitor_state()
            if monitor_state then
                monitor_state.viewport.zoom = 1.0
                monitor_state.viewport.offset_x = 0
                monitor_state.viewport.offset_y = 0
                if monitor_state.layout and monitor_state.layout.position_window then
                    for _, surface in ipairs(monitor_state.windows) do
                        monitor_state.layout:position_window(monitor_state, surface)
                    end
                end
            end
        end,
    }
end

return M
