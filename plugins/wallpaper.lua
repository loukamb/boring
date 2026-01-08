-- plugins/wallpaper.lua
-- Native wallpaper plugin - renders directly in compositor scene graph
-- For color wallpapers: uses wlr_scene_rect (native)
-- For image wallpapers: starts the wallpaper client (Wayland client)

local log = require("shared.log")
local wl = require("shared.wayland.server")
local color = require("shared.color")
local process = require("compositor.process")
local ffi = wl._ffi

local plugin = {
    name = "wallpaper",
}

-- State
local background_nodes = {}    -- wlr_output -> { type = "rect"|"client", node = scene_node, process = Process }
local config_cache = nil
local wallpaper_processes = {} -- track client processes

-- Parse color to RGBA float array (0-1 range) for wlroots
local function parse_color(value)
    if type(value) == "string" and value:sub(1, 1) == "#" then
        local c = color.hex(value)
        if c then
            return ffi.new("float[4]", c)
        end
    elseif type(value) == "table" then
        return ffi.new("float[4]", value) -- Already a float array
    end
    -- Default dark gray
    return ffi.new("float[4]", { 0.2, 0.2, 0.2, 1.0 })
end

-- Start wallpaper client for an output with image config
local function start_wallpaper_client(output_name, image_path, scale_mode)
    local p = process.new({ program = "clients.wallpaper" })
    -- Args parser expects --key=value format
    p:set_args({
        string.format("--output=%s", output_name),
        string.format("--image=%s", image_path),
        string.format("--scale=%s", scale_mode or "fill"),
    })

    if p:start_local() then
        table.insert(wallpaper_processes, p)
        return p
    else
        log.error("Failed to start wallpaper client for %s", output_name)
        return nil
    end
end

-- Cleanup existing wallpaper for an output
local function cleanup_wallpaper(wlr_output)
    local existing = background_nodes[wlr_output]
    if existing then
        if existing.node then
            wl.roots.scene_node_destroy(existing.node)
        end
        if existing.process and existing.process:is_running() then
            existing.process:stop()
        end
        background_nodes[wlr_output] = nil
    end
end

-- Create or update wallpaper for an output
local function update_wallpaper_for_output(wlr_output, output_name)
    local surface_service = require("compositor.services.surface")
    local output_service = require("compositor.services.output")

    -- Get output dimensions
    local width, height = output_service:get_output_dimensions(wlr_output)
    if not width or width <= 0 then
        width = 1920
        height = 1080
    end

    -- Find config for this output
    local wallpaper_value = nil
    if config_cache then
        for key, value in pairs(config_cache) do
            local key_name = nil
            if type(key) == "table" and key.name then
                key_name = key.name
            elseif type(key) == "table" and key.get_name then
                key_name = key:get_name()
            elseif type(key) == "string" then
                key_name = key
            end

            if key_name == "*" or key_name == output_name then
                wallpaper_value = value
                break
            end
        end
    end

    -- Remove existing wallpaper
    cleanup_wallpaper(wlr_output)

    -- Get output position
    local ox, oy = output_service:get_output_position(wlr_output)
    ox = ox or 0
    oy = oy or 0

    -- Handle image wallpaper -> use client
    if type(wallpaper_value) == "table" and wallpaper_value.image then
        local scale_mode = wallpaper_value.scale or "fill"
        local p = start_wallpaper_client(output_name, wallpaper_value.image, scale_mode)
        if p then
            background_nodes[wlr_output] = { type = "client", process = p }
        end
        return
    end

    -- Handle color wallpaper -> use native scene rect
    if type(wallpaper_value) == "string" and wallpaper_value:sub(1, 1) == "#" then
        local rgba = parse_color(wallpaper_value)
        local rect = wl.roots.scene_rect_create(
            surface_service.layers.background,
            width, height, rgba
        )
        if rect and rect ~= ffi.NULL then
            wl.roots.scene_node_set_position(rect.node, ox, oy)
            background_nodes[wlr_output] = { type = "rect", node = rect.node }
        end
        return
    end

    -- Default dark background (native)
    local rgba = parse_color("#1a1a2e")
    local rect = wl.roots.scene_rect_create(
        surface_service.layers.background,
        width, height, rgba
    )
    if rect and rect ~= ffi.NULL then
        wl.roots.scene_node_set_position(rect.node, ox, oy)
        background_nodes[wlr_output] = { type = "rect", node = rect.node }
    end
end

function plugin:mount(config)
    config_cache = config

    local output_service = require("compositor.services.output")
    local core_service = require("compositor.services.core")

    -- Subscribe to compositor:ready to create wallpapers after outputs exist
    self._ready_listener = core_service.events:on("compositor:ready", function()
        -- Create wallpapers for existing outputs
        local outputs = output_service:get_outputs()
        for _, output in ipairs(outputs) do
            local output_name = ffi.string(output.wlr_output.name)
            update_wallpaper_for_output(output.wlr_output, output_name)
        end
    end)

    -- Listen for new outputs
    self._output_add_listener = output_service.events:on("output:add", function(wlr_output, name)
        update_wallpaper_for_output(wlr_output, name)
    end)

    -- Listen for output removal
    self._output_remove_listener = output_service.events:on("output:remove", function(wlr_output)
        cleanup_wallpaper(wlr_output)
    end)

    return {}
end

function plugin:unmount()
    -- Clean up listeners
    if self._ready_listener and self._ready_listener.off then
        self._ready_listener:off()
    end
    if self._output_add_listener and self._output_add_listener.off then
        self._output_add_listener:off()
    end
    if self._output_remove_listener and self._output_remove_listener.off then
        self._output_remove_listener:off()
    end

    -- Destroy background nodes and stop client processes
    for wlr_output, entry in pairs(background_nodes) do
        if entry.node then
            wl.roots.scene_node_destroy(entry.node)
        end
        if entry.process and entry.process:is_running() then
            entry.process:stop()
        end
    end
    background_nodes = {}

    -- Stop any remaining wallpaper processes
    for _, p in ipairs(wallpaper_processes) do
        if p:is_running() then
            p:stop()
        end
    end
    wallpaper_processes = {}

    config_cache = nil
end

return plugin
