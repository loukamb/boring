local wl = require("shared.wayland.server")
local ffi = wl._ffi

local Box = {}
Box.__index = Box

function Box.new(x, y, width, height)
    return setmetatable({
        x = x or 0,
        y = y or 0,
        width = width or 0,
        height = height or 0,
    }, Box)
end

function Box.from_wlr(box)
    if box == nil or box == ffi.NULL then
        return Box.new()
    end
    return Box.new(box.x, box.y, box.width, box.height)
end

function Box:copy()
    return Box.new(self.x, self.y, self.width, self.height)
end

function Box:to_wlr()
    return ffi.new("struct wlr_box", { self.x, self.y, self.width, self.height })
end

function Box:contains(x, y)
    return x >= self.x and y >= self.y
        and x < self.x + self.width
        and y < self.y + self.height
end

return Box
