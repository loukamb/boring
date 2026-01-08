--- Image processing utilities using libvips
---@class shared.image
local ffi = require("ffi")

ffi.cdef [[
typedef struct _VipsImage VipsImage;
typedef struct _VipsObject VipsObject;

typedef enum {
    VIPS_INTERESTING_NONE,
    VIPS_INTERESTING_CENTRE,
    VIPS_INTERESTING_ENTROPY,
    VIPS_INTERESTING_ATTENTION,
    VIPS_INTERESTING_LOW,
    VIPS_INTERESTING_HIGH,
    VIPS_INTERESTING_ALL,
    VIPS_INTERESTING_LAST
} VipsInteresting;

typedef enum {
    VIPS_SIZE_BOTH,
    VIPS_SIZE_UP,
    VIPS_SIZE_DOWN,
    VIPS_SIZE_FORCE,
    VIPS_SIZE_LAST
} VipsSize;

typedef enum {
    VIPS_COMPASS_DIRECTION_CENTRE,
    VIPS_COMPASS_DIRECTION_NORTH,
    VIPS_COMPASS_DIRECTION_EAST,
    VIPS_COMPASS_DIRECTION_SOUTH,
    VIPS_COMPASS_DIRECTION_WEST,
    VIPS_COMPASS_DIRECTION_NORTH_EAST,
    VIPS_COMPASS_DIRECTION_SOUTH_EAST,
    VIPS_COMPASS_DIRECTION_SOUTH_WEST,
    VIPS_COMPASS_DIRECTION_NORTH_WEST,
    VIPS_COMPASS_DIRECTION_LAST
} VipsCompassDirection;

typedef enum {
    VIPS_EXTEND_BLACK,
    VIPS_EXTEND_COPY,
    VIPS_EXTEND_REPEAT,
    VIPS_EXTEND_MIRROR,
    VIPS_EXTEND_WHITE,
    VIPS_EXTEND_BACKGROUND,
    VIPS_EXTEND_LAST
} VipsExtend;

int vips_init(const char *argv0);
void vips_shutdown(void);
const char *vips_error_buffer(void);
void vips_error_clear(void);

VipsImage *vips_image_new_from_file(const char *name, ...);
VipsImage *vips_image_new_from_buffer(const void *buf, size_t len, const char *option_string, ...);

int vips_image_get_width(const VipsImage *image);
int vips_image_get_height(const VipsImage *image);
int vips_image_get_bands(const VipsImage *image);

void *vips_image_write_to_memory(VipsImage *in, size_t *size);
int vips_image_write_to_file(VipsImage *in, const char *name, ...);

int vips_resize(VipsImage *in, VipsImage **out, double scale, ...);
int vips_thumbnail_image(VipsImage *in, VipsImage **out, int width, ...);
int vips_smartcrop(VipsImage *in, VipsImage **out, int width, int height, ...);
int vips_crop(VipsImage *in, VipsImage **out, int left, int top, int width, int height, ...);
int vips_embed(VipsImage *in, VipsImage **out, int x, int y, int width, int height, ...);
int vips_gravity(VipsImage *in, VipsImage **out, int direction, int width, int height, ...);
int vips_replicate(VipsImage *in, VipsImage **out, int across, int down, ...);
int vips_colourspace(VipsImage *in, VipsImage **out, int space, ...);
int vips_flatten(VipsImage *in, VipsImage **out, ...);
int vips_bandjoin_const1(VipsImage *in, VipsImage **out, double c, ...);
int vips_cast(VipsImage *in, VipsImage **out, int bandfmt, ...);

void g_object_unref(void *object);
void g_free(void *mem);
]]
-- Try multiple library names for vips
local vips
local vips_names = { "vips", "libvips.so.42", "libvips.so" }
for _, name in ipairs(vips_names) do
    local ok, lib = pcall(ffi.load, name)
    if ok then
        vips = lib
        break
    end
end
assert(vips, "Could not load libvips (tried: " .. table.concat(vips_names, ", ") .. ")")

local glib = ffi.load("libglib-2.0.so.0")
local gobject = ffi.load("libgobject-2.0.so.0")

local image = {}

---@class Image
---@field _img ffi.cdata* libvips VipsImage pointer
local Image = {}
Image.__index = Image

local initialized = false

local function ensure_init()
    if not initialized then
        assert(vips.vips_init("lwc") == 0, "Failed to initialize libvips: " .. ffi.string(vips.vips_error_buffer()))
        initialized = true
    end
end

local function check_error(result, operation)
    if result ~= 0 then
        local err = ffi.string(vips.vips_error_buffer())
        vips.vips_error_clear()
        error(operation .. " failed: " .. err)
    end
end

