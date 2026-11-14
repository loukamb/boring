return function(t)
    local equal = require("shared.equal")

    t.test("equal compares tables structurally, including table keys", function()
        t.ok(equal({ a = 1, b = { c = "x" } }, { a = 1, b = { c = "x" } }))
        t.ok(not equal({ a = 1 }, { a = 1, b = 2 }))
        t.ok(not equal({ a = 1, b = 2 }, { a = 1 }))
        t.ok(equal({ [{ name = "*" }] = "#fff" }, { [{ name = "*" }] = "#fff" }))
        t.ok(not equal({ [{ name = "*" }] = "#fff" }, { [{ name = "eDP-1" }] = "#fff" }))
    end)

    t.test("equal treats recreated closures as equal when code and upvalues match", function()
        local function make(n) return function() return n end end
        t.ok(equal(make(1), make(1)))
        t.ok(not equal(make(1), make(2)))
        t.ok(not equal(function() return 1 end, function() return 2 end))
        t.ok(not equal(print, function() end))
        t.ok(equal(print, print))
    end)

    t.test("equal handles cycles", function()
        local a, b = { x = 1 }, { x = 1 }
        a.self, b.self = a, b
        t.ok(equal(a, b))
    end)
end
