-- compositor/config/input.lua
-- Keyboard and mouse configuration module

local M = {}

---@param helpers table Runtime helpers (create_config_object, resolve_config, readonly, assert_if_type)
---@return table Input configurator namespace
function M.get_configurator(helpers)
    return {
        keyboard = {
            ---@return table
            all = function()
                local data = _runtime.registry.keyboards
                return data and helpers.readonly(data.rules) or {}
            end,

            ---@param name string
            ---@return table|nil
            get = function(name)
                local data = _runtime.registry.keyboards
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
                return helpers.resolve_config("keyboards", name)
            end,

            ---@param opts table
            ---@return table
            new = function(opts)
                return helpers.create_config_object("keyboard", "keyboards", opts, function(o)
                    if o["repeat"] then
                        helpers.assert_if_type(o["repeat"], "delay", "number", 300)
                        helpers.assert_if_type(o["repeat"], "rate", "number", 30)
                    else
                        o["repeat"] = { delay = 300, rate = 30 }
                    end
                    if not o.xkb then
                        o.xkb = {}
                    end
                    if not o.shortcuts then
                        o.shortcuts = {}
                    end
                end)
            end
        },

        mouse = {
            ---@return table
            all = function()
                local data = _runtime.registry.mice
                return data and helpers.readonly(data.rules) or {}
            end,

            ---@param name string
            ---@return table|nil
            get = function(name)
                local data = _runtime.registry.mice
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
                return helpers.resolve_config("mice", name)
            end,

            ---@param opts table
            ---@return table
            new = function(opts)
                return helpers.create_config_object("mouse", "mice", opts, function(o)
                    helpers.assert_if_type(o, "handedness", "string", "right")
                    helpers.assert_if_type(o, "tap", "boolean", false)
                    if o.scroll then
                        helpers.assert_if_type(o.scroll, "speed", "number", 25)
                        helpers.assert_if_type(o.scroll, "natural", "boolean", false)
                    else
                        o.scroll = { speed = 25, natural = false }
                    end
                end)
            end
        }
    }
end

return M