local function wrap_image(vips_image)
    if vips_image == nil then
        local err = ffi.string(vips.vips_error_buffer())
        vips.vips_error_clear()
        assert(false, "Failed to create image: " .. err)
    end
    return setmetatable({ _img = vips_image }, Image)
end

---Load an image from a file path
---@param path string Path to the image file
---@return Image Loaded image object
function image.load(path)
    ensure_init()
    local img = vips.vips_image_new_from_file(path, nil)
    return wrap_image(img)
end

---Load an image from a memory buffer
---@param data string|ffi.cdata* Image data
---@param len number|nil Length of data (required if data is not a string)
---@return Image Loaded image object
function image.from_buffer(data, len)
    ensure_init()
    local buf
    if type(data) == "string" then
        buf = data
        len = len or #data
    else
        buf = data
    end
    local img = vips.vips_image_new_from_buffer(buf, len, "", nil)
    return wrap_image(img)
end

---Get image width in pixels
---@return number Width
function Image:width()
    return vips.vips_image_get_width(self._img)
end

---Get image height in pixels
---@return number Height
function Image:height()
    return vips.vips_image_get_height(self._img)
end

---Get number of color bands (channels)
---@return number Number of bands (e.g., 3 for RGB, 4 for RGBA)
function Image:bands()
    return vips.vips_image_get_bands(self._img)
end

---Scale image by a factor
---@param factor number Scale factor (1.0 = original size)
---@return Image Scaled image
function Image:scale(factor)
    local out = ffi.new("VipsImage*[1]")
    local result = vips.vips_resize(self._img, out, factor, nil)
    check_error(result, "scale")
    return wrap_image(out[0])
end

function Image:resize(width, height)
    local src_w, src_h = self:width(), self:height()
    local scale_x = width / src_w
    local scale_y = height / src_h
    local scale = math.max(scale_x, scale_y)
    local scaled = self:scale(scale)
    local scaled_w, scaled_h = scaled:width(), scaled:height()
    if scaled_w == width and scaled_h == height then
        return scaled
    end
    local cropped = scaled:crop(0, 0, math.min(scaled_w, width), math.min(scaled_h, height))
    scaled:free()
    return cropped
end

function Image:thumbnail(width, height)
    local out = ffi.new("VipsImage*[1]")
    local result = vips.vips_thumbnail_image(self._img, out, width, nil)
    check_error(result, "thumbnail")
    return wrap_image(out[0])
end

function Image:crop(left, top, width, height)
    local out = ffi.new("VipsImage*[1]")
    local result = vips.vips_crop(self._img, out, left, top, width, height, nil)
    check_error(result, "crop")
    return wrap_image(out[0])
end

function Image:embed(x, y, width, height)
    local out = ffi.new("VipsImage*[1]")
    local result = vips.vips_embed(self._img, out, x, y, width, height, nil)
    check_error(result, "embed")
    return wrap_image(out[0])
end

function Image:gravity(direction, width, height, extend_mode)
    local dir_enum
    if direction == "north" then
        dir_enum = ffi.C.VIPS_COMPASS_DIRECTION_NORTH
    elseif direction == "south" then
        dir_enum = ffi.C.VIPS_COMPASS_DIRECTION_SOUTH
    elseif direction == "east" then
        dir_enum = ffi.C.VIPS_COMPASS_DIRECTION_EAST
    elseif direction == "west" then
        dir_enum = ffi.C.VIPS_COMPASS_DIRECTION_WEST
    elseif direction == "north-east" then
        dir_enum = ffi.C.VIPS_COMPASS_DIRECTION_NORTH_EAST
    elseif direction == "south-east" then
        dir_enum = ffi.C.VIPS_COMPASS_DIRECTION_SOUTH_EAST
    elseif direction == "south-west" then
        dir_enum = ffi.C.VIPS_COMPASS_DIRECTION_SOUTH_WEST
    elseif direction == "north-west" then
        dir_enum = ffi.C.VIPS_COMPASS_DIRECTION_NORTH_WEST
    else
        dir_enum = ffi.C.VIPS_COMPASS_DIRECTION_CENTRE
    end

    local out = ffi.new("VipsImage*[1]")
    local result = vips.vips_gravity(self._img, out, dir_enum, width, height, nil)
    check_error(result, "gravity")
    return wrap_image(out[0])
end

function Image:replicate(across, down)
    local out = ffi.new("VipsImage*[1]")
    local result = vips.vips_replicate(self._img, out, across, down, nil)
    check_error(result, "replicate")
    return wrap_image(out[0])
end

