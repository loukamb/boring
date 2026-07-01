-- plugins/borders.lua
-- Draw borders around windows using wlr_scene_rect

local wl = require("shared.wayland.server")
local color_mod = require("shared.color")
local ffi = wl._ffi

local plugin = {
    name = "borders",
}

-- Default configuration
local default_config = {
    width = 2,
    colors = {
        normal = "#888888",
        focused = "#ffffff",
        urgent = "#ff0000",
    }
}

-- Parse color to RGBA array for wlr_scene_rect (0-1 range)
local function parse_color(hex_or_table)
    if type(hex_or_table) == "string" then
        return color_mod.hex(hex_or_table) or { 0.5, 0.5, 0.5, 1.0 }
    elseif type(hex_or_table) == "table" then
        return hex_or_table -- Already a float array
    end
    return { 0.5, 0.5, 0.5, 1.0 }
end

-- Premultiply alpha (Sway pattern)
local function premultiply(rgba)
    local r, g, b, a = rgba[1], rgba[2], rgba[3], rgba[4]
    return ffi.new("float[4]", { r * a, g * a, b * a, a })
end

-- Create border rects for a surface
local function create_border(surface, color_rgba)
    if not surface.scene_tree then return end

    local tree = surface.scene_tree
    local color = premultiply(color_rgba)

    -- Create 4 rect nodes as children of surface's scene tree
    surface._border = {
        top = wl.roots.scene_rect_create(tree, 0, 0, color),
        bottom = wl.roots.scene_rect_create(tree, 0, 0, color),
        left = wl.roots.scene_rect_create(tree, 0, 0, color),
        right = wl.roots.scene_rect_create(tree, 0, 0, color),
    }
end

-- Update border geometry
local function update_border(surface, border_width)
    local b = surface._border
    if not b then return end
    if not surface.scene_tree then return end

    -- Get surface geometry
    local geo = { width = 0, height = 0 }
    if surface.role_obj and surface.role_obj.base then
        local g = surface.role_obj.base.current.geometry
        geo.width = g.width
        geo.height = g.height
    end

    if geo.width <= 0 or geo.height <= 0 then return end

    local cache = surface._border_geometry
    if cache and cache.width == geo.width and cache.height == geo.height and cache.border_width == border_width then
        return
    end
    surface._border_geometry = {
        width = geo.width,
        height = geo.height,
        border_width = border_width,
    }

    -- Top: full width, at top edge
    wl.roots.scene_rect_set_size(b.top, geo.width + border_width * 2, border_width)
    wl.roots.scene_node_set_position(b.top.node, -border_width, -border_width)

    -- Bottom: full width, at bottom edge
    wl.roots.scene_rect_set_size(b.bottom, geo.width + border_width * 2, border_width)
    wl.roots.scene_node_set_position(b.bottom.node, -border_width, geo.height)

    -- Left: inner height, at left edge
    wl.roots.scene_rect_set_size(b.left, border_width, geo.height)
    wl.roots.scene_node_set_position(b.left.node, -border_width, 0)

    -- Right: inner height, at right edge
    wl.roots.scene_rect_set_size(b.right, border_width, geo.height)
    wl.roots.scene_node_set_position(b.right.node, geo.width, 0)
end

-- Set border color
local function set_border_color(surface, color_rgba)
    local b = surface._border
    if not b then return end

    local color = premultiply(color_rgba)
    for _, rect in pairs(b) do
        if rect then
            wl.roots.scene_rect_set_color(rect, color)
        end
    end
end

-- Destroy border
local function destroy_border(surface)
    local b = surface._border
    if not b then return end

    for _, rect in pairs(b) do
        if rect and rect.node then
            wl.roots.scene_node_destroy(rect.node)
        end
    end
    surface._border = nil
    surface._border_geometry = nil
end

function plugin:mount(config)
    config = config or {}
    local colors = {
        normal = parse_color((config.colors or {}).normal or default_config.colors.normal),
        focused = parse_color((config.colors or {}).focused or default_config.colors.focused),
        urgent = parse_color((config.colors or {}).urgent or default_config.colors.urgent),
    }
    local border_width = config.width or default_config.width

    local surface_service = require("compositor.services.surface")

    -- Store config for use in callbacks
    self._config = { colors = colors, width = border_width }
    self._listeners = {}

    -- Subscribe to surface events
    table.insert(self._listeners, surface_service.events:on("surface:map", function(surface)
        create_border(surface, colors.normal)
        update_border(surface, border_width)
    end))

    table.insert(self._listeners, surface_service.events:on("surface:unmap", function(surface)
        destroy_border(surface)
    end))

    table.insert(self._listeners, surface_service.events:on("surface:commit", function(surface)
        update_border(surface, border_width)
    end))

    table.insert(self._listeners, surface_service.events:on("surface:focus", function(surface)
        set_border_color(surface, colors.focused)
    end))

    table.insert(self._listeners, surface_service.events:on("surface:blur", function(surface)
        set_border_color(surface, colors.normal)
    end))


    return {}
end

function plugin:unmount()
    -- Unsubscribe all listeners
    for _, listener in ipairs(self._listeners or {}) do
        if listener and listener.off then
            listener:off()
        end
    end
    self._listeners = nil
    self._config = nil
end

plugin._private = {
    parse_color = parse_color,
    premultiply = premultiply,
}

return plugin
