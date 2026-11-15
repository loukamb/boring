-- plugins/borders.lua
-- Draw solid borders around windows.
--
--   plugin("@boring/borders"):mount({
--       width = 2,
--       colors = {
--           normal = "#737373",
--           focused = "#f59e0b",
--           urgent = "#ef4444",    -- a window wants attention
--       },
--       transition = 150,          -- ms to blend between colours (0: none)
--   })
--
-- Windows with w.props.border = false (see the rules plugin) get none.
--
-- Colours can be animations (library/animate), e.g. an urgent border that
-- pulses: urgent = animate.pulse({ from = "#ef4444", to = "#7f1d1d", period = 800 }).

local animate = require("@boring/library/animate")
local scene = require("@boring/library/scene")

local plugin = { name = "borders" }

local SIDES = { "top", "bottom", "left", "right" }

function plugin:mount(config, ctx)
    local colors = config.colors or {}
    local width = config.width or 2
    local normal = colors.normal or "#888888"
    local focused = colors.focused or "#ffffff"
    local urgent = colors.urgent or focused
    local transition = { duration = config.transition or 150 }
    local scope = ctx.scope

    local function update(w)
        local b = w.data.borders
        if not b then return end
        local g = w:geometry()
        if g.width <= 0 or g.height <= 0 then return end
        if b.width == g.width and b.height == g.height and b.x == g.x and b.y == g.y then return end
        b.x, b.y, b.width, b.height = g.x, g.y, g.width, g.height
        local x0, y0 = g.x - width, g.y - width
        b.top:set_size(g.width + width * 2, width)
        b.top:set_position(x0, y0)
        b.bottom:set_size(g.width + width * 2, width)
        b.bottom:set_position(x0, g.y + g.height)
        b.left:set_size(width, g.height)
        b.left:set_position(x0, g.y)
        b.right:set_size(width, g.height)
        b.right:set_position(g.x + g.width, g.y)
    end

    local function wanted(w)
        return w == boring.focused() and focused or (w.urgent and urgent or normal)
    end

    local function paint(w)
        local b = w.data.borders
        if not b then return end
        local want = wanted(w)
        if b.want ~= want then
            b.want = want
            animate.to(b.color, want, transition)
        end
        -- No borders around fullscreen windows.
        for _, side in ipairs(SIDES) do b[side]:set_enabled(not w.fullscreen) end
    end

    local function attach(w)
        if w.data.borders or w.props.border == false then return end
        local tree = scene.window(w)
        local function rect() return scene.rect(tree, 0, 0, "#808080") end
        local b = { top = rect(), bottom = rect(), left = rect(), right = rect() }
        w.data.borders = b
        b.want = wanted(w)
        b.color = animate.bind(nil, b.want, function(c)
            for _, side in ipairs(SIDES) do b[side]:set_color(c) end
        end)
        update(w)
        paint(w)
    end

    local function detach(w)
        local b = w.data.borders
        if not b then return end
        animate.stop(b.color)
        for _, side in ipairs(SIDES) do b[side]:destroy() end
        w.data.borders = nil
    end

    scope:subscribe(boring.events, "window:map", attach)
    scope:subscribe(boring.events, "window:unmap", detach)
    scope:subscribe(boring.events, "window:commit", update)
    for _, event in ipairs({ "window:focus", "window:blur", "window:urgent", "window:fullscreen" }) do
        scope:subscribe(boring.events, event, paint)
    end

    -- Windows that are already open (mounted after a reload) get borders;
    -- unmounting removes them.
    for _, w in ipairs(boring.windows()) do attach(w) end
    scope:defer(function()
        for _, w in ipairs(boring.windows()) do detach(w) end
    end)
end

return plugin