function Image:smartcrop(width, height, interesting)
    interesting = interesting or "centre"
    local int_enum
    if interesting == "entropy" then
        int_enum = ffi.C.VIPS_INTERESTING_ENTROPY
    elseif interesting == "attention" then
        int_enum = ffi.C.VIPS_INTERESTING_ATTENTION
    else
        int_enum = ffi.C.VIPS_INTERESTING_CENTRE
    end
    local out = ffi.new("VipsImage*[1]")
    local result = vips.vips_smartcrop(self._img, out, width, height, "interesting", int_enum, nil)
    check_error(result, "smartcrop")
    return wrap_image(out[0])
end

function Image:add_alpha()
    if self:bands() >= 4 then
        return self
    end
    local out = ffi.new("VipsImage*[1]")
    local result = vips.vips_bandjoin_const1(self._img, out, 255.0, nil)
    check_error(result, "add_alpha")
    return wrap_image(out[0])
end

function Image:write_to_memory()
    local size = ffi.new("size_t[1]")
    local ptr = vips.vips_image_write_to_memory(self._img, size)
    if ptr == nil then
        local err = ffi.string(vips.vips_error_buffer())
        vips.vips_error_clear()
        assert(false, "write_to_memory failed: " .. err)
    end
    return ptr, tonumber(size[0]), self:width() * self:bands()
end

function Image:free()
    if self._img ~= nil then
        gobject.g_object_unref(self._img)
        self._img = nil
    end
end

function image.free_buffer(ptr)
    if ptr ~= nil then
        glib.g_free(ptr)
    end
end

function image.shutdown()
    if initialized then
        vips.vips_shutdown()
        initialized = false
    end
end

image.VIPS_SIZE_BOTH = "both"
image.VIPS_SIZE_UP = "up"
image.VIPS_SIZE_DOWN = "down"
image.VIPS_SIZE_FORCE = "force"

function image.apply_scale_mode(img, width, height, mode)
    local src_w, src_h = img:width(), img:height()

    if mode == "stretch" then
        return img:resize(width, height)
    elseif mode == "fill" then
        local scale = math.max(width / src_w, height / src_h)
        local scaled = img:scale(scale)
        local sw, sh = scaled:width(), scaled:height()
        local x = math.floor((sw - width) / 2)
        local y = math.floor((sh - height) / 2)
        local cropped = scaled:crop(x, y, width, height)
        scaled:free()
        return cropped
    elseif mode == "fit" then
        local scale = math.min(width / src_w, height / src_h)
        local scaled = img:scale(scale)
        local sw, sh = scaled:width(), scaled:height()
        local x = math.floor((width - sw) / 2)
        local y = math.floor((height - sh) / 2)
        local result = scaled:embed(x, y, width, height)
        scaled:free()
        return result
    elseif mode == "center" then
        if src_w <= width and src_h <= height then
            local x = math.floor((width - src_w) / 2)
            local y = math.floor((height - src_h) / 2)
            return img:embed(x, y, width, height)
        else
            local crop_x = math.max(0, math.floor((src_w - width) / 2))
            local crop_y = math.max(0, math.floor((src_h - height) / 2))
            local crop_w = math.min(src_w, width)
            local crop_h = math.min(src_h, height)
            local cropped = img:crop(crop_x, crop_y, crop_w, crop_h)
            if crop_w < width or crop_h < height then
                local x = math.floor((width - crop_w) / 2)
                local y = math.floor((height - crop_h) / 2)
                local result = cropped:embed(x, y, width, height)
                cropped:free()
                return result
            end
            return cropped
        end
    elseif mode == "tile" then
        local across = math.ceil(width / src_w)
        local down = math.ceil(height / src_h)
        local tiled = img:replicate(across, down)
        local cropped = tiled:crop(0, 0, width, height)
        tiled:free()
        return cropped
    end

    return img:resize(width, height)
end

function image.fill_buffer_image(data, width, height, img, scale_mode)
    local processed = image.apply_scale_mode(img, width, height, scale_mode)
    local with_alpha = processed:add_alpha()
    if with_alpha ~= processed then
        processed:free()
        processed = with_alpha
    end

    local ptr, size, stride = processed:write_to_memory()
    local src = ffi.cast("uint8_t*", ptr)
    local dst = ffi.cast("uint8_t*", data)
    local bands = processed:bands()

    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local src_idx = (y * width + x) * bands
            local dst_idx = (y * width + x) * 4
            local r = src[src_idx + 0]
            local g = src[src_idx + 1]
            local b = src[src_idx + 2]
            local a = bands >= 4 and src[src_idx + 3] or 255
            dst[dst_idx + 0] = b
            dst[dst_idx + 1] = g
            dst[dst_idx + 2] = r
            dst[dst_idx + 3] = a
        end
    end

    image.free_buffer(ptr)
    processed:free()
end

return image
