return function(t)
    local color = require("shared.color")
    local hash = require("shared.hash")

    t.test("color hex, int, and hex round trips include alpha", function()
        local c = color.hex("#33669980")
        local r, g, b, a = color.to_int(c)
        t.eq(r, 0x33)
        t.eq(g, 0x66)
        t.eq(b, 0x99)
        t.eq(a, 0x80)
        t.eq(color.to_hex(c), "#336699")
    end)

    t.test("hash sha256 is stable", function()
        t.eq(hash.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        t.eq(hash.short("abc"), "ba7816bf8f01cfea")
    end)
end
