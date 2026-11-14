-- plugins/layout-tiling.lua
-- Sway-style N-ary tiling: windows live in a tree of horizontal/vertical
-- splits with resizable fractions.
--
--   local tiling = plugin("@boring/layout-tiling"):mount({
--       outputs = { "DP-1" },                         -- default: every output
--       gaps = { inner = 4, outer = 4, smart = true }, -- smart: none for one window
--   })
--   ["Mod4+h"] = tiling.actions.focus("left"),        -- left, right, up, down
--   ["Mod4+Shift+h"] = tiling.actions.move("left"),   -- swap with the neighbour
--   ["Mod4+Ctrl+h"] = tiling.actions.resize("left", 40),  -- grow towards a side
--   ["Mod4+b"] = tiling.actions.split_horizontal,     -- next window goes beside
--   ["Mod4+v"] = tiling.actions.split_vertical,       -- next window goes below
--
-- New windows go next to the focused one, in its split. Dragging a window
-- onto another swaps them; dragging an edge resizes the split.

local bit = require("bit")
local C = require("ffi").C
local spaces = require("@boring/library/spaces")

local LEFT, RIGHT, TOP, BOTTOM = C.WLR_EDGE_LEFT, C.WLR_EDGE_RIGHT, C.WLR_EDGE_TOP, C.WLR_EDGE_BOTTOM
local HORIZONTAL_EDGES = bit.bor(LEFT, RIGHT)
local VERTICAL_EDGES = bit.bor(TOP, BOTTOM)
local MIN_SIZE = 50

local tiling = { gaps = { inner = 4, outer = 4, smart = true } }

--------------------------------------------------------------------------------
-- The tree
--
-- A space's tree is { layout = "horizontal"|"vertical", children = {...} }.
-- Children are leaves { type = "leaf", window } or splits { type = "split",
-- layout, children }. Each has a parent (nil at the top), its share of its
-- parent (width_fraction/height_fraction, 0 for "not assigned yet") and the
-- box it got at the last arrange (x, y, width, height).
--------------------------------------------------------------------------------

local function node(fields)
    fields.width_fraction, fields.height_fraction = 0, 0
    fields.x, fields.y, fields.width, fields.height = 0, 0, 0, 0
    return fields
end

local function leaf(w) return node({ type = "leaf", window = w }) end

local function split(layout, children)
    local s = node({ type = "split", layout = layout, children = children or {} })
    for _, child in ipairs(s.children) do child.parent = s end
    return s
end

local function index_of(list, item)
    for i, v in ipairs(list) do
        if v == item then return i end
    end
end

-- The list a container lives in: its parent's children, or the top level.
local function siblings_of(tree, c)
    return c.parent and c.parent.children or tree.children
end

local function layout_of(tree, c)
    return c.parent and c.parent.layout or tree.layout
end

local function each_leaf(list, fn)
    for _, c in ipairs(list) do
        if c.type == "leaf" then fn(c) else each_leaf(c.children, fn) end
    end
end

local function find(list, w)
    for _, c in ipairs(list) do
        if c.type == "leaf" then
            if c.window == w then return c end
        else
            local found = find(c.children, w)
            if found then return found end
        end
    end
end

local function count(list)
    local n = 0
    each_leaf(list, function() n = n + 1 end)
    return n
end

local function contains(list, target)
    for _, c in ipairs(list) do
        if c == target or (c.type == "split" and contains(c.children, target)) then return true end
    end
    return false
end

local function leaf_at(list, x, y)
    for _, c in ipairs(list) do
        if x >= c.x and x < c.x + c.width and y >= c.y and y < c.y + c.height then
            if c.type == "leaf" then return c end
            return leaf_at(c.children, x, y)
        end
    end
end

