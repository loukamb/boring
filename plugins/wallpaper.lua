-- plugins/wallpaper.lua
-- Wallpapers: a solid colour drawn in the scene, or an image shown by the
-- wallpaper client (clients/wallpaper.lua, a layer-shell client).
--
--   plugin("@boring/wallpaper"):mount({
--       ["*"] = "#fef3c7",                                  -- every output
--       [monitor] = { image = "/path/to.jpg", scale = "fill" }, -- fill, fit, stretch, center, tile
--   })
--
-- Keys are output names, "*", or monitor objects from monitor.new.

local color = require("shared.color")

local plugin = { name = "wallpaper" }

local DEFAULT = "#1a1a2e"

local function key_name(key)
    if type(key) == "string" then return key end
    if type(key) == "table" then
        if key.get_name then return key:get_name() end
        return key.name
    end
end

local function value_for(config, output_name)
    local wildcard
    for key, value in pairs(config) do
        local name = key_name(key)
        if name == output_name then return value end
        if name == "*" then wildcard = value end
    end
    return wildcard or DEFAULT
end

function plugin:mount(config, ctx)
    local lib = boring.wl.lib
    local scope = ctx.scope
    local per_output = {} -- output -> { rect = scene_rect } or { process = p }

    local function remove(o)
        local entry = per_output[o]
        if not entry then return end
        if entry.rect then entry.rect.node:destroy() end
        if entry.process then entry.process:stop() end
        per_output[o] = nil
    end

    local function place(o)
        local entry = per_output[o]
        if entry and entry.rect then
            local b = o:box()
            entry.rect:set_size(b.width, b.height)
            entry.rect.node:set_position(b.x, b.y)
        end
    end

    local function add(o)
        remove(o)
        local value = value_for(config, o.name)
        if type(value) == "table" and value.image then
            local p = boring.process.new({
                program = "clients.wallpaper",
                args = { "--output=" .. o.name, "--image=" .. value.image, "--scale=" .. (value.scale or "fill") },
            })
            p:start()
            per_output[o] = { process = p }
            return
        end
        local c = color.hex(type(value) == "string" and value or DEFAULT) or color.hex(DEFAULT)
        local rgba = color.float4(c)
        per_output[o] = { rect = lib.wlr_scene_rect_create(boring.layers.background, 1, 1, rgba) }
        place(o)
    end

    for _, o in ipairs(boring.outputs()) do add(o) end
    scope:subscribe(boring.events, "output:add", add)
    scope:subscribe(boring.events, "output:change", place)
    scope:subscribe(boring.events, "output:remove", remove)
    scope:defer(function()
        for o in pairs(per_output) do remove(o) end
    end)
end

return plugin
