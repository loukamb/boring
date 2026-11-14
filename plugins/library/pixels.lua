-- plugins/library/pixels.lua
-- Images in memory and drawing on them, in plain Lua.
--
--   local pixels = require("@boring/library/pixels")
--   local c = pixels.new(200, 100)                    -- { width, height, data = uint32_t[] }
--   pixels.fill(c, 0, 0, 200, 100, pixels.argb(1, 1, 1))
--   pixels.line(c, 10, 10, 190, 90, 4, pixels.argb(1, 0, 0))
--   pixels.blur(c, 20, 20, 60, 40, 8)                 -- box blur a region
--   local part = pixels.crop(c, 50, 0, 100, 100)
--
-- Pixels are premultiplied ARGB (0xAARRGGBB), what scene buffers and
-- wlr_texture_read_pixels use. Coordinates are clipped to the canvas.

local bit = require("bit")
local ffi = require("ffi")

local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift
local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt

local pixels = {}

function pixels.new(width, height)
    return { width = width, height = height, data = ffi.new("uint32_t[?]", math.max(1, width * height)) }
end

--- Premultiplied ARGB from 0..1 floats.
function pixels.argb(r, g, b, a)
    a = a or 1
    local function c(v) return floor(max(0, min(1, v)) * a * 255 + 0.5) end
    return bor(lshift(floor(a * 255 + 0.5), 24), lshift(c(r), 16), lshift(c(g), 8), c(b))
end

function pixels.copy(c)
    local out = pixels.new(c.width, c.height)
    ffi.copy(out.data, c.data, c.width * c.height * 4)
    return out
end

-- Clip a rectangle to the canvas: x0, y0, x1, y1 (exclusive), or nil.
local function clip(c, x, y, w, h)
    local x0, y0 = max(0, floor(x)), max(0, floor(y))
    local x1, y1 = min(c.width, floor(x + w)), min(c.height, floor(y + h))
    if x1 <= x0 or y1 <= y0 then return nil end
    return x0, y0, x1, y1
end

function pixels.crop(c, x, y, w, h)
    local out = pixels.new(w, h)
    local x0, y0, x1, y1 = clip(c, x, y, w, h)
    if not x0 then return out end
    for row = y0, y1 - 1 do
        ffi.copy(out.data + (row - y) * w + (x0 - x), c.data + row * c.width + x0, (x1 - x0) * 4)
    end
    return out
end

--- Draw `src` onto `dst` at (x, y), blending.
function pixels.paste(dst, src, x, y)
    for row = 0, src.height - 1 do
        local dy = y + row
        if dy >= 0 and dy < dst.height then
            for col = 0, src.width - 1 do
                local dx = x + col
                if dx >= 0 and dx < dst.width then
                    pixels.blend(dst, dy * dst.width + dx, src.data[row * src.width + col], 255)
                end
            end
        end
    end
end

--- Blend a premultiplied pixel over data[i], scaled by `alpha` (0..255).
function pixels.blend(c, i, p, alpha)
    local a = rshift(p, 24)
    if alpha < 255 then
        local k = alpha / 255
        a = floor(a * k + 0.5)
        p = bor(lshift(a, 24), lshift(floor(band(rshift(p, 16), 0xff) * k + 0.5), 16),
            lshift(floor(band(rshift(p, 8), 0xff) * k + 0.5), 8), floor(band(p, 0xff) * k + 0.5))
    end
    if a == 0 then return end
    if a == 255 then
        c.data[i] = p
        return
    end
    local d = c.data[i]
    local inv = 255 - a
    local function ch(shift)
        return min(255, band(rshift(p, shift), 0xff) + floor(band(rshift(d, shift), 0xff) * inv / 255 + 0.5))
    end
    c.data[i] = bor(lshift(ch(24), 24), lshift(ch(16), 16), lshift(ch(8), 8), ch(0))
end
local blend = pixels.blend

function pixels.fill(c, x, y, w, h, p)
    local x0, y0, x1, y1 = clip(c, x, y, w, h)
    if not x0 then return end
    for row = y0, y1 - 1 do
        local base = row * c.width
        for col = x0, x1 - 1 do blend(c, base + col, p, 255) end
    end
end

