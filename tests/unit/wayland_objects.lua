return function(t)
    local Box = require("shared.wayland.box")
    local Surface = require("shared.wayland.surface")

    t.test("box copies and contains points", function()
        local box = Box.new(10, 20, 30, 40)
        local copy = box:copy()

        t.eq(copy.x, 10)
        t.eq(copy.y, 20)
        t.eq(copy:contains(20, 30), true)
        t.eq(copy:contains(50, 30), false)
    end)

    t.test("surface exposes xwayland geometry without role shims", function()
        local ffi = require("ffi")
        pcall(ffi.cdef, [[
            struct boring_test_xwayland_surface {
                int width;
                int height;
            };
        ]])

        local surface = Surface.new({
            wlr_surface = nil,
            role = "xwayland",
            role_obj = ffi.new("struct boring_test_xwayland_surface", { 640, 480 }),
        })
        local geo = surface:geometry()

        t.eq(geo.width, 640)
        t.eq(geo.height, 480)
    end)
end
