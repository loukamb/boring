-- plugins/borders.lua
-- Draw solid borders around windows.
--
--   plugin("@boring/borders"):mount({
--       width = 2,
--       colors = { normal = "#737373", focused = "#f59e0b" },
--   })

local color = require("shared.color")
local ffi = require("ffi")

local plugin = { name = "borders" }

local DEFAULTS = { width = 2, normal = "#888888", focused = "#ffffff" }

local function parse_color(value)
    if type(value) == "string" then
        return color.hex(value) or { 0.5, 0.5, 0.5, 1.0 }
    elseif type(value) == "table" then
        return value
    end
    return { 0.5, 0.5, 0.5, 1.0 }
end

-- wlroots wants premultiplied alpha.
local function premultiply(rgba)
    local r, g, b, a = rgba[1], rgba[2], rgba[3], rgba[4] or 1
    return ffi.new("float[4]", { r * a, g * a, b * a, a })
end

function plugin:mount(config, ctx)
    local colors = config.colors or {}
    local width = config.width or DEFAULTS.width
    local normal = premultiply(parse_color(colors.normal or DEFAULTS.normal))
    local focused = premultiply(parse_color(colors.focused or DEFAULTS.focused))
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

    local function set_color(w, c)
        local b = w.data.borders
        if not b then return end
        for _, side in ipairs({ "top", "bottom", "left", "right" }) do
            b[side]:set_color(c)
        end
    end

    local function attach(w)
        local function rect() return lib.wlr_scene_rect_create(w.tree, 0, 0, normal) end
        w.data.borders = { top = rect(), bottom = rect(), left = rect(), right = rect() }
        update(w)
    end

    scope:subscribe(boring.events, "window:map", attach)
    scope:subscribe(boring.events, "window:unmap", function(w)
        local b = w.data.borders
        if not b then return end
        for _, side in ipairs({ "top", "bottom", "left", "right" }) do
            b[side].node:destroy()
        end
        w.data.borders = nil
    end)
    scope:subscribe(boring.events, "window:commit", update)
    scope:subscribe(boring.events, "window:focus", function(w) set_color(w, focused) end)
    scope:subscribe(boring.events, "window:blur", function(w) set_color(w, normal) end)

    -- Borders for windows that are already open (mounted after a reload).
    for _, w in ipairs(boring.windows()) do
        if not w.data.borders then
            attach(w)
            if w == boring.focused() then set_color(w, focused) end
        end
    end

    -- Remove borders from windows that still have them.
    scope:defer(function()
        for _, w in ipairs(boring.windows()) do
            local b = w.data.borders
            if b then
                for _, side in ipairs({ "top", "bottom", "left", "right" }) do b[side].node:destroy() end
                w.data.borders = nil
            end
        end
    end)
end

plugin._private = {
    parse_color = parse_color,
    premultiply = premultiply,
}

return plugin
