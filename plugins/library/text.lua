-- plugins/library/text.lua
-- Text drawn into the scene graph.
--
--   local text = require("@boring/library/text")
--   local node, width, height = text.draw(parent, "Hello", {   -- a library/scene tree
--       font = "Sans Bold 10",   -- Pango font description
--       color = "#ffffff",       -- hex string or { r, g, b, a }
--       max_width = 200,         -- longer text ends in "…"
--       wrap = nil,              -- or a width: break into lines instead
--   })
--
-- Text is rendered by libvips (Pango); without it, `text.available` is false
-- and draw returns nil. Rendered text is cached by string and font.

local ffi = require("ffi")
local image = require("shared.image")
local buffer = require("shared.wl.buffer")
local scene = require("@boring/library/scene")
local color = require("shared.color")

local text = {}

text.available = image.available

local DEFAULT_FONT = "Sans 10"
local ELLIPSIS = "…"
local CACHE_LIMIT = 512

local cache, cached = {}, 0

-- width, height and coverage bytes of a string, or nil.
local function mask(str, font, wrap)
    local key = font .. "\0" .. (wrap or "") .. "\0" .. str
    local m = cache[key]
    if m then return m[1], m[2], m[3] end
    local ok, width, height, bytes = pcall(image.text, str, font, nil, wrap)
    if not ok or not width then return nil end
    if cached >= CACHE_LIMIT then cache, cached = {}, 0 end
    cache[key] = { width, height, bytes }
    cached = cached + 1
    return width, height, bytes
end

--- Size of a string in pixels, or nil if it can't be rendered.
function text.measure(str, opts)
    if not text.available or not str or str == "" then return nil end
    opts = opts or {}
    local width, height = mask(str, opts.font or DEFAULT_FONT, opts.wrap)
    return width, height
end

-- UTF-8 character boundaries of a string: positions after each character.
local function boundaries(str)
    local ends = {}
    for pos in str:gmatch("[%z\1-\127\194-\244][\128-\191]*()") do ends[#ends + 1] = pos - 1 end
    return ends
end

--- The longest prefix of `str` that fits in max_width with "…" after it
--- (or `str` if it fits as it is).
function text.fit(str, font, max_width)
    font = font or DEFAULT_FONT
    local width = mask(str, font)
    if not width or width <= max_width then return str end
    local ends = boundaries(str)
    local lo, hi = 0, #ends - 1 -- number of characters kept
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        local candidate = str:sub(1, ends[mid]) .. ELLIPSIS
        local w = mask(candidate, font)
        if w and w <= max_width then lo = mid else hi = mid - 1 end
    end
    if lo == 0 then return ELLIPSIS end
    return (str:sub(1, ends[lo]):gsub("%s+$", "")) .. ELLIPSIS
end

-- Premultiplied ARGB for each coverage value, per colour.
local luts = {}
local function lut_for(c)
    local key = table.concat(c, ",")
    local lut = luts[key]
    if lut then return lut end
    lut = ffi.new("uint32_t[256]")
    for i = 1, 255 do lut[i] = buffer.argb(c[1], c[2], c[3], (c[4] or 1) * i / 255) end
    luts[key] = lut
    return lut
end

--- Draw text under a scene tree. Returns the image (library/scene), its
--- width and height; nil if there's nothing to draw or no text renderer.
function text.draw(parent, str, opts)
    if not text.available or not str or str == "" then return nil end
    opts = opts or {}
    local font = opts.font or DEFAULT_FONT
    if opts.max_width and not opts.wrap then str = text.fit(str, font, opts.max_width) end
    local width, height, bytes = mask(str, font, opts.wrap)
    if not width then return nil end

    local lut = lut_for(color.parse(opts.color, { 1, 1, 1, 1 }))
    local buf = buffer.new(width, height)
    local px, src = buf.pixels, ffi.cast("const uint8_t *", bytes)
    for i = 0, width * height - 1 do px[i] = lut[src[i]] end
    return scene.wrap(buffer.attach(scene.raw(parent), buf)), width, height
end

return text
