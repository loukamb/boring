-- wlr_buffers backed by pixels in Lua-owned memory, for drawing text and
-- decorations into the scene graph (wlr_scene_buffer_create).
--
--   local buf = buffer.new(width, height)      -- ARGB8888, premultiplied
--   buf.pixels[y * width + x] = 0xff000000     -- uint32 per pixel
--   local node = buffer.attach(tree, buf)      -- the scene now owns it
--
-- All buffers share one wlr_buffer_impl, i.e. three C callbacks in total.

local bit = require("bit")
local ffi = require("ffi")
local wl = require("shared.wl")

local lib = wl.lib

local buffer = {}

ffi.cdef [[
struct boring_buffer {
    struct wlr_buffer base;
    uint32_t id;
};
]]

local DRM_FORMAT_ARGB8888 = 0x34325241 -- fourcc 'AR24'
local WLR_BUFFER_DATA_PTR_ACCESS_WRITE = 2

local boring_buffer_ptr = ffi.typeof("struct boring_buffer *")
local objects = {} -- id -> { buf = cdata, pixels = uint32_t[], stride = n }
local next_id = 1

local function entry(wlr_buffer)
    return objects[ffi.cast(boring_buffer_ptr, wlr_buffer).id]
end

local impl = ffi.new("struct wlr_buffer_impl")
impl.destroy = ffi.cast("void (*)(struct wlr_buffer *)", function(b)
    objects[ffi.cast(boring_buffer_ptr, b).id] = nil
end)
impl.begin_data_ptr_access = ffi.cast(
    "bool (*)(struct wlr_buffer *, uint32_t, void **, uint32_t *, size_t *)",
    function(b, flags, data, format, stride)
        local e = entry(b)
        if not e or bit.band(flags, WLR_BUFFER_DATA_PTR_ACCESS_WRITE) ~= 0 then
            return false
        end
        data[0] = e.pixels
        format[0] = DRM_FORMAT_ARGB8888
        stride[0] = e.stride
        return true
    end)
impl.end_data_ptr_access = ffi.cast("void (*)(struct wlr_buffer *)", function() end)

--- A transparent width x height ARGB8888 buffer. Fill `pixels` (uint32
--- 0xAARRGGBB, premultiplied) before attaching it.
function buffer.new(width, height)
    local id = next_id
    next_id = next_id + 1
    local buf = ffi.new("struct boring_buffer")
    buf.id = id
    local pixels = ffi.new("uint32_t[?]", width * height)
    local e = { buf = buf, pixels = pixels, stride = width * 4, width = width, height = height }
    objects[id] = e
    lib.wlr_buffer_init(buf.base, impl, width, height)
    return e
end

--- Show a buffer in the scene under `tree`; returns the wlr_scene_buffer.
--- The scene takes the buffer over: don't reuse it afterwards.
function buffer.attach(tree, e)
    local node = lib.wlr_scene_buffer_create(tree, e.buf.base)
    lib.wlr_buffer_drop(e.buf.base)
    return node
end

--- Premultiplied 0xAARRGGBB from 0..1 floats.
function buffer.argb(r, g, b, a)
    a = a or 1
    local function c(v) return math.floor(math.max(0, math.min(1, v)) * a * 255 + 0.5) end
    return bit.bor(bit.lshift(math.floor(a * 255 + 0.5), 24), bit.lshift(c(r), 16), bit.lshift(c(g), 8), c(b))
end

return buffer
