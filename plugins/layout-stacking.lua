-- plugins/layout-stacking.lua
-- Floating windows with optional server-side title bars.
--
--   local stacking = plugin("@boring/layout-stacking"):mount({
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
--           { type = "button", icon = "minimize" },
--           { type = "button", icon = "maximize" },
--           { type = "button", icon = "close" },
--           -- or your own: { type = "button", icon = "★", on_click = function(w) ... end },
--       },
--   })
--   ["Mod4+m"] = stacking.actions.maximize,   -- toggle, focused window
--   ["Mod4+n"] = stacking.actions.minimize,
--
-- Without `controls` (or with `decorations = false`) windows get no title
-- bar. New windows open centred; dragging the title bar moves a window and
-- double-clicking it maximizes. Maximized windows fill the usable area.

local color = require("shared.color")
local spaces = require("@boring/library/spaces")
local text = require("@boring/library/text")

local plugin = { name = "layout-stacking" }

local ICONS = { close = "×", maximize = "□", minimize = "–" }
local BUTTON_LEFT = 0x110

local function make_stacking(config)
    local theme = config.theme or {}
    local controls = config.controls
    local decorated = controls ~= nil and config.decorations ~= false
    local height = theme.height or 24
    local font = theme.font or "Sans Bold 10"
    local bar_color = color.parse(theme.decorations, { 0.2, 0.2, 0.2, 1 })
    local title_color = color.parse(theme.title, { 1, 1, 1, 1 })
    local button_bg = color.parse(theme.button_background, bar_color)
    local button_fg = color.parse(theme.button_foreground, title_color)
    local lib = boring.wl.lib

    local stacking = {}

    local function managed(w)
        local space = spaces.of(w)
        return space ~= nil and space.impl == stacking
    end

    -- Maximize --------------------------------------------------------------

    function stacking.maximize(w, on)
        if not managed(w) or w.fullscreen or w.maximized == (on and true or false) then return end
        local d = w.data
        if on then
            local x, y = w:position()
            local width, h = w:size()
            d.stacking_restore = { x = x, y = y, width = width, height = h }
            local area, g = spaces.of(w).output.usable, w:geometry()
            local top = decorated and height or 0
            w:set_maximized(true)
            w:set_position(area.x - g.x, area.y + top - g.y)
            w:set_size(area.width, area.height - top)
        else
            local r = d.stacking_restore
            d.stacking_restore = nil
            w:set_maximized(false)
            if r then
                w:set_position(r.x, r.y)
                w:set_size(r.width, r.height)
            end
        end
    end

    local DEFAULT_CLICK = {
        close = function(w) w:close() end,
        maximize = function(w) stacking.maximize(w, not w.maximized) end,
        minimize = function(w) spaces.minimize(w, true) end,
    }

    -- Title bars ------------------------------------------------------------

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

        local bar = lib.wlr_scene_rect_create(tree, g.width, height, color.float4(bar_color))
        local last_click = 0
        d.handlers[#d.handlers + 1] = boring.on_click(bar.node, function(win, button)
            if button ~= BUTTON_LEFT then return end
            local now = boring.now()
            if now - last_click < 300 then
                last_click = 0
                stacking.maximize(win, not win.maximized)
                return
            end
            last_click = now
            if not win.maximized then boring.begin_move(win) end
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
                local node, _, th = text.draw(tree, d.title, {
                    font = font, color = title_color, max_width = math.max(0, g.width - fixed - 16),
                })
                if node then node.node:set_position(x + 8, math.floor((height - th) / 2)) end
            elseif c.type == "spacer" then
                x = x + math.max(0, (g.width - fixed) / math.max(spacers, 1))
            elseif c.type == "button" then
                local bx = math.floor(x)
                local rect = lib.wlr_scene_rect_create(tree, height, height, color.float4(button_bg))
                rect.node:set_position(bx, 0)
                local node, iw, ih = text.draw(tree, ICONS[c.icon] or c.icon or "", { font = font, color = button_fg })
                if node then
                    node.node:set_position(math.floor(bx + (height - iw) / 2), math.floor((height - ih) / 2))
                end
                local on_click = c.on_click or DEFAULT_CLICK[c.icon]
                d.handlers[#d.handlers + 1] = boring.on_click(rect.node, function(win)
                    if on_click then on_click(win) end
                end)
                x = x + height
            end
        end
    end

    function stacking.update_decorations(w)
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

    --- X11 windows asking for a place and size get it.
    function stacking.request_geometry(w, box)
        if not managed(w) or w.fullscreen or w.maximized then return end
        w:set_position(box.x, box.y)
        w:set_size(box.width, box.height)
    end

    -- Arrangement -----------------------------------------------------------

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

    -- Maximized windows follow the usable area (a panel appeared).
    function stacking:arrange(space)
        for _, w in ipairs(spaces.arranged(space)) do
            if w.maximized then
                local area, g = space.output.usable, w:geometry()
                local top = decorated and height or 0
                w:set_position(area.x - g.x, area.y + top - g.y)
                w:set_size(area.width, area.height - top)
            end
        end
    end

    function stacking:shutdown(space)
        for _, w in ipairs(space.windows) do
            destroy_decorations(w)
            if w.maximized then stacking.maximize(w, false) end
        end
    end

    -- No move/resize here: windows follow the pointer (spaces' default),
    -- except maximized ones, which stay put.
    function stacking:move(_, w)
        if not w.maximized then boring.begin_move(w) end
    end
    function stacking:resize(_, w, edges)
        if not w.maximized then boring.begin_resize(w, edges) end
    end

    return stacking
end

function plugin:mount(config, ctx)
    local stacking = make_stacking(config)
    local scope = ctx.scope
    scope:subscribe(boring.events, "window:commit", stacking.update_decorations)
    scope:subscribe(boring.events, "window:title", stacking.update_decorations)
    scope:subscribe(boring.events, "window:fullscreen", stacking.update_decorations)
    scope:subscribe(boring.events, "window:request_geometry", stacking.request_geometry)
    scope:subscribe(boring.events, "window:request_maximize", stacking.maximize)
    scope:defer(spaces.register("stacking", stacking, { outputs = config.outputs }))

    local function focused(fn)
        return function()
            local w = boring.focused()
            if w then fn(w) end
        end
    end
    return {
        layout = stacking,
        actions = {
            maximize = focused(function(w) stacking.maximize(w, not w.maximized) end),
            minimize = focused(function(w) spaces.minimize(w, true) end),
        },
    }
end

return plugin
