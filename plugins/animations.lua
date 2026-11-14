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
local color = require("shared.color")

local plugin = { name = "animations" }

function plugin:mount(config, ctx)
    local wl = boring.wl
    local lib, C = wl.lib, wl.C
    local scope = ctx.scope
    local open = config.open ~= false and (config.open or {}) or nil
    local close = config.close ~= false and (config.close or {}) or nil

    -- Every buffer and rect under a scene tree, with its offset from it.
    local function collect(tree, ox, oy, out)
        for node in wl.list.each(tree.children, "struct wlr_scene_node", "link") do
            local x, y = ox + node.x, oy + node.y
            if node.type == C.WLR_SCENE_NODE_TREE then
                collect(lib.wlr_scene_tree_from_node(node), x, y, out)
            elseif node.type == C.WLR_SCENE_NODE_BUFFER then
                out[#out + 1] = { kind = "buffer", node = lib.wlr_scene_buffer_from_node(node), x = x, y = y }
            elseif node.type == C.WLR_SCENE_NODE_RECT and node.enabled then
                out[#out + 1] = { kind = "rect", node = lib.wlr_scene_rect_from_node(node), x = x, y = y }
            end
        end
        return out
    end

    if open then
        scope:subscribe(boring.events, "window:map", function(w)
            local function fade(v)
                if not w.mapped then return end
                for _, item in ipairs(collect(w.tree, 0, 0, {})) do
                    if item.kind == "buffer" then lib.wlr_scene_buffer_set_opacity(item.node, v) end
                end
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
            local items = collect(w.tree, 0, 0, {})
            if #items == 0 then return end

            -- The copy, where the window was, just above it.
            local ghost = lib.wlr_scene_tree_create(w.tree.node.parent)
            ghost.node:set_position(w.tree.node.x, w.tree.node.y)
            ghost.node:place_above(w.tree.node)
            local copies = {}
            local min_x, min_y, max_x, max_y = math.huge, math.huge, -math.huge, -math.huge
            for _, item in ipairs(items) do
                local copy
                if item.kind == "buffer" then
                    local src = item.node
                    if src.buffer ~= nil then
                        local width = src.dst_width > 0 and src.dst_width or src.buffer.width
                        local height = src.dst_height > 0 and src.dst_height or src.buffer.height
                        local node = lib.wlr_scene_buffer_create(ghost, src.buffer)
                        copy = { kind = "buffer", node = node, x = item.x, y = item.y, width = width, height = height }
                    end
                else
                    local r = item.node
                    local c = { r.color[0], r.color[1], r.color[2], r.color[3] }
                    local node = lib.wlr_scene_rect_create(ghost, r.width, r.height, r.color)
                    copy = { kind = "rect", node = node, x = item.x, y = item.y, width = r.width, height = r.height,
                        color = c, scratch = color.float4({ 0, 0, 0, 0 }) }
                end
                if copy then
                    copies[#copies + 1] = copy
                    min_x, min_y = math.min(min_x, copy.x), math.min(min_y, copy.y)
                    max_x = math.max(max_x, copy.x + copy.width)
                    max_y = math.max(max_y, copy.y + copy.height)
                end
            end
            if #copies == 0 then
                ghost.node:destroy()
                return
            end
            local cx, cy = (min_x + max_x) / 2, (min_y + max_y) / 2

            local function frame(p)
                local s = 1 + (final_scale - 1) * p
                local alpha = 1 - p
                for _, c in ipairs(copies) do
                    local x = math.floor(cx + (c.x - cx) * s + 0.5)
                    local y = math.floor(cy + (c.y - cy) * s + 0.5)
                    local width = math.max(1, math.floor(c.width * s + 0.5))
                    local height = math.max(1, math.floor(c.height * s + 0.5))
                    if c.kind == "buffer" then
                        c.node.node:set_position(x, y)
                        lib.wlr_scene_buffer_set_dest_size(c.node, width, height)
                        lib.wlr_scene_buffer_set_opacity(c.node, alpha)
                    else
                        c.node.node:set_position(x, y)
                        c.node:set_size(width, height)
                        -- Rect colours are premultiplied: scale every channel.
                        local k = c.scratch
                        k[0], k[1], k[2], k[3] = c.color[1] * alpha, c.color[2] * alpha, c.color[3] * alpha, c.color[4] * alpha
                        c.node:set_color(k)
                    end
                end
            end
            frame(0)
            local binding
            local function finish()
                if not ghosts[finish] then return end
                ghosts[finish] = nil
                animate.stop(binding)
                ghost.node:destroy()
            end
            ghosts[finish] = true
            binding = animate.run(nil, animate.ease({
                from = 0, to = 1, duration = close.duration or 160, easing = close.easing or "out-cubic",
            }), frame, finish)
        end)
    end
end

return plugin
