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
--   })

local color = require("shared.color")

local plugin = { name = "borders" }

local SIDES = { "top", "bottom", "left", "right" }

function plugin:mount(config, ctx)
    local colors = config.colors or {}
    local width = config.width or 2
    local normal = color.float4(color.parse(colors.normal, { 0.53, 0.53, 0.53, 1 }))
    local focused = color.float4(color.parse(colors.focused, { 1, 1, 1, 1 }))
    local urgent = color.float4(color.parse(colors.urgent, color.parse(colors.focused, { 1, 1, 1, 1 })))
    local lib = boring.wl.lib
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
        b.top.node:set_position(x0, y0)
        b.bottom:set_size(g.width + width * 2, width)
        b.bottom.node:set_position(x0, g.y + g.height)
        b.left:set_size(width, g.height)
        b.left.node:set_position(x0, g.y)
        b.right:set_size(width, g.height)
        b.right.node:set_position(g.x + g.width, g.y)
    end

    local function paint(w)
        local b = w.data.borders
        if not b then return end
        local c = w == boring.focused() and focused or (w.urgent and urgent or normal)
        for _, side in ipairs(SIDES) do b[side]:set_color(c) end
        -- No borders around fullscreen windows.
        for _, side in ipairs(SIDES) do b[side].node:set_enabled(not w.fullscreen) end
    end

    local function attach(w)
        if w.data.borders then return end
        local function rect() return lib.wlr_scene_rect_create(w.tree, 0, 0, normal) end
        w.data.borders = { top = rect(), bottom = rect(), left = rect(), right = rect() }
        update(w)
        paint(w)
    end

    local function detach(w)
        local b = w.data.borders
        if not b then return end
        for _, side in ipairs(SIDES) do b[side].node:destroy() end
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
