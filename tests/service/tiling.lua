return function(t)
    -- The tree code doesn't touch the compositor; spaces is only needed at load.
    package.preload["@boring/library/spaces"] = function() return { of = function() end } end
    local plugin = require("plugins.layout-tiling")
    package.preload["@boring/library/spaces"] = nil
    local tiling = plugin._private

    local function tree() return { layout = "horizontal", children = {} } end
    local function window(name) return { id = name } end
    local function arrange(tr, width, height)
        tiling.lay_out(tr.children, { x = 0, y = 0, width = width or 800, height = height or 600 }, 0,
            tr.layout == "horizontal")
    end

    t.test("tiling: a vertical split around the focused window takes the next one", function()
        local tr, a, b = tree(), window("a"), window("b")
        tiling.add(tr, a)
        tiling.split_at(tr, a, "vertical")
        tiling.add(tr, b, a)
        local root = tr.children[1]
        t.eq(root.type, "split")
        t.eq(root.layout, "vertical")
        t.eq(root.children[1].window, a)
        t.eq(root.children[2].window, b)
    end)

    t.test("tiling: removing collapses splits with one child left", function()
        local tr, a, b = tree(), window("a"), window("b")
        tiling.add(tr, a)
        tiling.split_at(tr, a, "vertical")
        tiling.add(tr, b, a)
        tiling.remove(tr, b)
        t.eq(#tr.children, 1)
        t.eq(tr.children[1].type, "leaf")
        t.eq(tr.children[1].window, a)
        t.eq(tr.children[1].parent, nil)
    end)

    t.test("tiling: arranging shares the width; hit testing finds nested leaves", function()
        local tr, a, b, c = tree(), window("a"), window("b"), window("c")
        tiling.add(tr, a)
        tiling.add(tr, b, a)
        tiling.split_at(tr, b, "vertical")
        tiling.add(tr, c, b)
        arrange(tr)
        local la, lb, lc = tiling.find(tr.children, a), tiling.find(tr.children, b), tiling.find(tr.children, c)
        t.eq(la.width, 400)
        t.eq(lb.x, 400)
        t.eq(lb.height, 300)
        t.eq(lc.y, 300)
        t.eq(tiling.leaf_at(tr.children, 500, 450).window, c)
    end)

    t.test("tiling: neighbours by direction", function()
        local tr, a, b, c = tree(), window("a"), window("b"), window("c")
        tiling.add(tr, a)
        tiling.add(tr, b, a)
        tiling.split_at(tr, b, "vertical")
        tiling.add(tr, c, b)
        arrange(tr)
        local la, lb, lc = tiling.find(tr.children, a), tiling.find(tr.children, b), tiling.find(tr.children, c)
        t.eq(tiling.neighbour(tr, la, "right"), lb)
        t.eq(tiling.neighbour(tr, lc, "left"), la)
        t.eq(tiling.neighbour(tr, lb, "down"), lc)
        t.eq(tiling.neighbour(tr, lc, "up"), lb)
        t.eq(tiling.neighbour(tr, la, "left"), nil)
    end)

    t.test("tiling: resizing moves the boundary and respects the minimum", function()
        local tr, a, b = tree(), window("a"), window("b")
        tiling.add(tr, a)
        tiling.add(tr, b, a)
        arrange(tr)
        local la = tiling.find(tr.children, a)
        local edge = require("ffi").C.WLR_EDGE_RIGHT
        local target, list = tiling.resize_target(tr, la, edge)
        t.eq(target, la)
        t.ok(tiling.resize_by(target, list, edge, 100))
        arrange(tr)
        t.eq(la.width, 500)
        t.ok(not tiling.resize_by(target, list, edge, 1000))
        t.eq(tiling.resize_target(tr, la, require("ffi").C.WLR_EDGE_LEFT), nil)
    end)
end
