-- plugins/library/capture.lua
-- What's on screen, as pixels: the scene graph composed on the CPU.
--
--   local capture = require("@boring/library/capture")
--   local canvas = capture.region({ x = 0, y = 0, width = 800, height = 600 })
--   local canvas = capture.output(o)                  -- a whole output
--   local canvas = capture.region(box, { scale = 2, exclude = { some_tree } })
--
-- Every enabled buffer and rect is read back (wlr_texture_read_pixels, so
-- GPU and software renderers both work) and blended in scene order. The
-- result is a library/pixels canvas in premultiplied ARGB, `scale` pixels
-- per layout pixel (default: the output's scale). Excluded trees (the
-- screenshot UI itself) are skipped. No external tools, no protocol.

local bit = require("bit")
local ffi = require("ffi")
local pixels = require("@boring/library/pixels")
local scene = require("@boring/library/scene")

local capture = {}

local wl = boring.wl
local lib, C = wl.lib, wl.C
local floor, min, max = math.floor, math.min, math.max

local DRM_FORMAT_ARGB8888 = 0x34325241

-- The pixels of a scene buffer's wlr_buffer: data, width, height (or nil).
local function read_buffer(buf)
    local server = boring.server
    local texture, own = nil, false
    local client = lib.wlr_client_buffer_get(buf)
    if client ~= nil and client.texture ~= nil then
        texture = client.texture
    else
        texture = lib.wlr_texture_from_buffer(server.renderer, buf)
        own = true
    end
    if texture == nil then return nil end
    local width, height = texture.width, texture.height
    local data = ffi.new("uint32_t[?]", width * height)
    local options = ffi.new("struct wlr_texture_read_pixels_options", {
        data = data, format = DRM_FORMAT_ARGB8888, stride = width * 4,
    })
    local ok = lib.wlr_texture_read_pixels(texture, options)
    if own then lib.wlr_texture_destroy(texture) end
    if not ok then return nil end
    return data, width, height
end

-- Compose one buffer node onto the canvas.
local function draw_buffer(canvas, box, scale, sb, nx, ny)
    if sb.buffer == nil then return end
    local data, tw, th = read_buffer(sb.buffer)
    if not data then return end
    local dw = sb.dst_width > 0 and sb.dst_width or tw
    local dh = sb.dst_height > 0 and sb.dst_height or th
    local sx, sy, sw, shh = 0, 0, tw, th
    local src = sb.src_box
    if src.width > 0 and src.height > 0 then sx, sy, sw, shh = src.x, src.y, src.width, src.height end
    local alpha = floor(max(0, min(1, sb.opacity)) * 255 + 0.5)

    -- The node's rect on the canvas.
    local cx0 = max(0, floor((nx - box.x) * scale))
    local cy0 = max(0, floor((ny - box.y) * scale))
    local cx1 = min(canvas.width, floor((nx + dw - box.x) * scale + 0.5))
    local cy1 = min(canvas.height, floor((ny + dh - box.y) * scale + 0.5))
    if cx1 <= cx0 or cy1 <= cy0 then return end
    local kx, ky = sw / (dw * scale), shh / (dh * scale)
    local ox, oy = (nx - box.x) * scale, (ny - box.y) * scale
    local blend, out, cw = pixels.blend, canvas.data, canvas.width
    local exact = kx == 1 and ky == 1 and alpha == 255
    for y = cy0, cy1 - 1 do
        local v = min(th - 1, floor(sy + (y + 0.5 - oy) * ky))
        local row = v * tw
        local base = y * cw
        for x = cx0, cx1 - 1 do
            local u = min(tw - 1, floor(sx + (x + 0.5 - ox) * kx))
            local p = data[row + u]
            local a = bit.rshift(p, 24)
            if exact and a == 255 then
                out[base + x] = p
            elseif a > 0 then
                blend(canvas, base + x, p, alpha)
            end
        end
    end
end

local function draw_rect(canvas, box, scale, r, nx, ny)
    local c = r.color
    if c[3] <= 0 then return end
    local p = bit.bor(bit.lshift(floor(c[3] * 255 + 0.5), 24), bit.lshift(floor(c[0] * 255 + 0.5), 16),
        bit.lshift(floor(c[1] * 255 + 0.5), 8), floor(c[2] * 255 + 0.5))
    local x0 = max(0, floor((nx - box.x) * scale))
    local y0 = max(0, floor((ny - box.y) * scale))
    local x1 = min(canvas.width, floor((nx + r.width - box.x) * scale + 0.5))
    local y1 = min(canvas.height, floor((ny + r.height - box.y) * scale + 0.5))
    for y = y0, y1 - 1 do
        local base = y * canvas.width
        for x = x0, x1 - 1 do pixels.blend(canvas, base + x, p, 255) end
    end
end

-- Walk a tree in drawing order (bottom first).
local function walk(canvas, box, scale, tree, ox, oy, excluded)
    for node in wl.list.each(tree.children, "struct wlr_scene_node", "link") do
        if node.enabled and not excluded[wl.addr(node)] then
            local x, y = ox + node.x, oy + node.y
            if node.type == C.WLR_SCENE_NODE_TREE then
                walk(canvas, box, scale, lib.wlr_scene_tree_from_node(node), x, y, excluded)
            elseif node.type == C.WLR_SCENE_NODE_BUFFER then
                draw_buffer(canvas, box, scale, lib.wlr_scene_buffer_from_node(node), x, y)
            elseif node.type == C.WLR_SCENE_NODE_RECT then
                draw_rect(canvas, box, scale, lib.wlr_scene_rect_from_node(node), x, y)
            end
        end
    end
end

--- A region of the layout (layout coordinates) as a canvas.
--- opts: scale (pixels per layout pixel, default 1), exclude (library/scene
--- trees, or raw ones).
function capture.region(box, opts)
    opts = opts or {}
    local scale = opts.scale or 1
    local canvas = pixels.new(max(1, floor(box.width * scale + 0.5)), max(1, floor(box.height * scale + 0.5)))
    -- Opaque black underneath, like an output.
    for i = 0, canvas.width * canvas.height - 1 do canvas.data[i] = 0xff000000 end
    local excluded = {}
    for _, tree in ipairs(opts.exclude or {}) do excluded[wl.addr(scene.raw(tree).node)] = true end
    walk(canvas, box, scale, boring.server.scene.tree, 0, 0, excluded)
    return canvas
end

--- A whole output, at its scale.
function capture.output(o, opts)
    opts = opts or {}
    return capture.region(o:box(), { scale = opts.scale or o:scale(), exclude = opts.exclude })
end

return capture
