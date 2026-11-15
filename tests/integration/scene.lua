-- library/scene against a real (headless) scene graph.

return function(t)
    local compositor = require("tests.harness.compositor")

    local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

    local function with_compositor(fn)
        local c, log = compositor.start({ config = "tests/fixtures/minimal_ipc_config.lua" })
        if not c then error("compositor failed to start:\n" .. tostring(log)) end
        local function ipc(code) return c.exec("luajit boring.lua -e " .. quote(code)) end
        local ok, err = pcall(fn, c, ipc)
        local final_log = c.stop()
        if not ok then error(tostring(err) .. "\ncompositor log:\n" .. final_log, 0) end
        t.ok(not final_log:match("err!"), final_log)
    end

    t.test("scene: nodes are the same object, and know their kind and place", function()
        with_compositor(function(_, ipc)
            local out = ipc([[local scene = require("@boring/library/scene")
local tree = scene.tree(scene.layer("overlay"))
tree:set_position(10, 20)
local r = scene.rect(tree, 30, 40, "#ff0000")
r:set_position(1.6, 2)
local kinds = {}
for n in tree:children() do kinds[#kinds + 1] = n.kind .. tostring(n == r) end
local x, y = r:position()
local w, h = r:size()
local same = scene.wrap(r.raw) == r and r:parent() == tree
tree:destroy()
print(table.concat(kinds, ","), x, y, w, h, same)]])
            t.eq(out, "recttrue\t1\t2\t30\t40\ttrue")
        end)
    end)

    t.test("scene: rect colours and opacity are premultiplied for wlroots", function()
        with_compositor(function(_, ipc)
            local out = ipc([[local scene = require("@boring/library/scene")
local r = scene.rect(scene.layer("overlay"), 4, 4, { 1, 0.5, 0, 0.5 })
r:set_opacity(0.5)
local k = r.raw.color
local c = r:color()
print(string.format("%.3f %.3f %.3f %.3f | %.2f %.2f", k[0], k[1], k[2], k[3], c[2], c[4]))
r:destroy()]])
            t.eq(out, "0.250 0.125 0.000 0.250 | 0.50 0.50")
        end)
    end)

    t.test("scene: images show a canvas and snapshots copy a tree", function()
        with_compositor(function(_, ipc)
            local out = ipc([[local scene = require("@boring/library/scene")
local pixels = require("@boring/library/pixels")
local canvas = pixels.new(2, 3)
local tree = scene.tree(scene.layer("overlay"))
tree:set_position(5, 5)
local img = scene.image(tree, canvas)
img:set_position(3, 4)
local w1, h1 = img:size()
img:set_size(20, 30)
local sub = scene.tree(tree)
sub:set_position(10, 0)
scene.rect(sub, 7, 8, "#00ff00"):set_position(1, 1)
local copy = tree:snapshot()
local parts = {}
for n in copy:children() do
    local x, y = n:position()
    local w, h = n:size()
    parts[#parts + 1] = string.format("%s@%d,%d:%dx%d", n.kind, x, y, w, h)
end
local cx, cy = copy:position()
copy:destroy()
tree:destroy()
print(w1, h1, cx, cy, table.concat(parts, " "))]])
            t.eq(out, "2\t3\t5\t5\timage@3,4:20x30 rect@11,1:7x8")
        end)
    end)
end
