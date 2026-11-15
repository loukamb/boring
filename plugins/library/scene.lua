-- plugins/library/scene.lua
-- The scene graph, as Lua objects: trees, solid rects and images.
--
--   local scene = require("@boring/library/scene")
--   local tree = scene.tree(scene.window(w))          -- under a window
--   local bar = scene.rect(tree, 200, 24, "#333333")  -- any shared.color value
--   bar:set_position(0, -24)
--   local pic = scene.image(scene.layer("overlay"), canvas)  -- a library/pixels canvas
--   pic:set_size(400, 300)                            -- shown at this size
--   local off = scene.on_click(bar, function(w, button) ... end)
--
-- Layers, bottom to top: background, bottom, windows, top, unmanaged,
-- overlay, lock.
--
-- Every node: kind ("tree", "rect" or "image"), set_position(x, y),
-- position(), set_enabled(on), enabled(), raise_to_top(), place_above(n),
-- place_below(n), parent(), destroy(). Rects: set_color(c), set_size(w, h),
-- size(). Images: set_size(w, h), size(), set_canvas(canvas). All of them:
-- set_opacity(a) (trees: everything under them). Trees: children(), and
-- snapshot(parent), a still copy of what's under it (the copy stays on
-- screen after the original is gone, e.g. to animate a window closing).
--
-- The same scene node is always the same object. `node.raw` is the
-- underlying object, for other libraries.

local ffi = require("ffi")
local color = require("shared.color")
local buffer = require("shared.wl.buffer")

local wl = boring.wl
local lib, C = wl.lib, wl.C

local scene = {}

local Node = {}
Node.__index = Node

local cache = setmetatable({}, { __mode = "v" }) -- node address -> wrapper

local tree_t = ffi.typeof("struct wlr_scene_tree *")
local rect_t = ffi.typeof("struct wlr_scene_rect *")
local buffer_t = ffi.typeof("struct wlr_scene_buffer *")
local node_t = ffi.typeof("struct wlr_scene_node *")

-- A wrapper for a typed scene object (tree, rect or buffer).
local function make(kind, raw)
    local key = wl.addr(raw.node)
    local n = cache[key]
    -- Addresses are reused once nodes are freed: only trust a match in kind.
    if n and n.kind == kind and not n.destroyed then return n end
    n = setmetatable({ kind = kind, raw = raw, _node = raw.node, _alpha = 1 }, Node)
    cache[key] = n
    return n
end

--- The scene object for a raw scene tree, rect, buffer or node (or a node
--- already wrapped). Nil for NULL.
function scene.wrap(raw)
    if raw == nil then return nil end
    if getmetatable(raw) == Node then return raw end
    if ffi.istype(tree_t, raw) then return make("tree", raw) end
    if ffi.istype(rect_t, raw) then return make("rect", raw) end
    if ffi.istype(buffer_t, raw) then return make("image", raw) end
    if ffi.istype(node_t, raw) then
        if raw.type == C.WLR_SCENE_NODE_TREE then return make("tree", lib.wlr_scene_tree_from_node(raw)) end
        if raw.type == C.WLR_SCENE_NODE_RECT then return make("rect", lib.wlr_scene_rect_from_node(raw)) end
        if raw.type == C.WLR_SCENE_NODE_BUFFER then return make("image", lib.wlr_scene_buffer_from_node(raw)) end
    end
    error("scene.wrap: not a scene object", 2)
end

--- The raw scene tree of a tree (wrapped or not).
function scene.raw(n)
    if getmetatable(n) == Node then return n.raw end
    return n
end

local function parent_tree(parent)
    local raw = scene.raw(parent)
    assert(raw ~= nil, "scene: no parent")
    return raw
end

--- A window's scene tree (it moves with the window).
function scene.window(w) return make("tree", w.tree) end

--- One of the compositor's layers.
function scene.layer(name)
    local tree = boring.layers[name]
    assert(tree, "scene.layer: no layer " .. tostring(name))
    return make("tree", tree)
end

--- An empty tree under `parent`.
function scene.tree(parent)
    return make("tree", lib.wlr_scene_tree_create(parent_tree(parent)))
end

--- A solid rectangle.
function scene.rect(parent, width, height, c)
    local n = make("rect", lib.wlr_scene_rect_create(parent_tree(parent), math.max(0, width), math.max(0, height),
        color.float4({ 0, 0, 0, 0 })))
    n:set_color(c)
    return n
end

-- A wlr_buffer holding a copy of the canvas's pixels (data: uint32_t[] or
-- a string of width * height * 4 bytes, premultiplied ARGB).
local function buffer_of(canvas)
    local buf = buffer.new(canvas.width, canvas.height)
    ffi.copy(buf.pixels, canvas.data, canvas.width * canvas.height * 4)
    return buf
end

--- An image showing (a copy of) a canvas, at its own size until set_size.
function scene.image(parent, canvas)
    return make("image", buffer.attach(parent_tree(parent), buffer_of(canvas)))
end

--- fn(window, button) when the node (or anything under it) is clicked.
--- Returns a function that removes the handler.
function scene.on_click(n, fn)
    return boring.on_click(scene.wrap(n)._node, fn)
end

-- Every node -------------------------------------------------------------------

function Node:set_position(x, y) self._node:set_position(math.floor(x), math.floor(y)) end
function Node:position() return self._node.x, self._node.y end
function Node:set_enabled(on) self._node:set_enabled(on and true or false) end
function Node:enabled() return self._node.enabled end
function Node:raise_to_top() self._node:raise_to_top() end
function Node:lower_to_bottom() self._node:lower_to_bottom() end
function Node:place_above(other) self._node:place_above(scene.wrap(other)._node) end
function Node:place_below(other) self._node:place_below(scene.wrap(other)._node) end

