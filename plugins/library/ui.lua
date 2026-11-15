-- plugins/library/ui.lua
-- Widgets drawn by the compositor itself: launchers, notifications,
-- screenshot tools.
--
--   local ui = require("@boring/library/ui")
--   local theme = ui.theme(config.theme)             -- defaults + overrides
--
--   local view = ui.view({
--       theme = theme,
--       layer = "overlay",                           -- a library/scene layer name
--       parent = nil,                                -- or a library/scene tree
--       render = function(view)                      -- returns the widget tree
--           return ui.box(ui.column({
--               ui.text("Hello", { style = "title" }),
--               ui.button("Close", function() view:close() end),
--           }), { padding = 16, radius = 12 })
--       end,
--       place = function(width, height)              -- where it goes (layout coords)
--           local b = boring.outputs()[1]:box()
--           return b.x + (b.width - width) / 2, b.y + 100
--       end,
--   })
--   view:update()   -- render again after state changed
--   view:click(x, y) / view:contains(x, y) / view:close() / view:set_opacity(a)
--   view.tree   -- its library/scene tree (new after every update)
--
-- Widgets are plain tables made by the functions below. Sizes are in
-- layout pixels; colours are hex strings or { r, g, b, a }.
--
--   ui.text(str, { style = "body"|"title"|"muted", font, color, max_width, wrap })
--   ui.image(path, { size })                    -- any image libvips reads
--   ui.box(child, { padding, background, radius, border, border_width,
--                   width, height, min_width })
--   ui.row(children, { gap, align = "start"|"center"|"end" })
--   ui.column(children, { gap, align = "start"|"center"|"end"|"stretch" })
--   ui.spacer(width, height)
--   ui.button(label, on_click, { selected })
--   ui.input({ value, cursor, placeholder, width })   -- see ui.edit
--   ui.list(items, { render = fn(item, index, selected), selected, max })
--
-- Themes are plain tables (ui.default_theme lists every key); ui.theme
-- merges overrides into a copy, so a config can change any of them.

local ffi = require("ffi")
local color = require("shared.color")
local buffer = require("shared.wl.buffer")
local image = require("shared.image")
local text = require("@boring/library/text")

local ui = {}

ui.default_theme = {
    font = "Sans 11",
    title_font = "Sans Bold 12",
    small_font = "Sans 9",
    foreground = "#f5f5f5",
    muted = "#a3a3a3",
    background = "#1c1c1ef0",
    surface = "#2c2c2e",
    accent = "#0a84ff",
    selection = "#0a84ff",
    selection_foreground = "#ffffff",
    border = "#ffffff26",
    border_width = 1,
    radius = 12,
    padding = 12,
    gap = 8,
    input_height = 44,
    input_font = "Sans 16",
    row_height = 40,
    icon_size = 28,
}

--- The default theme with `overrides` merged in.
function ui.theme(overrides)
    local t = {}
    for k, v in pairs(ui.default_theme) do t[k] = v end
    for k, v in pairs(overrides or {}) do t[k] = v end
    return t
end

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

function ui.text(str, opts)
    opts = opts or {}
    return { kind = "text", text = str or "", style = opts.style, font = opts.font, color = opts.color,
        max_width = opts.max_width, wrap = opts.wrap }
end

function ui.image(path, opts)
    return { kind = "image", path = path, size = opts and opts.size }
end

function ui.box(child, opts)
    local w = { kind = "box", child = child }
    for k, v in pairs(opts or {}) do w[k] = v end
    return w
end

function ui.row(children, opts)
    opts = opts or {}
    return { kind = "row", children = children, gap = opts.gap, align = opts.align or "center" }
end

function ui.column(children, opts)
    opts = opts or {}
    return { kind = "column", children = children, gap = opts.gap, align = opts.align or "stretch" }
end

function ui.spacer(width, height)
    return { kind = "spacer", width = width or 0, height = height or 0 }
end

function ui.button(label, on_click, opts)
    opts = opts or {}
    return { kind = "button", label = label, on_click = on_click, selected = opts.selected }
end

function ui.input(opts)
    return { kind = "input", value = opts.value or "", cursor = opts.cursor, placeholder = opts.placeholder,
        width = opts.width }
end

function ui.list(items, opts)
    opts = opts or {}
    return { kind = "list", items = items, render = opts.render, selected = opts.selected, max = opts.max,
        offset = opts.offset }
end

--------------------------------------------------------------------------------
-- Text editing
--------------------------------------------------------------------------------

-- Byte offset of the UTF-8 character boundary before/after `pos`.
local function prev_char(s, pos)
    pos = pos - 1
    while pos > 0 and s:byte(pos + 1) and s:byte(pos + 1) >= 0x80 and s:byte(pos + 1) < 0xC0 do pos = pos - 1 end
    return math.max(0, pos)
