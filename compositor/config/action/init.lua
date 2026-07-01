-- compositor/config/action/init.lua
-- Action module loader - merges all action modules into one namespace

local modules = {
    require("compositor.config.action.process"),
    require("compositor.config.action.compositor"),
    require("compositor.config.action.fullscreen"),
    require("compositor.config.action.layout"),
    require("compositor.config.action.window"),
}

local M = {}

---@param helpers table Runtime helpers
---@return table Merged action namespace
function M.get_configurator(helpers)
    local actions = {}
    for _, mod in ipairs(modules) do
        for k, v in pairs(mod.get_actions(helpers)) do
            actions[k] = v
        end
    end
    return actions
end

return M
