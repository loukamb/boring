return function(t)
    local plugin = require("plugins.layout-tiling")
    local tiling = plugin._private.layout
    local private = plugin._private

    local function surface(name)
        return { id = name }
    end

    local function state()
        local monitor_state = {
            output = {
                dimensions = function()
                    return 800, 600
                end,
            },
            config = { gaps = { inner = 0, outer = 0, smart = false } },
        }
        tiling:init(monitor_state)
        return monitor_state
    end

    t.test("tiling creates nested vertical split around focused container", function()
        local ms = state()
        local a, b = surface("a"), surface("b")
        private.add_window(ms.tiling, a)
        tiling:split(ms, a, "vertical")
        private.add_window(ms.tiling, b, a)

        local root = ms.tiling.children[1]
        t.eq(root.type, "split")
        t.eq(root.layout, "vertical")
        t.eq(#root.children, 2)
        t.eq(root.children[1].surface, a)
        t.eq(root.children[2].surface, b)
    end)

    t.test("tiling collapses single-child nested splits on removal", function()
        local ms = state()
        local a, b = surface("a"), surface("b")
        private.add_window(ms.tiling, a)
        tiling:split(ms, a, "vertical")
        private.add_window(ms.tiling, b, a)
        private.remove_window(ms.tiling, b)

        t.eq(ms.tiling.children[1].type, "leaf")
        t.eq(ms.tiling.children[1].surface, a)
    end)

    t.test("tiling hit testing descends into nested leaves", function()
        local ms = state()
        local a, b = surface("a"), surface("b")
        private.add_window(ms.tiling, a)
        tiling:split(ms, a, "vertical")
        private.add_window(ms.tiling, b, a)
        local root = ms.tiling.children[1]
        root.x, root.y, root.width, root.height = 0, 0, 100, 100
        root.children[1].x, root.children[1].y, root.children[1].width, root.children[1].height = 0, 0, 100, 50
        root.children[2].x, root.children[2].y, root.children[2].width, root.children[2].height = 0, 50, 100, 50

        t.eq(private.find_leaf_at(ms.tiling.children, 10, 75).surface, b)
    end)
end
