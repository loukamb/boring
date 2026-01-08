-- compositor/config/action/fullscreen.lua
-- Fullscreen-related actions

local M = {}

---@param helpers table Runtime helpers
---@return table Fullscreen actions
function M.get_actions(helpers)
    return {
        ---Enter fullscreen for focused window
        fullscreen = function()
            local layout_service = require("compositor.services.layout")
            local surface_service = require("compositor.services.surface")
            local surface = surface_service:get_focused_window()
            if surface then
                layout_service:enter_fullscreen(surface)
            end
        end,

        ---Exit fullscreen mode
        exit_fullscreen = function()
            local layout_service = require("compositor.services.layout")
            local monitor_state = layout_service:get_primary_monitor_state()
            if monitor_state then
                layout_service:exit_fullscreen(monitor_state)
            end
        end,
    }
end

return M
