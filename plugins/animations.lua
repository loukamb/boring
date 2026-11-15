-- plugins/animations.lua
-- Windows fade in when they open and fade out (shrinking a little) when
-- they close.
--
--   plugin("@boring/animations"):mount({
--       open = { duration = 180, easing = "out-cubic" },   -- false: no animation
--       close = { duration = 160, easing = "out-cubic", scale = 0.92 },
--   })
--
-- Closing windows are gone by the time they'd animate, so what fades out is
-- a copy of their last frame: the same buffers, in a tree of their own.

local animate = require("@boring/library/animate")
local scene = require("@boring/library/scene")

local plugin = { name = "animations" }

function plugin:mount(config, ctx)
    local scope = ctx.scope
    local open = config.open ~= false and (config.open or {}) or nil
    local close = config.close ~= false and (config.close or {}) or nil

    if open then
        scope:subscribe(boring.events, "window:map", function(w)
            local tree = scene.window(w)
            local function fade(v)
                if w.mapped then tree:set_opacity(v) end
            end
            animate.run(scope, animate.ease({
                from = 0, to = 1, duration = open.duration or 180, easing = open.easing or "out-cubic",
            }), fade, function() fade(1) end)
        end)
    end

    if close then
        local final_scale = close.scale or 0.92
        local ghosts = {} -- finish functions of copies still fading
        scope:defer(function()
            for finish in pairs(ghosts) do finish() end
        end)
        scope:subscribe(boring.events, "window:unmap", function(w)
            if not w:visible() then return end
            -- The copy, where the window was, just above it.
            local ghost = scene.window(w):snapshot()
            local copies = {}
            local min_x, min_y, max_x, max_y = math.huge, math.huge, -math.huge, -math.huge
            for node in ghost:children() do
                local x, y = node:position()
                local width, height = node:size()
                copies[#copies + 1] = { copy = node, x = x, y = y, width = width, height = height }
                min_x, min_y = math.min(min_x, x), math.min(min_y, y)
                max_x, max_y = math.max(max_x, x + width), math.max(max_y, y + height)
            end
            if #copies == 0 then
                ghost:destroy()
                return
            end
            local cx, cy = (min_x + max_x) / 2, (min_y + max_y) / 2

            local function frame(p)
                local s = 1 + (final_scale - 1) * p
                for _, c in ipairs(copies) do
                    c.copy:set_position(math.floor(cx + (c.x - cx) * s + 0.5), math.floor(cy + (c.y - cy) * s + 0.5))
                    c.copy:set_size(math.max(1, math.floor(c.width * s + 0.5)), math.max(1, math.floor(c.height * s + 0.5)))
                end
                ghost:set_opacity(1 - p)
            end
            frame(0)
            local binding
            local function finish()
                if not ghosts[finish] then return end
                ghosts[finish] = nil
                animate.stop(binding)
                ghost:destroy()
            end
            ghosts[finish] = true
            binding = animate.run(nil, animate.ease({
                from = 0, to = 1, duration = close.duration or 160, easing = close.easing or "out-cubic",
            }), frame, finish)
        end)
    end
end

return plugin
