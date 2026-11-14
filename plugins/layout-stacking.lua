-- plugins/layout-stacking.lua
-- Floating windows with optional server-side title bars.
--
--   plugin("@boring/layout-stacking"):mount({
--       outputs = { "DP-1" },          -- default: every output
--       theme = {
--           height = 24,               -- title bar height
--           font = "Sans Bold 10",
--           title = "#0a0a0a",         -- title text
--           decorations = "#f59e0b",   -- title bar
--           button_background = "#f59e0b",
--           button_foreground = "#0a0a0a",
--       },
--       controls = {                   -- left to right
--           { type = "title" },
--           { type = "spacer" },
--           { type = "button", icon = "close", on_click = function(w) w:close() end },
--       },
--   })
--
-- Without `controls` (or with `decorations = false`) windows get no title bar.
-- Dragging the title bar moves the window; new windows open centred.

local color = require("shared.color")
local ffi = require("ffi")
local spaces = require("@boring/library/spaces")

local plugin = { name = "layout-stacking" }

local ICONS = { close = "×", maximize = "□", minimize = "–" }

local function rgba(value, fallback)
    local c = type(value) == "string" and color.hex(value) or value
    return c or fallback
end

-- float[4] premultiplied, for scene rects.
local function float4(c)
    local a = c[4] or 1
    return ffi.new("float[4]", { c[1] * a, c[2] * a, c[3] * a, a })
end

local function make_stacking(config)
    local theme = config.theme or {}
    local controls = config.controls
    local decorated = controls ~= nil and config.decorations ~= false
    local height = theme.height or 24
    local font = theme.font or "Sans Bold 10"
    local bar_color = rgba(theme.decorations, { 0.2, 0.2, 0.2, 1 })
    local title_color = rgba(theme.title, { 1, 1, 1, 1 })
    local button_bg = rgba(theme.button_background, bar_color)
    local button_fg = rgba(theme.button_foreground, title_color)

    local lib = boring.wl.lib
    local buffer = require("shared.wl.buffer")
    local image = require("shared.image")
    if not image.available then image = nil end

    -- Text as a scene buffer under `tree`, or nil if there's no text renderer.
    local function text_node(tree, text, c)
        if not image or not text or text == "" then return nil end
        local ok, width, h, mask = pcall(image.text, text, font)
        if not ok or not width then return nil end
        local buf = buffer.new(width, h)
        local px = buf.pixels
        for i = 0, width * h - 1 do
            local coverage = mask:byte(i + 1) / 255
            if coverage > 0 then
                px[i] = buffer.argb(c[1], c[2], c[3], (c[4] or 1) * coverage)
            end
        end
        return buffer.attach(tree, buf), width, h
    end

    local stacking = {}

    local function destroy_decorations(w)
        local d = w.data.stacking
        if not d then return end
        for _, off in ipairs(d.handlers) do off() end
        d.tree.node:destroy()
        w.data.stacking = nil
    end

    local function build_decorations(w)
        destroy_decorations(w)
        if not decorated then return end
        local g = w:geometry()
        if g.width <= 0 then return end

        local tree = lib.wlr_scene_tree_create(w.tree)
        tree.node:set_position(g.x, g.y - height)
        local d = { tree = tree, width = g.width, x = g.x, y = g.y, title = w:title(), handlers = {} }
        w.data.stacking = d

        local bar = lib.wlr_scene_rect_create(tree, g.width, height, float4(bar_color))
        d.handlers[#d.handlers + 1] = boring.on_click(bar.node, function(win, button)
            if button == 0x110 then boring.begin_move(win) end
        end)

        -- Lay controls out left to right; a spacer takes the remaining width.
        local fixed, spacers = 0, 0
        for _, c in ipairs(controls) do
            if c.type == "button" then fixed = fixed + height
            elseif c.type == "spacer" then spacers = spacers + 1 end
        end
        local x = 0
        for _, c in ipairs(controls) do
            if c.type == "title" then
                local node, tw, th = text_node(tree, d.title, title_color)
                if node then
                    node.node:set_position(x + 8, math.floor((height - th) / 2))
                    -- Clip long titles to the space the bar has.
                    local avail = math.max(0, g.width - fixed - 16)
                    if tw > avail then
                        local box = ffi.new("struct wlr_fbox", { 0, 0, avail, th })
                        node:set_source_box(box)
                        node:set_dest_size(avail, th)
                    end
                end
            elseif c.type == "spacer" then
                x = x + math.max(0, (g.width - fixed) / math.max(spacers, 1))
            elseif c.type == "button" then
                local bx = x
                local rect = lib.wlr_scene_rect_create(tree, height, height, float4(button_bg))
                rect.node:set_position(math.floor(bx), 0)
                local node, iw, ih = text_node(tree, ICONS[c.icon] or c.icon or "", button_fg)
                if node then
                    node.node:set_position(math.floor(bx + (height - iw) / 2), math.floor((height - ih) / 2))
                end
                local on_click = c.on_click
                d.handlers[#d.handlers + 1] = boring.on_click(rect.node, function(win)
                    if on_click then on_click(win) end
                end)
                x = x + height
            end
        end
    end

    local function managed(w)
        local space = spaces.of(w)
        return space ~= nil and space.impl == stacking
    end

    local function update_decorations(w)
        if not decorated or not managed(w) then return end
        local d = w.data.stacking
        if w.fullscreen then
            if d then d.tree.node:set_enabled(false) end
            return
        end
        local g = w:geometry()
        if not d or d.width ~= g.width or d.title ~= w:title() then
            build_decorations(w)
        else
            d.tree.node:set_enabled(true)
            if d.x ~= g.x or d.y ~= g.y then
                d.x, d.y = g.x, g.y
                d.tree.node:set_position(g.x, g.y - height)
            end
        end
    end
    stacking.update_decorations = update_decorations

    --- X11 windows asking for a place and size get it.
    function stacking.request_geometry(w, box)
        if not managed(w) or w.fullscreen then return end
        w:set_position(box.x, box.y)
        w:set_size(box.width, box.height)
    end

    function stacking:add(space, w)
        build_decorations(w)
        -- Windows keep their place when the layout is re-registered (reload).
        if w.data.stacking_placed then return end
        w.data.stacking_placed = true
        if w.impl.positioned then return end
        -- Centre in the usable area, title bar included.
        local area = space.output.usable
        local g = w:geometry()
        local top = decorated and height or 0
        local x = area.x + math.max(0, (area.width - g.width) / 2) - g.x
        local y = area.y + top + math.max(0, (area.height - g.height - top) / 2) - g.y
        w:set_position(x, y)
    end

    function stacking:remove(_, w)
        destroy_decorations(w)
    end

    function stacking:shutdown(space)
        for _, w in ipairs(space.windows) do destroy_decorations(w) end
    end

    -- No move/resize: windows follow the pointer (spaces' default).

    return stacking
end

function plugin:mount(config, ctx)
    local stacking = make_stacking(config)
    ctx.scope:subscribe(boring.events, "window:commit", stacking.update_decorations)
    ctx.scope:subscribe(boring.events, "window:title", stacking.update_decorations)
    ctx.scope:subscribe(boring.events, "window:fullscreen", stacking.update_decorations)
    ctx.scope:subscribe(boring.events, "window:request_geometry", stacking.request_geometry)
    ctx.scope:defer(spaces.register("stacking", stacking, { outputs = config.outputs }))
    return { layout = stacking }
end

return plugin