--- Add a window next to `focused` (in the active split, if there's one).
local function add(tree, w, focused)
    local new = leaf(w)
    local at = focused and find(tree.children, focused)
    if not at then
        table.insert(tree.children, new)
        return new
    end
    local active = tree.active_split
    if active and contains(tree.children, active) then
        local i = index_of(active.children, at)
        table.insert(active.children, i and i + 1 or #active.children + 1, new)
        new.parent = active
        return new
    end
    tree.active_split = nil
    local list = siblings_of(tree, at)
    table.insert(list, index_of(list, at) + 1, new)
    new.parent = at.parent
    return new
end

--- Remove a window, collapsing splits left with one child.
local function remove(tree, w)
    local c = find(tree.children, w)
    if not c then return end
    local list = siblings_of(tree, c)
    table.remove(list, index_of(list, c))
    local parent = c.parent
    while parent and #parent.children <= 1 do
        local outer = siblings_of(tree, parent)
        local i = index_of(outer, parent)
        local only = parent.children[1]
        if only then
            only.width_fraction, only.height_fraction = parent.width_fraction, parent.height_fraction
            only.parent = parent.parent
            outer[i] = only
        else
            table.remove(outer, i)
        end
        if tree.active_split == parent then tree.active_split = nil end
        parent = parent.parent
    end
end

--- Make new windows open beside (horizontal) or below (vertical) `w`: wrap
--- it in a split of that direction, unless it's in one already.
local function split_at(tree, w, layout)
    local c = w and find(tree.children, w)
    if not c then
        tree.layout, tree.active_split = layout, nil
        return
    end
    if c.parent and c.parent.layout == layout then
        tree.active_split = c.parent
        return
    end
    local s = split(layout, {})
    for _, k in ipairs({ "width_fraction", "height_fraction", "x", "y", "width", "height" }) do s[k] = c[k] end
    local list = siblings_of(tree, c)
    list[index_of(list, c)] = s
    s.parent = c.parent
    c.parent = s
    c.width_fraction, c.height_fraction = 1, 1
    s.children[1] = c
    tree.active_split = s
end

--------------------------------------------------------------------------------
-- Arranging (Sway's arrange.c)
--------------------------------------------------------------------------------

local arrange_children

-- Lay children out along one axis of `box`: proportional to their fractions,
-- new children getting the average share.
local function lay_out(children, box, gap, horizontal)
    local n = #children
    if n == 0 then return end
    local frac = horizontal and "width_fraction" or "height_fraction"
    local total, fresh = 0, 0
    for _, c in ipairs(children) do
        total = total + c[frac]
        if c[frac] <= 0 then fresh = fresh + 1 end
    end
    for _, c in ipairs(children) do
        if c[frac] <= 0 then
            c[frac] = total <= 0 and 1 or (n > fresh and total / (n - fresh) or total)
        end
    end
    total = 0
    for _, c in ipairs(children) do total = total + c[frac] end

    local available = (horizontal and box.width or box.height) - gap * (n - 1)
    local pos = horizontal and box.x or box.y
    for i, c in ipairs(children) do
        local size = math.floor(c[frac] / total * available)
        if horizontal then
            c.x, c.y, c.height = math.floor(pos), box.y, box.height
            c.width = i == n and box.x + box.width - c.x or size
            pos = pos + c.width + gap
        else
            c.x, c.y, c.width = box.x, math.floor(pos), box.width
            c.height = i == n and box.y + box.height - c.y or size
            pos = pos + c.height + gap
        end
        arrange_children(c, gap)
    end
end

-- Place a leaf's window in its box, or recurse into a split.
arrange_children = function(c, gap)
    if c.type == "split" then
        lay_out(c.children, c, gap, c.layout == "horizontal")
        return
    end
    local w = c.window
    if w.fullscreen or not w.geometry then return end
    local g = w:geometry()
    w:set_position(c.x - g.x, c.y - g.y)
    w:set_size(c.width, c.height)
    -- Clip until the client catches up with the new size, so it never
    -- draws over its neighbours.
    w:set_clip({ x = g.x, y = g.y, width = c.width, height = c.height })
end

local function arrange(space)
    local tree = space.data.tree
    if not tree then return end
    local area = space.output.usable
    local gaps = tiling.gaps
    local inner, outer = gaps.inner or 4, gaps.outer or 4
    if gaps.smart and count(tree.children) == 1 then inner, outer = 0, 0 end
    local box = {
        x = area.x + outer, y = area.y + outer,
        width = area.width - outer * 2, height = area.height - outer * 2,
    }
    lay_out(tree.children, box, inner, tree.layout == "horizontal")
end

--------------------------------------------------------------------------------
-- Resizing (Sway's resize.c)
--------------------------------------------------------------------------------

-- The container to resize for `edge` (one of LEFT/RIGHT/TOP/BOTTOM): the
-- nearest ancestor-or-self in a split along that axis with a sibling on
-- that side. Returns it and its sibling list.
local function resize_target(tree, c, edge)
    local layout = bit.band(edge, HORIZONTAL_EDGES) ~= 0 and "horizontal" or "vertical"
    local before = bit.band(edge, bit.bor(LEFT, TOP)) ~= 0
    while c do
        local list = siblings_of(tree, c)
        if layout_of(tree, c) == layout and #list > 1 then
            local i = index_of(list, c)
            if (before and i > 1) or (not before and i < #list) then return c, list end
        end
        c = c.parent
    end
end

-- Grow `c` by `amount` pixels towards `edge`, taking it from the sibling
-- on that side.
local function resize_by(c, list, edge, amount)
    if amount == 0 then return false end
    local horizontal = bit.band(edge, HORIZONTAL_EDGES) ~= 0
    local i = index_of(list, c)
    local sibling = list[bit.band(edge, bit.bor(LEFT, TOP)) ~= 0 and i - 1 or i + 1]
    if not sibling then return false end
    local dim = horizontal and "width" or "height"
    local frac = dim .. "_fraction"
    if c[dim] + amount < MIN_SIZE or sibling[dim] - amount < MIN_SIZE then return false end
    local total = 0
    for _, x in ipairs(list) do total = total + x[dim] end
    if total <= 0 then return false end
    for _, x in ipairs(list) do x[frac] = x[dim] / total end
    c[frac] = (c[dim] + amount) / total
    sibling[frac] = (sibling[dim] - amount) / total
    return true
end

--------------------------------------------------------------------------------
-- Neighbours, for keyboard commands
--------------------------------------------------------------------------------

local DIRECTIONS = {
    left = { edge = LEFT, dx = -1, dy = 0 },
    right = { edge = RIGHT, dx = 1, dy = 0 },
    up = { edge = TOP, dx = 0, dy = -1 },
    down = { edge = BOTTOM, dx = 0, dy = 1 },
}

-- The leaf nearest to `c` in a direction: past c's edge on that side,
-- overlapping it on the other axis, closest first.
local function neighbour(tree, c, direction)
    local d = DIRECTIONS[direction]
    local best, best_distance = nil, math.huge
    each_leaf(tree.children, function(o)
        if o == c or o.window.fullscreen then return end
        local distance, overlap
        if d.dx ~= 0 then
            distance = d.dx < 0 and c.x - (o.x + o.width) or o.x - (c.x + c.width)
            overlap = math.min(c.y + c.height, o.y + o.height) - math.max(c.y, o.y)
        else
            distance = d.dy < 0 and c.y - (o.y + o.height) or o.y - (c.y + c.height)
            overlap = math.min(c.x + c.width, o.x + o.width) - math.max(c.x, o.x)
        end
        if distance >= 0 and overlap > 0 and distance < best_distance then
            best, best_distance = o, distance
        end
    end)
    return best
end

--------------------------------------------------------------------------------
-- The arrangement (see library/spaces)
--------------------------------------------------------------------------------

-- A tree saved by shutdown (plugin remount), minus windows that went away.
local function restore(saved, space)
    local present = {}
    for _, w in ipairs(spaces.arranged(space)) do present[w] = true end
    local gone = {}
    each_leaf(saved.children, function(c)
        if not present[c.window] then gone[#gone + 1] = c.window end
    end)
    for _, w in ipairs(gone) do remove(saved, w) end
    return saved
end

function tiling:init(space)
    local saved = self.saved and self.saved[space]
    if saved then
        self.saved[space] = nil
        space.data.tree = restore(saved, space)
    else
        space.data.tree = { layout = "horizontal", children = {} }
    end
end

function tiling:shutdown(space)
    local tree = space.data.tree
    space.data.tree = nil
    for _, w in ipairs(space.windows) do w:set_clip(nil) end
    if not (self.saved and tree) then return end
    -- Keep this tree; drop those of spaces that are gone.
    local live = {}
    for _, o in ipairs(boring.outputs()) do
        for _, other in ipairs(spaces.list(o)) do live[other] = true end
    end
    for other in pairs(self.saved) do
        if not live[other] then self.saved[other] = nil end
    end
    self.saved[space] = tree
end

function tiling:add(space, w)
    local tree = space.data.tree
    if not find(tree.children, w) then -- not already in a restored tree
        local focused = boring.focused()
        if focused and spaces.of(focused) ~= space then focused = nil end
        add(tree, w, focused)
    end
    arrange(space)
end

function tiling:remove(space, w)
    w:set_clip(nil)
    remove(space.data.tree, w)
    arrange(space)
end

function tiling:arrange(space) arrange(space) end

-- After a commit, keep the window where its tile is (its geometry offset
-- may have changed).
function tiling:commit(space, w)
    local c = find(space.data.tree.children, w)
    if not c then return end
    local g = w:geometry()
    w:set_position(c.x - g.x, c.y - g.y)
end

-- Dragging a window onto another swaps them.
function tiling:move(space, w)
    boring.grab_pointer({
        window = w,
        cursor = "grabbing",
        finish = function(cancelled)
            local tree = space.data.tree
            if cancelled or not tree then return end
            local grabbed, target = find(tree.children, w), leaf_at(tree.children, boring.cursor())
            if grabbed and target and grabbed ~= target then
                grabbed.window, target.window = target.window, grabbed.window
                arrange(space)
            end
        end,
    })
end

-- Dragging an edge moves the split boundary on that side (both axes for a
-- corner); with no edge given, the quadrant under the cursor decides.
function tiling:resize(space, w, edges)
    local tree = space.data.tree
    local c = find(tree.children, w)
    if not c then return end
    local cx, cy = boring.cursor()
    if edges == 0 then
        edges = bit.bor(cx > c.x + c.width / 2 and RIGHT or LEFT, cy > c.y + c.height / 2 and BOTTOM or TOP)
    end
    local axes = {}
    for _, mask in ipairs({ HORIZONTAL_EDGES, VERTICAL_EDGES }) do
        local edge = bit.band(edges, mask)
        if edge ~= 0 then
            local target, list = resize_target(tree, c, edge)
            if target then axes[#axes + 1] = { edge = edge, target = target, list = list } end
        end
    end
    if #axes == 0 then return end

    local ref_x, ref_y = cx, cy
    boring.grab_pointer({
        window = w,
        cursor = boring.resize_cursor(edges),
        motion = function(x, y)
            if not space.data.tree then return end
            local changed = false
            for _, a in ipairs(axes) do
                local horizontal = bit.band(a.edge, HORIZONTAL_EDGES) ~= 0
                local delta = horizontal and x - ref_x or y - ref_y
                local sign = bit.band(a.edge, bit.bor(LEFT, TOP)) ~= 0 and -1 or 1
                local amount = math.floor(delta * sign + 0.5)
                if amount ~= 0 and resize_by(a.target, a.list, a.edge, amount) then
                    -- Only what was applied moves the reference point.
                    if horizontal then ref_x = ref_x + amount * sign else ref_y = ref_y + amount * sign end
                    changed = true
                end
            end
            if changed then arrange(space) end
        end,
    })
end

--------------------------------------------------------------------------------
-- Commands on the focused window
--------------------------------------------------------------------------------

-- The focused window, its space and its leaf, if tiling manages it.
local function focused_leaf()
    local w = boring.focused()
    local space = w and spaces.of(w)
    if not space or space.impl ~= tiling or not space.data.tree then return end
    local c = find(space.data.tree.children, w)
    if c then return w, space, c end
end

local commands = {}

function commands.split(direction)
    local w, space = focused_leaf()
    if not w then return end
    split_at(space.data.tree, w, direction)
    arrange(space)
end

function commands.focus(direction)
    local _, space, c = focused_leaf()
    if not c then return end
    local n = neighbour(space.data.tree, c, direction)
    if n then boring.focus(n.window) end
end

function commands.move(direction)
    local _, space, c = focused_leaf()
    if not c then return end
    local n = neighbour(space.data.tree, c, direction)
    if not n then return end
    c.window, n.window = n.window, c.window
    arrange(space)
end

function commands.resize(direction, amount)
    local _, space, c = focused_leaf()
    if not c then return end
    local edge = DIRECTIONS[direction].edge
    local target, list = resize_target(space.data.tree, c, edge)
    if target and resize_by(target, list, edge, amount or 40) then arrange(space) end
end

--------------------------------------------------------------------------------
-- Plugin
--------------------------------------------------------------------------------

local plugin = { name = "layout-tiling" }

plugin._private = {
    layout = tiling,
    add = add,
    remove = remove,
    split_at = split_at,
    find = find,
    leaf_at = leaf_at,
    neighbour = neighbour,
    lay_out = lay_out,
    resize_target = resize_target,
    resize_by = resize_by,
}

function plugin:mount(config, ctx)
    tiling.gaps = config.gaps or { inner = 4, outer = 4, smart = true }
    -- Trees are kept per space across remounts (config reloads).
    ctx.state.trees = ctx.state.trees or {}
    tiling.saved = ctx.state.trees
    local unregister = spaces.register("tiling", tiling, { outputs = config.outputs })
    ctx.scope:defer(function()
        unregister()
        tiling.saved = nil
    end)

    return {
        layout = tiling,
        actions = {
            split_horizontal = function() commands.split("horizontal") end,
            split_vertical = function() commands.split("vertical") end,
            focus = function(direction) return function() commands.focus(direction) end end,
            move = function(direction) return function() commands.move(direction) end end,
            resize = function(direction, amount) return function() commands.resize(direction, amount) end end,
        },
    }
end

return plugin