end

local function next_char(s, pos)
    pos = pos + 1
    while pos < #s and s:byte(pos + 1) >= 0x80 and s:byte(pos + 1) < 0xC0 do pos = pos + 1 end
    return math.min(#s, pos)
end

--- Apply a key (from boring.grab_keyboard) to { value, cursor }. Returns
--- true if it changed something. Handles typing, BackSpace, Delete, Left,
--- Right, Home, End and Ctrl+BackSpace/Ctrl+u (delete a word / the line).
function ui.edit(field, ev)
    if not ev.pressed then return false end
    local s, c = field.value or "", field.cursor or #(field.value or "")
    local name = ev.name
    if ev.mods.ctrl and name == "u" then
        field.value, field.cursor = s:sub(c + 1), 0
    elseif name == "BackSpace" then
        if c == 0 then return false end
        local from = prev_char(s, c)
        if ev.mods.ctrl then
            from = c
            while from > 0 and s:sub(from, from):match("%s") do from = from - 1 end
            while from > 0 and not s:sub(from, from):match("%s") do from = from - 1 end
        end
        field.value, field.cursor = s:sub(1, from) .. s:sub(c + 1), from
    elseif name == "Delete" then
        if c >= #s then return false end
        field.value = s:sub(1, c) .. s:sub(next_char(s, c) + 1)
    elseif name == "Left" then
        field.cursor = prev_char(s, c)
    elseif name == "Right" then
        field.cursor = next_char(s, c)
    elseif name == "Home" then
        field.cursor = 0
    elseif name == "End" then
        field.cursor = #s
    elseif ev.text ~= "" and not ev.mods.ctrl and not ev.mods.logo then
        field.value, field.cursor = s:sub(1, c) .. ev.text .. s:sub(c + 1), c + #ev.text
    else
        return false
    end
    return true
end

--------------------------------------------------------------------------------
-- Drawing helpers
--------------------------------------------------------------------------------

local lib = boring.wl.lib
local scene = require("@boring/library/scene")

local function rect(tree, x, y, width, height, c)
    if width <= 0 or height <= 0 then return end
    local parsed = color.parse(c, { 0, 0, 0, 0 })
    local r = lib.wlr_scene_rect_create(tree, width, height, color.float4(parsed))
    r.node:set_position(x, y)
    return r
end

-- One antialiased quarter circle of radius r (corner 0..3: tl, tr, bl, br).
local function corner(tree, x, y, r, c, which)
    local buf = buffer.new(r, r)
    local px = buf.pixels
    local cc = color.parse(c, { 0, 0, 0, 0 })
    for j = 0, r - 1 do
        for i = 0, r - 1 do
            -- Distance from the circle centre, sampled at the pixel centre.
            local dx = (which == 0 or which == 2) and (r - i - 0.5) or (i + 0.5)
            local dy = (which == 0 or which == 1) and (r - j - 0.5) or (j + 0.5)
            local coverage = math.max(0, math.min(1, r - math.sqrt(dx * dx + dy * dy) + 0.5))
            if coverage > 0 then px[j * r + i] = buffer.argb(cc[1], cc[2], cc[3], (cc[4] or 1) * coverage) end
        end
    end
    buffer.attach(tree, buf).node:set_position(x, y)
end

-- A filled rectangle with rounded corners: three rects and four corners.
local function rounded(tree, x, y, width, height, radius, c)
    radius = math.floor(math.min(radius or 0, width / 2, height / 2))
    if radius <= 0 then return rect(tree, x, y, width, height, c) end
    rect(tree, x + radius, y, width - 2 * radius, height, c)
    rect(tree, x, y + radius, radius, height - 2 * radius, c)
    rect(tree, x + width - radius, y + radius, radius, height - 2 * radius, c)
    corner(tree, x, y, radius, c, 0)
    corner(tree, x + width - radius, y, radius, c, 1)
    corner(tree, x, y + height - radius, radius, c, 2)
    corner(tree, x + width - radius, y + height - radius, radius, c, 3)
end
ui.rounded = rounded

local icon_cache = {}

local function icon_pixels(path, size)
    local key = path .. "\0" .. size
    local cached = icon_cache[key]
    if cached == nil then
        local ok, width, height, pixels = pcall(image.icon, path, size)
        cached = ok and width and { width, height, pixels } or false
        icon_cache[key] = cached
    end
    return cached or nil
end

--------------------------------------------------------------------------------
-- Layout: measure, then draw
--------------------------------------------------------------------------------

local measure

local function text_font(w, theme)
    if w.font then return w.font end
    if w.style == "title" then return theme.title_font end
    if w.style == "muted" or w.style == "small" then return theme.small_font end
    return theme.font
end

local function text_color(w, theme)
    if w.color then return w.color end
    if w.style == "muted" or w.style == "small" then return theme.muted end
    return theme.foreground
end

local function list_rows(w)
    local first = w.offset or 1
    local last = math.min(#w.items, first + (w.max or #w.items) - 1)
    return first, last
end

-- Width and height of a widget given the width available.
measure = function(w, theme, available)
    local kind = w.kind
    if kind == "text" then
        if w.text == "" then return 0, 0 end
        local max = w.max_width or available
        -- Wrap where the first (top-down) measure decided: drawing measures
        -- again with the narrower box the text got, which would wrap more.
        if w._wrap == nil and w.wrap then w._wrap = math.min(w.wrap, max) end
        local width, height = text.measure(w.wrap and w.text or text.fit(w.text, text_font(w, theme), max),
            { font = text_font(w, theme), wrap = w._wrap })
        return width or 0, height or 0
    elseif kind == "image" then
        local size = w.size or theme.icon_size
        return size, size
    elseif kind == "spacer" then
        return w.width, w.height
    elseif kind == "box" then
        local pad = w.padding or 0
        local inner = (w.width or available) - pad * 2
        local cw, ch = 0, 0
        if w.child then cw, ch = measure(w.child, theme, inner) end
        local width = w.width or math.max(cw + pad * 2, w.min_width or 0)
        return math.min(width, available), w.height or ch + pad * 2
    elseif kind == "row" then
        local gap, width, height = w.gap or theme.gap, 0, 0
        for i, child in ipairs(w.children) do
            local cw, ch = measure(child, theme, available - width)
            width = width + cw + (i > 1 and gap or 0)
            height = math.max(height, ch)
        end
        return width, height
    elseif kind == "column" then
        local gap, width, height = w.gap or theme.gap, 0, 0
        for i, child in ipairs(w.children) do
            local cw, ch = measure(child, theme, available)
            width = math.max(width, cw)
            height = height + ch + (i > 1 and gap or 0)
        end
        return width, height
    elseif kind == "button" then
        local tw, th = text.measure(w.label, { font = theme.font })
        return (tw or 0) + theme.padding * 2, math.max(th or 0, 0) + theme.padding
    elseif kind == "input" then
        return w.width or available, theme.input_height
    elseif kind == "list" then
        local first, last = list_rows(w)
        return available, math.max(0, last - first + 1) * theme.row_height
    end
    return 0, 0
end
ui.measure = measure

local draw

-- Draw `w` at (x, y) in a box of width x height.
draw = function(w, ctx, x, y, width, height)
    local kind, theme, tree = w.kind, ctx.theme, ctx.tree
    if kind == "text" then
        local node = text.draw(tree, w.text, { font = text_font(w, theme), color = text_color(w, theme),
            max_width = w.max_width or width, wrap = w._wrap or (w.wrap and math.min(w.wrap, width)) or nil })
        if node then node:set_position(math.floor(x), math.floor(y)) end
    elseif kind == "image" then
        local size = w.size or theme.icon_size
        local px = w.path and icon_pixels(w.path, size)
        if px then
            local buf = buffer.new(px[1], px[2])
            ffi.copy(buf.pixels, px[3], #px[3])
            buffer.attach(tree, buf).node:set_position(math.floor(x + (size - px[1]) / 2),
                math.floor(y + (size - px[2]) / 2))
        end
    elseif kind == "box" then
        local bw = w.border and (w.border_width or theme.border_width) or 0
        local radius = w.radius or 0
        if bw > 0 then
            rounded(tree, x, y, width, height, radius, w.border)
            rounded(tree, x + bw, y + bw, width - 2 * bw, height - 2 * bw, math.max(0, radius - bw),
                w.background or theme.background)
        elseif w.background then
            rounded(tree, x, y, width, height, radius, w.background)
        end
        if w.on_click then ctx.targets[#ctx.targets + 1] = { x = x, y = y, width = width, height = height, fn = w.on_click } end
        if w.child then
            local pad = w.padding or 0
            local inner_w = width - pad * 2
            local _, ch = measure(w.child, theme, inner_w)
            draw(w.child, ctx, x + pad, y + pad, inner_w, math.max(ch, height - pad * 2))
        end
    elseif kind == "row" then
        local gap, cx = w.gap or theme.gap, x
        for _, child in ipairs(w.children) do
            local cw, ch = measure(child, theme, width - (cx - x))
            local cy = y
            if w.align == "center" then cy = y + (height - ch) / 2
            elseif w.align == "end" then cy = y + height - ch end
            draw(child, ctx, cx, math.floor(cy), cw, ch)
            cx = cx + cw + gap
        end
    elseif kind == "column" then
        local gap, cy = w.gap or theme.gap, y
        for _, child in ipairs(w.children) do
            local cw, ch = measure(child, theme, width)
            local cx, dw = x, cw
            if w.align == "stretch" then dw = width
            elseif w.align == "center" then cx = x + (width - cw) / 2
            elseif w.align == "end" then cx = x + width - cw end
            draw(child, ctx, math.floor(cx), cy, dw, ch)
            cy = cy + ch + gap
        end
    elseif kind == "spacer" then
        return
    elseif kind == "button" then
        rounded(tree, x, y, width, height, theme.radius / 2, w.selected and theme.selection or theme.surface)
        local tw, th = text.measure(w.label, { font = theme.font })
        local node = text.draw(tree, w.label, { font = theme.font,
            color = w.selected and theme.selection_foreground or theme.foreground })
        if node then node:set_position(math.floor(x + (width - (tw or 0)) / 2), math.floor(y + (height - (th or 0)) / 2)) end
        ctx.targets[#ctx.targets + 1] = { x = x, y = y, width = width, height = height, fn = w.on_click }
    elseif kind == "input" then
        local font = theme.input_font
        local value = w.value
        local shown = value ~= "" and value or (w.placeholder or "")
        local tw, th = text.measure(shown ~= "" and shown or " ", { font = font })
        th = th or 0
        local ty = math.floor(y + (height - th) / 2)
        local node = text.draw(tree, shown, { font = font, color = value ~= "" and theme.foreground or theme.muted,
            max_width = width })
        if node then node:set_position(math.floor(x), ty) end
        -- The caret.
        local cursor = w.cursor or #value
        local before = value:sub(1, cursor)
        local cw = before ~= "" and (text.measure(before, { font = font })) or 0
        rect(tree, math.floor(x + math.min(cw, width - 2)), ty, 2, th, theme.accent)
    elseif kind == "list" then
        local first, last = list_rows(w)
        local rh = theme.row_height
        for i = first, last do
            local ry = y + (i - first) * rh
            local selected = i == w.selected
            if selected then rounded(tree, x, ry, width, rh, theme.radius / 2, theme.selection) end
            local child = w.render(w.items[i], i, selected)
            if child then
                local _, ch = measure(child, theme, width - theme.padding * 2)
                draw(child, ctx, x + theme.padding, math.floor(ry + (rh - ch) / 2), width - theme.padding * 2, ch)
            end
            local item = w.items[i]
            if w.on_click then
                ctx.targets[#ctx.targets + 1] = { x = x, y = ry, width = width, height = rh,
                    fn = function() w.on_click(item, i) end }
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Views
--------------------------------------------------------------------------------

local function view_update(view)
    if view.closed then return end
    if view.tree then view.tree:destroy() end
    view.tree = scene.tree(view.parent or scene.layer(view.layer or "overlay"))
    local widget = view.render(view)
    local width, height = measure(widget, view.theme, view.max_width or 10000)
    view.width, view.height = width, height
    local x, y = 0, 0
    if view.place then x, y = view.place(width, height) end
    view.x, view.y = math.floor(x), math.floor(y)
    view.tree:set_position(view.x, view.y)
    local ctx = { theme = view.theme, tree = view.tree.raw, targets = {} }
    local ok, err = pcall(draw, widget, ctx, 0, 0, width, height)
    if not ok then error(err, 0) end
    view.targets = ctx.targets
    if view.opacity then view:set_opacity(view.opacity) end
end

local function view_contains(view, x, y)
    return not view.closed and x >= view.x and y >= view.y and x < view.x + view.width and y < view.y + view.height
end

--- Run the click handler under (x, y), if any. Returns true if there was one.
local function view_click(view, x, y, button)
    if not view_contains(view, x, y) then return false end
    local lx, ly = x - view.x, y - view.y
    for i = #view.targets, 1, -1 do
        local t = view.targets[i]
        if t.fn and lx >= t.x and ly >= t.y and lx < t.x + t.width and ly < t.y + t.height then
            t.fn(button)
            return true
        end
    end
    return false
end

-- Opacity of everything in the view.
local function set_opacity(view, alpha)
    view.opacity = alpha
    if view.tree then view.tree:set_opacity(alpha) end
end

local function view_close(view)
    if view.closed then return end
    view.closed = true
    if view.tree then view.tree:destroy() end
    view.tree = nil
    if view.on_close then view.on_close(view) end
end

--- A widget tree in the scene; see the top of this file.
function ui.view(opts)
    local view = {
        theme = opts.theme or ui.theme(),
        layer = opts.layer,
        parent = opts.parent,
        render = opts.render,
        place = opts.place,
        max_width = opts.max_width,
        on_close = opts.on_close,
        targets = {},
        x = 0, y = 0, width = 0, height = 0,
        update = view_update,
        contains = view_contains,
        click = view_click,
        close = view_close,
        set_opacity = set_opacity,
    }
    view_update(view)
    return view
end

return ui
