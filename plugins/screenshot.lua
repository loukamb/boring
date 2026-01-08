-- plugins/screenshot.lua
-- Screenshot plugin stub


local plugin = {
    name = "screenshot",
}

function plugin:mount(config)
    -- Return actions that can be bound to shortcuts
    return {
        actions = {
            area = function()

            end,
            fullscreen = function()

            end,
            window = function()

            end,
        }
    }
end

function plugin:unmount()

end

return plugin
