return function(t)
    local color = require("shared.color")

    t.test("color hex, int, and hex round trips include alpha", function()
        local c = color.hex("#33669980")
        local r, g, b, a = color.to_int(c)
        t.eq(r, 0x33)
        t.eq(g, 0x66)
        t.eq(b, 0x99)
        t.eq(a, 0x80)
        t.eq(color.to_hex(c), "#336699")
    end)

    t.test("color parse falls back; float4 premultiplies alpha", function()
        local grey = { 0.5, 0.5, 0.5, 1 }
        t.eq(color.parse("bad", grey), grey)
        t.eq(color.parse({ 1, 0, 0 })[4], 1)
        t.eq(color.parse("#ff0000")[1], 1)

        local c = color.float4({ 1.0, 0.5, 0.25, 0.5 })
        t.eq(c[0], 0.5)
        t.eq(c[1], 0.25)
        t.eq(c[2], 0.125)
        t.eq(c[3], 0.5)
    end)
end