function Node:parent()
    local p = self._node.parent
    if p == nil then return nil end
    return make("tree", p)
end

--- Destroy the node and everything under it.
function Node:destroy()
    if self.destroyed then return end
    -- Forget the wrappers below too: their addresses can be reused.
    local function forget(n)
        if n.kind == "tree" then
            for child in n:children() do forget(child) end
        end
        n.destroyed = true
        cache[wl.addr(n._node)] = nil
    end
    local node = self._node
    forget(self)
    node:destroy()
end

-- Rects --------------------------------------------------------------------------

-- Rects keep their colour (straight alpha) and opacity; wlroots takes the
-- product, premultiplied.
local function paint(n)
    local c, a = n._color, n._alpha * (n._color[4] or 1)
    n._scratch = n._scratch or color.float4({ 0, 0, 0, 0 })
    local k = n._scratch
    k[0], k[1], k[2], k[3] = c[1] * a, c[2] * a, c[3] * a, a
    n.raw:set_color(k)
end

-- A premultiplied float[4] back to { r, g, b, a }.
local function straight(k)
    local a = k[3]
    if a <= 0 then return { 0, 0, 0, 0 } end
    return { k[0] / a, k[1] / a, k[2] / a, a }
end

function Node:set_color(c)
    assert(self.kind == "rect", "set_color: not a rect")
    self._color = color.parse(c, { 0, 0, 0, 0 })
    paint(self)
end

--- The rect's colour, { r, g, b, a }.
function Node:color()
    if not self._color then
        self._color = straight(self.raw.color)
    end
    return self._color
end

function Node:set_size(width, height)
    width, height = math.max(0, math.floor(width)), math.max(0, math.floor(height))
    if self.kind == "rect" then
        self.raw:set_size(width, height)
    elseif self.kind == "image" then
        lib.wlr_scene_buffer_set_dest_size(self.raw, width, height)
    else
        error("set_size: not a rect or image", 2)
    end
end

function Node:size()
    local raw = self.raw
    if self.kind == "rect" then return raw.width, raw.height end
    if self.kind == "image" then
        local w, h = raw.dst_width, raw.dst_height
        if (w <= 0 or h <= 0) and raw.buffer ~= nil then w, h = raw.buffer.width, raw.buffer.height end
        return w, h
    end
    error("size: not a rect or image", 2)
end

-- Images ---------------------------------------------------------------------------

--- Show another canvas (keeps the size set with set_size, if any).
function Node:set_canvas(canvas)
    assert(self.kind == "image", "set_canvas: not an image")
    local buf = buffer_of(canvas)
    lib.wlr_scene_buffer_set_buffer(self.raw, buf.buf.base)
    lib.wlr_buffer_drop(buf.buf.base)
end

-- Opacity ---------------------------------------------------------------------------

function Node:set_opacity(a)
    self._alpha = a
    if self.kind == "image" then
        lib.wlr_scene_buffer_set_opacity(self.raw, a)
    elseif self.kind == "rect" then
        self:color()
        paint(self)
    else
        for child in self:children() do child:set_opacity(a) end
    end
end

-- Trees ---------------------------------------------------------------------------

--- The nodes directly under a tree, bottom first.
function Node:children()
    assert(self.kind == "tree", "children: not a tree")
    local list = {}
    for node in wl.list.each(self.raw.children, "struct wlr_scene_node", "link") do
        list[#list + 1] = node
    end
    local i = 0
    return function()
        i = i + 1
        local node = list[i]
        if node then return scene.wrap(node) end
    end
end

--- A still copy of the images (shown or just unmapped) and shown rects
--- under this tree, flattened
--- into one new tree under `parent` (default: this tree's parent), at the
--- same place and just above it. Images share their pixels with the
--- originals.
function Node:snapshot(parent)
    assert(self.kind == "tree", "snapshot: not a tree")
    local copy = scene.tree(parent or self:parent())
    local x, y = self:position()
    copy:set_position(x, y)
    if not parent then copy:place_above(self) end
    local function walk(tree, ox, oy)
        for node in wl.list.each(tree.children, "struct wlr_scene_node", "link") do
            -- Surfaces are disabled as they unmap, which is when a copy is
            -- wanted: buffers count even then. Rects only when shown.
            local nx, ny = ox + node.x, oy + node.y
            if node.type == C.WLR_SCENE_NODE_TREE then
                walk(lib.wlr_scene_tree_from_node(node), nx, ny)
            elseif node.type == C.WLR_SCENE_NODE_BUFFER then
                local src = lib.wlr_scene_buffer_from_node(node)
                if src.buffer ~= nil then
                    local width = src.dst_width > 0 and src.dst_width or src.buffer.width
                    local height = src.dst_height > 0 and src.dst_height or src.buffer.height
                    local n = make("image", lib.wlr_scene_buffer_create(copy.raw, src.buffer))
                    n:set_position(nx, ny)
                    n:set_size(width, height)
                    if src.opacity < 1 then n:set_opacity(src.opacity) end
                end
            elseif node.type == C.WLR_SCENE_NODE_RECT and node.enabled then
                local r = lib.wlr_scene_rect_from_node(node)
                local n = scene.rect(copy, r.width, r.height, straight(r.color))
                n:set_position(nx, ny)
            end
        end
    end
    walk(self.raw, 0, 0)
    return copy
end

return scene
