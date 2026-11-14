-- plugins/layout-master.lua
-- Master and stack: the master windows on the left, the others stacked on
-- the right.
--
--   local master = plugin("@boring/layout-master"):mount({
--       outputs = { "DP-1" },                          -- default: every output
--       ratio = 0.55,                                  -- master area width
--       masters = 1,                                   -- windows in the master area
--       gaps = { inner = 4, outer = 4, smart = true },
--   })
--   ["Mod4+Return"] = master.actions.zoom,      -- focused window becomes the master
--   ["Mod4+j"] = master.actions.focus_next,     -- and focus_previous
--   ["Mod4+Shift+j"] = master.actions.swap_next, -- and swap_previous
--   ["Mod4+l"] = master.actions.grow,           -- and shrink: the master area
--   ["Mod4+i"] = master.actions.more,           -- and fewer: windows in it
--
-- New windows become the master. Dragging a window onto another swaps them;
-- dragging resizes the master area. Floating windows (w.props.floating)
-- stay out of it.

local spaces = require("@boring/library/spaces")

local plugin = { name = "layout-master" }

local master = { ratio = 0.55, masters = 1, gaps = { inner = 4, outer = 4, smart = true } }

local function tiled(space)
    local list = {}
    for _, w in ipairs(space.data.order) do
        if not w.fullscreen then list[#list + 1] = w end
    end
    return list
end

local function place(w, x, y, width, height)
    w:set_tiled(true)
    local g = w:geometry()
    w:set_position(x - g.x, y - g.y)
    w:set_size(width, height)
    w:set_clip({ x = g.x, y = g.y, width = width, height = height })
    w.data.master_box = { x = x, y = y, width = width, height = height }
end

-- Split `count` windows from `list[first]` evenly down a column.
local function column(list, first, count, x, y, width, height, gap)
    if count <= 0 then return end
    local each = (height - gap * (count - 1)) / count
    for i = 0, count - 1 do
        local top = math.floor(y + i * (each + gap))
        local bottom = i == count - 1 and y + height or math.floor(y + i * (each + gap) + each)
        place(list[first + i], x, top, width, bottom - top)
    end
end

local function arrange(space)
    local list = tiled(space)
    local n = #list
    if n == 0 then return end
    local area, gaps = space.output.usable, master.gaps
    local inner, outer = gaps.inner or 4, gaps.outer or 4
    if gaps.smart and n == 1 then inner, outer = 0, 0 end
    local x, y = area.x + outer, area.y + outer
    local width, height = area.width - outer * 2, area.height - outer * 2
    local masters = math.min(space.data.masters, n)
    if masters == 0 or masters == n then
        column(list, 1, n, x, y, width, height, inner)
    else
        local left = math.floor((width - inner) * space.data.ratio)
        column(list, 1, masters, x, y, left, height, inner)
        column(list, masters + 1, n - masters, x + left + inner, y, width - left - inner, height, inner)
    end
end

local function index_of(list, w)
    for i, x in ipairs(list) do
        if x == w then return i end
    end
end

function master:init(space)
    space.data.order = {}
    space.data.ratio = self.ratio
    space.data.masters = self.masters
end

function master:shutdown(space)
    for _, w in ipairs(space.windows) do
        w:set_clip(nil)
        w:set_tiled(false)
    end
end

function master:add(space, w)
    if w.props.floating then
        w:raise()
        return
    end
    table.insert(space.data.order, 1, w)
    arrange(space)
end

function master:remove(space, w)
    w:set_clip(nil)
    w:set_tiled(false)
    local i = index_of(space.data.order, w)
    if not i then return end
    table.remove(space.data.order, i)
    arrange(space)
end

function master:arrange(space) arrange(space) end

function master:commit(_, w)
    local b = w.data.master_box
    if not b or w.fullscreen then return end
    local g = w:geometry()
    w:set_position(b.x - g.x, b.y - g.y)
end

-- The tiled window under a point.
local function window_at(space, x, y)
    for _, w in ipairs(tiled(space)) do
        local b = w.data.master_box
        if b and x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height then return w end
    end
end

function master:move(space, w)
    if not index_of(space.data.order, w) then return boring.begin_move(w) end
    boring.grab_pointer({
        window = w,
        cursor = "grabbing",
        finish = function(cancelled)
            if cancelled then return end
            local order = space.data.order
            local target = window_at(space, boring.cursor())
            local i, j = index_of(order, w), target and index_of(order, target)
            if i and j and i ~= j then
                order[i], order[j] = order[j], order[i]
                arrange(space)
            end
        end,
    })
end

-- Dragging anywhere moves the boundary between the areas.
function master:resize(space, w, edges)
    if not index_of(space.data.order, w) then return boring.begin_resize(w, edges) end
    local area = space.output.usable
    boring.grab_pointer({
        window = w,
        cursor = "ew-resize",
        motion = function(x)
            local ratio = (x - area.x) / math.max(1, area.width)
            space.data.ratio = math.max(0.1, math.min(0.9, ratio))
            arrange(space)
        end,
    })
end

--------------------------------------------------------------------------------
-- Commands on the focused window's space
--------------------------------------------------------------------------------

local function focused_space()
    local w = boring.focused()
    local space = w and spaces.of(w)
    if space and space.impl == master then return space, w end
end

local commands = {}

function commands.zoom()
    local space, w = focused_space()
    if not space then return end
    local order = space.data.order
    local i = index_of(order, w)
    if not i then return end
    -- The master itself swaps with the next window.
    local j = i == 1 and 2 or 1
    if not order[j] then return end
    order[i], order[j] = order[j], order[i]
    arrange(space)
    boring.focus(order[1])
end

local function step(delta, swap)
    local space, w = focused_space()
    if not space then return end
    local order = space.data.order
    local i = index_of(order, w)
    if not i or #order < 2 then return end
    local j = (i - 1 + delta) % #order + 1
    if swap then
        order[i], order[j] = order[j], order[i]
        arrange(space)
    else
        boring.focus(order[j])
    end
end

function commands.focus_next() step(1) end
function commands.focus_previous() step(-1) end
function commands.swap_next() step(1, true) end
function commands.swap_previous() step(-1, true) end

local function adjust(field, delta, min, max)
    local space = focused_space()
    if not space then return end
    space.data[field] = math.max(min, math.min(max, space.data[field] + delta))
    arrange(space)
end

function commands.grow() adjust("ratio", 0.05, 0.1, 0.9) end
function commands.shrink() adjust("ratio", -0.05, 0.1, 0.9) end
function commands.more() adjust("masters", 1, 0, 32) end
function commands.fewer() adjust("masters", -1, 0, 32) end

plugin._private = { layout = master, arrange = arrange }

function plugin:mount(config, ctx)
    master.ratio = config.ratio or 0.55
    master.masters = config.masters or 1
    master.gaps = config.gaps or { inner = 4, outer = 4, smart = true }
    ctx.scope:defer(spaces.register("master", master, { outputs = config.outputs }))
    return { layout = master, actions = commands }
end

return plugin
