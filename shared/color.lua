--- Color manipulation utilities
---@class shared.color
local ffi = require("ffi")

local color = {}
--- RGBA color type (array of 4 floats in 0-1 range)
--- @alias Color number[] Array of {r, g, b, a} floats (0-1 range)

---Create color from 0-255 integer values
---@param r number Red component (0-255)
---@param g number Green component (0-255)
---@param b number Blue component (0-255)
---@param a number|nil Alpha component (0-255), defaults to 255
---@return Color RGBA color as float array (0-1 range)
function color.rgb(r, g, b, a)
    return { r / 255, g / 255, b / 255, (a or 255) / 255 }
end

---Create color from 0-1 float values
---@param r number Red component (0-1)
---@param g number Green component (0-1)
---@param b number Blue component (0-1)
---@param a number|nil Alpha component (0-1), defaults to 1.0
---@return Color RGBA color as float array
function color.rgba(r, g, b, a)
    return { r, g, b, a or 1.0 }
end

---Parse hex string to color
---@param str string Hex color string (e.g., "#RRGGBB" or "#RRGGBBAA")
---@return Color|nil RGBA color, or nil on invalid input
function color.hex(str)
    if not str or str:sub(1, 1) ~= "#" then
        return nil
    end
    local hex_str = str:sub(2)
    if #hex_str == 6 then
        local r = tonumber(hex_str:sub(1, 2), 16)
        local g = tonumber(hex_str:sub(3, 4), 16)
        local b = tonumber(hex_str:sub(5, 6), 16)
        if r and g and b then
            return { r / 255, g / 255, b / 255, 1.0 }
        end
    elseif #hex_str == 8 then
        local r = tonumber(hex_str:sub(1, 2), 16)
        local g = tonumber(hex_str:sub(3, 4), 16)
        local b = tonumber(hex_str:sub(5, 6), 16)
        local a = tonumber(hex_str:sub(7, 8), 16)
        if r and g and b and a then
            return { r / 255, g / 255, b / 255, a / 255 }
        end
    end
    return nil
end

---A color from a config value: a hex string or an {r, g, b, a} table.
---@param value string|Color|nil
---@param fallback Color|nil returned when value is missing or invalid
---@return Color|nil
function color.parse(value, fallback)
    if type(value) == "string" then return color.hex(value) or fallback end
    if type(value) == "table" then
        return { value[1] or 0, value[2] or 0, value[3] or 0, value[4] or 1 }
    end
    return fallback
end

---Premultiplied float[4], what wlroots scene rects take.
---@param c Color
---@return ffi.cdata* float[4]
function color.float4(c)
    local a = c[4] or 1
    return ffi.new("float[4]", c[1] * a, c[2] * a, c[3] * a, a)
end

---Write the premultiplied colour into an existing float[4] (no allocation;
---for per-frame updates).
---@param c Color
---@param out ffi.cdata* float[4]
---@return ffi.cdata* out
function color.float4_into(c, out)
    local a = c[4] or 1
    out[0], out[1], out[2], out[3] = c[1] * a, c[2] * a, c[3] * a, a
    return out
end

---Convert color to hex string (ignores alpha)
---@param c Color RGBA color
---@return string Hex string in "#RRGGBB" format
function color.to_hex(c)
    return string.format("#%02X%02X%02X",
        math.floor(c[1] * 255 + 0.5),
        math.floor(c[2] * 255 + 0.5),
        math.floor(c[3] * 255 + 0.5))
end

---Convert color to 0-255 integer values
---@param c Color RGBA color
---@return number r Red (0-255)
---@return number g Green (0-255)
---@return number b Blue (0-255)
---@return number a Alpha (0-255)
function color.to_int(c)
    return
        math.floor(c[1] * 255 + 0.5),
        math.floor(c[2] * 255 + 0.5),
        math.floor(c[3] * 255 + 0.5),
        math.floor(c[4] * 255 + 0.5)
end

return color
