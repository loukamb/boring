-- compositor/config/action/layout.lua
-- Layout-related actions

local M = {}

---@param helpers table Runtime helpers
---@return table Layout actions
function M.get_actions(helpers)
    return {
        split_horizontal = function()
            local layout_service = require("compositor.services.layout")
            return layout_service:split_focused("horizontal")
        end,

        split_vertical = function()
            local layout_service = require("compositor.services.layout")
            return layout_service:split_focused("vertical")
        end,
    }
end

return M
