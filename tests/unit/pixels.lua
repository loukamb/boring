return function(t)
    local bit = require("bit")
    local pixels = require("plugins.library.pixels")

    local function channel(p, shift) return bit.band(bit.rshift(p, shift), 0xff) end

    t.test("pixels: fill, crop, blend", function()
        local c = pixels.new(4, 4)
        pixels.fill(c, 0, 0, 4, 4, pixels.argb(0, 0, 1))
        pixels.fill(c, 2, 0, 2, 4, pixels.argb(1, 0, 0, 0.5))
        local part = pixels.crop(c, 1, 1, 2, 2)
        t.eq(part.width, 2)
        t.eq(part.data[0], c.data[1 * 4 + 1])
        local mixed = c.data[1 * 4 + 2]
        t.eq(channel(mixed, 24), 255)                     -- opaque stays opaque
        t.ok(math.abs(channel(mixed, 16) - 128) <= 1)     -- half red
        t.ok(math.abs(channel(mixed, 0) - 128) <= 1)      -- half the blue left
        -- Cropping past the edge leaves the rest transparent.
        t.eq(pixels.crop(c, 3, 3, 2, 2).data[3], 0)
    end)

    t.test("pixels: blur spreads within the region only", function()
        local c = pixels.new(9, 1)
        for i = 0, 8 do c.data[i] = pixels.argb(0, 0, 0) end
        c.data[4] = pixels.argb(1, 1, 1)
        local outside = c.data[0]
        pixels.blur(c, 2, 0, 5, 1, 1)
        t.ok(channel(c.data[4], 16) < 255 and channel(c.data[3], 16) > 0, "blurred")
        t.eq(c.data[0], outside)
    end)

    t.test("pixels: lines and arrows cover their path", function()
        local c = pixels.new(20, 20)
        pixels.line(c, 2, 10, 18, 10, 3, pixels.argb(1, 0, 0))
        t.eq(channel(c.data[10 * 20 + 10], 24), 255)
        t.eq(c.data[2 * 20 + 10], 0)
        pixels.arrow(c, 2, 2, 15, 2, 2, pixels.argb(0, 1, 0))
        t.ok(channel(c.data[2 * 20 + 8], 8) > 200)
    end)
end
