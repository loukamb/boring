-- plugins/idle.lua
-- Lock the session and/or turn the screens off after a while without input.
-- Idle inhibitors (a video playing fullscreen) hold both off.
--
--   plugin("@boring/idle"):mount({
--       lock = { timeout = 300, command = "swaylock -f" },  -- seconds
--       screens = { timeout = 600 },                        -- outputs off; input turns them on
--   })

local plugin = { name = "idle" }

function plugin:mount(config, ctx)
    local scope = ctx.scope

    local lock = config.lock
    if lock and lock.command then
        scope:defer(boring.idle((lock.timeout or 300) * 1000, {
            idle = function()
                if not boring.locked() then boring.spawn(lock.command) end
            end,
        }))
    end

    local screens = config.screens
    if screens then
        local off = false
        local function power(on)
            off = not on
            for _, o in ipairs(boring.outputs()) do o:set_power(on) end
        end
        scope:defer(boring.idle((screens.timeout or 600) * 1000, {
            idle = function() power(false) end,
            resume = function() power(true) end,
        }))
        -- Outputs that appear while the screens are off stay on; unmounting
        -- turns everything back on.
        scope:defer(function() if off then power(true) end end)
    end
end

return plugin
