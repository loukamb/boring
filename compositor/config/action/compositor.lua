-- compositor/config/action/compositor.lua
-- Compositor lifecycle actions: exit, reload, close

local M = {}

---@param helpers table Runtime helpers
---@return table Compositor actions
function M.get_actions(helpers)
    return {
        ---Exit the compositor
        exit = function()
            local core_service = require("compositor.services.core")
            core_service:terminate()
        end,

        ---Reload configuration
        reload = function()
            local state_mod = require("compositor.state")
            local services_mod = require("compositor.services")
            state_mod.reload_config()
            services_mod.reload_wallpapers()
        end,

        ---Close the focused window
        close = function()
            local surface_service = require("compositor.services.surface")
            surface_service:close_focused_window()
        end,
    }
end

return M
