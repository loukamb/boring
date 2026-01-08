-- compositor/config/action/window.lua
-- Window-related actions (string identifiers for mouse handling)

local M = {}

---@param helpers table Runtime helpers
---@return table Window actions
function M.get_actions(helpers)
    return {
        -- Mouse drag actions (string identifiers for special handling by input service)
        move_window = "move_window",
        drag_window = "drag_window",  -- Alias for move_window
        resize_window = "resize_window",
    }
end

return M