--- Box blur a region (three passes: close to a gaussian).
function pixels.blur(c, x, y, w, h, radius)
    local x0, y0, x1, y1 = clip(c, x, y, w, h)
    if not x0 or radius < 1 then return end
    local rw, rh = x1 - x0, y1 - y0
    local tmp = ffi.new("uint32_t[?]", max(rw, rh))
    local data, stride = c.data, c.width
    -- One pass along a line of n pixels at data[start + k * step].
    local function pass(start, step, n)
        for k = 0, n - 1 do tmp[k] = data[start + k * step] end
        local r = min(radius, n - 1)
        local sa, sr, sg, sb = 0, 0, 0, 0
        local function add(p, s)
            sa = sa + band(rshift(p, 24), 0xff) * s
            sr = sr + band(rshift(p, 16), 0xff) * s
            sg = sg + band(rshift(p, 8), 0xff) * s
            sb = sb + band(p, 0xff) * s
        end
        -- The window around k, with edges repeated.
        for k = -r, r do add(tmp[min(n - 1, max(0, k))], 1) end
        local size = 2 * r + 1
        for k = 0, n - 1 do
            data[start + k * step] = bor(lshift(floor(sa / size + 0.5), 24), lshift(floor(sr / size + 0.5), 16),
                lshift(floor(sg / size + 0.5), 8), floor(sb / size + 0.5))
            add(tmp[min(n - 1, k + r + 1)], 1)
            add(tmp[max(0, k - r)], -1)
        end
    end
    for _ = 1, 3 do
        for row = y0, y1 - 1 do pass(row * stride + x0, 1, rw) end
        for col = x0, x1 - 1 do pass(y0 * stride + col, stride, rh) end
    end
end

-- A filled, antialiased disc.
local function disc(c, cx, cy, r, p)
    local x0, y0, x1, y1 = clip(c, cx - r - 1, cy - r - 1, 2 * r + 3, 2 * r + 3)
    if not x0 then return end
    for y = y0, y1 - 1 do
        for x = x0, x1 - 1 do
            local dx, dy = x + 0.5 - cx, y + 0.5 - cy
            local coverage = r + 0.5 - sqrt(dx * dx + dy * dy)
            if coverage > 0 then blend(c, y * c.width + x, p, floor(min(1, coverage) * 255)) end
        end
    end
end
pixels.disc = disc

--- A line `width` pixels thick with round ends.
function pixels.line(c, ax, ay, bx, by, width, p)
    local r = max(0.5, width / 2)
    local x0, y0, x1, y1 = clip(c, min(ax, bx) - r - 1, min(ay, by) - r - 1,
        math.abs(bx - ax) + 2 * r + 3, math.abs(by - ay) + 2 * r + 3)
    if not x0 then return end
    local vx, vy = bx - ax, by - ay
    local len2 = vx * vx + vy * vy
    for y = y0, y1 - 1 do
        for x = x0, x1 - 1 do
            local px, py = x + 0.5 - ax, y + 0.5 - ay
            local t = len2 > 0 and max(0, min(1, (px * vx + py * vy) / len2)) or 0
            local dx, dy = px - t * vx, py - t * vy
            local coverage = r + 0.5 - sqrt(dx * dx + dy * dy)
            if coverage > 0 then blend(c, y * c.width + x, p, floor(min(1, coverage) * 255)) end
        end
    end
end

--- A rectangle outline.
function pixels.outline(c, x, y, w, h, width, p)
    pixels.line(c, x, y, x + w, y, width, p)
    pixels.line(c, x + w, y, x + w, y + h, width, p)
    pixels.line(c, x + w, y + h, x, y + h, width, p)
    pixels.line(c, x, y + h, x, y, width, p)
end

--- A line with an arrowhead at (bx, by).
function pixels.arrow(c, ax, ay, bx, by, width, p)
    pixels.line(c, ax, ay, bx, by, width, p)
    local angle = math.atan2(by - ay, bx - ax)
    local head = max(10, width * 4)
    for _, side in ipairs({ -1, 1 }) do
        local a = angle + math.pi + side * math.pi / 6
        pixels.line(c, bx, by, bx + math.cos(a) * head, by + math.sin(a) * head, width, p)
    end
end

return pixels
