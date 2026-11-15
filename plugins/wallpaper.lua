-- plugins/wallpaper.lua
-- Wallpapers: a solid colour drawn in the scene, or an image shown by the
-- wallpaper client (clients/wallpaper.lua, a layer-shell client).
--
--   plugin("@boring/wallpaper"):mount({
--       ["*"] = "#fef3c7",                                  -- every output
--       [monitor] = { image = "/path/to.jpg", scale = "fill" }, -- fill, fit, stretch, center, tile
--       ["DP-1"] = animate.pulse({ from = "#1e293b", to = "#334155", period = 8000 }),
--   })
--
-- Keys are output names, "*", or monitor objects from monitor.new. Colours
-- can be animations (library/animate).

local color = require("shared.color")
local animate = require("@boring/library/animate")
local scene = require("@boring/library/scene")

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
    local scope = ctx.scope
    local per_output = {} -- output -> { rect = scene rect } or { process = p }

    local function remove(o)
        local entry = per_output[o]
        if not entry then return end
        if entry.binding then animate.stop(entry.binding) end
        if entry.rect then entry.rect:destroy() end
        if entry.process then entry.process:stop() end
        per_output[o] = nil
    end

    local function place(o)
        local entry = per_output[o]
        if entry and entry.rect then
            local b = o:box()
            entry.rect:set_size(b.width, b.height)
            entry.rect:set_position(b.x, b.y)
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
        if type(value) ~= "string" and not animate.is(value) and type(value) ~= "table" then value = DEFAULT end
        local rect = scene.rect(scene.layer("background"), 1, 1, DEFAULT)
        local entry = { rect = rect }
        per_output[o] = entry
        entry.binding = animate.bind(nil, value, function(c)
            rect:set_color(color.parse(c) and c or DEFAULT)
        end)
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
