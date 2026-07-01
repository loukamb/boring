return function(t)
    local borders = require("plugins.borders")._private

    t.test("borders parse color falls back and premultiplies alpha", function()
        local fallback = borders.parse_color("bad")
        t.eq(fallback[1], 0.5)
        t.eq(fallback[4], 1.0)

        local color = borders.premultiply({ 1.0, 0.5, 0.25, 0.5 })
        t.eq(color[0], 0.5)
        t.eq(color[1], 0.25)
        t.eq(color[2], 0.125)
        t.eq(color[3], 0.5)
    end)
end
