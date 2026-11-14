-- plugins/library/fullscreen.lua
-- Fullscreen a window on an output and put it back where it was.
--
--   local fullscreen = require("@boring/library/fullscreen")
--   fullscreen.enter(w, output)   -- remembers the geometry, fills the output
--   fullscreen.fit(w, output)     -- the output changed size
--   fullscreen.exit(w)            -- restores the geometry
--
-- The window's own state (w.fullscreen, window:fullscreen) follows.

local fullscreen = {}

local saved = setmetatable({}, { __mode = "k" }) -- window -> geometry before

--- Fill an output's whole box (panels included).
function fullscreen.fit(w, o)
    local box, g = o:box(), w:geometry()
    w:set_position(box.x - g.x, box.y - g.y)
    w:set_size(box.width, box.height)
end

function fullscreen.enter(w, o)
    if not saved[w] then
        local x, y = w:position()
        local width, height = w:size()
        saved[w] = { x = x, y = y, width = width, height = height }
    end
    w:set_fullscreen(true)
    w:set_clip(nil)
    fullscreen.fit(w, o)
    w:raise()
end

--- Leave fullscreen. `restore = false` keeps the geometry (the caller is
--- about to place the window itself).
function fullscreen.exit(w, restore)
    local before = saved[w]
    saved[w] = nil
    w:set_fullscreen(false)
    if before and restore ~= false then
        w:set_position(before.x, before.y)
        w:set_size(before.width, before.height)
    end
end

return fullscreen
