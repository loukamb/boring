-- compositor/config/monitor.lua
-- Monitor configuration module

local M = {}

---@param helpers table Runtime helpers (create_config_object, resolve_config, readonly, assert_if_type)
---@return table Monitor configurator namespace
function M.get_configurator(helpers)
    return {
        ---@return table
        all = function()
            local data = _runtime.registry.monitors
            return data and helpers.readonly(data.rules) or {}
        end,

        ---@param name string
        ---@return table|nil
        get = function(name)
            local data = _runtime.registry.monitors
            if not data then return nil end
            for _, rule in ipairs(data.rules) do
                if rule:get_name() == name then
                    return rule
                end
            end
            return nil
        end,

        ---@param name string
        ---@return table
        resolve = function(name)
            return helpers.resolve_config("monitors", name)
        end,

        ---@param opts table
        ---@return table
        new = function(opts)
            return helpers.create_config_object("monitor", "monitors", opts, function(o)
                if o.mode then
                    if o.mode == "preferred" then
                        o.width = nil
                        o.height = nil
                        o.refresh_rate = nil
                    else
                        local width, height, refresh_rate = o.mode:match("^(%d+)x(%d+)@(%d+)$")
                        if width then
                            o.width = tonumber(width)
                            o.height = tonumber(height)
                            o.refresh_rate = tonumber(refresh_rate)
                        end
                    end
                end
                helpers.assert_if_type(o, "x", "number", 0)
                helpers.assert_if_type(o, "y", "number", 0)
                helpers.assert_if_type(o, "scale", "number", 1)
                if o.rotate == nil then
                    o.rotate = 0
                elseif type(o.rotate) == "table" then
                    helpers.assert_if_type(o.rotate, "degrees", "number", 0)
                    helpers.assert_if_type(o.rotate, "flip", "boolean", false)
                end
            end)
        end
    }
end

return M
