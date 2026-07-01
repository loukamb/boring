local ffi = require("ffi")
local wl = require("shared.wayland.client")
local proto = require("shared.wayland.registry")
local log = require("shared.log")
local image = require("shared.image")
local color = require("shared.color")

local layer_shell_layer = proto.enum("zwlr_layer_shell_v1").layer
local layer_surface_anchor = proto.enum("zwlr_layer_surface_v1").anchor

local state = {
    display = nil,
    registry = nil,
    compositor = nil,
    shm = nil,
    layer_shell = nil,
    outputs = {},
    surfaces = {},
    running = true,
    config = {
        output = "*",
        image = nil,
        color = "#000000",
        scale = "fill",
    },
    loaded_image = nil,
}

local function parse_args(args)
    if args.output then
        state.config.output = args.output
    end
    if args.image then
        state.config.image = args.image
    end
    if args.color then
        state.config.color = args.color
    end
    if args.scale then
        state.config.scale = args.scale
    end
end

local function load_image(path)
    local ok, img = pcall(image.load, path)
    if not ok then
        log.error("Failed to load image: %s - %s", path, img)
        return nil
    end

    return img
end

local function fill_buffer_color(data, width, height, r, g, b, a)
    local pixels = ffi.cast("uint32_t*", data)
    local color = wl.bit.bor(
        wl.bit.lshift(a, 24),
        wl.bit.lshift(r, 16),
        wl.bit.lshift(g, 8),
        b
    )
    for i = 0, width * height - 1 do
        pixels[i] = color
    end
end

local function fill_buffer_image(data, width, height, img, scale_mode)
    image.fill_buffer_image(data, width, height, img, scale_mode)
end

local function create_surface_for_output(output_data)
    if not state.layer_shell or not state.compositor or not state.shm then
        log.warn("Missing globals for surface creation")
        return
    end

    local surface = wl.compositor_create_surface(state.compositor)
    if wl.is_null(surface) then
        log.error("Failed to create surface")
        return
    end

    local layer_surface = wl.layer_shell_get_layer_surface(
        state.layer_shell,
        surface,
        output_data.output,
        layer_shell_layer.background,
        "wallpaper"
    )
    if wl.is_null(layer_surface) then
        log.error("Failed to create layer surface")
        return
    end

    local anchor = wl.bit.bor(
        layer_surface_anchor.top,
        layer_surface_anchor.bottom,
        layer_surface_anchor.left,
        layer_surface_anchor.right
    )
    wl.layer_surface_set_anchor(layer_surface, anchor)
    wl.layer_surface_set_exclusive_zone(layer_surface, -1)

    local surf_data = {
        surface = surface,
        layer_surface = layer_surface,
        output = output_data,
        width = 0,
        height = 0,
        configured = false,
        buffer = nil,
        buffer_data = nil,
        buffer_size = nil,
    }

    local function cleanup_buffer()
        if surf_data.buffer then
            wl.buffer_destroy(surf_data.buffer)
            surf_data.buffer = nil
        end
        if surf_data.buffer_data and surf_data.buffer_size then
            ffi.C.munmap(surf_data.buffer_data, surf_data.buffer_size)
            surf_data.buffer_data = nil
            surf_data.buffer_size = nil
        end
    end

    local configure_cb = wl.persistent_callback(
        "void(*)(void*, struct zwlr_layer_surface_v1*, uint32_t, uint32_t, uint32_t)",
        function(data, ls, serial, width, height)
            surf_data.width = width
            surf_data.height = height
            surf_data.configured = true
            wl.layer_surface_ack_configure(ls, serial)

            cleanup_buffer()

            local buffer, buf_data, buf_size = wl.create_shm_buffer(state.shm, width, height, wl.WL_SHM_FORMAT_ARGB8888)
            if buffer and buf_data then
                surf_data.buffer = buffer
                surf_data.buffer_data = buf_data
                surf_data.buffer_size = buf_size

                if state.loaded_image then
                    fill_buffer_image(buf_data, width, height, state.loaded_image, state.config.scale)
                else
                    local c = color.hex(state.config.color)
                    if c then
                        local r, g, b, a = color.to_int(c)
                        fill_buffer_color(buf_data, width, height, r, g, b, a)
                    else
                        fill_buffer_color(buf_data, width, height, 0, 0, 0, 255)
                    end
                end

                wl.surface_attach(surf_data.surface, buffer, 0, 0)
                wl.surface_damage(surf_data.surface, 0, 0, width, height)
                wl.surface_commit(surf_data.surface)
            end
        end
    )

    local closed_cb = wl.persistent_callback(
        "void(*)(void*, struct zwlr_layer_surface_v1*)",
        function(data, ls)
            cleanup_buffer()
            state.running = false
        end
    )

    local listener = ffi.new("struct zwlr_layer_surface_v1_listener")
    listener.configure = configure_cb
    listener.closed = closed_cb
    table.insert(wl._prevent_gc, listener)

    wl.layer_surface_add_listener(layer_surface, listener, nil)

    wl.surface_commit(surface)
    wl.display_roundtrip(state.display)

    table.insert(state.surfaces, surf_data)
end

local function handle_global(data, registry, name, interface, version)
    local iface = wl.string(interface)

    if iface == "wl_compositor" then
        local proxy = wl.registry_bind(registry, name, wl._wl.wl_compositor_interface, 4)
        state.compositor = ffi.cast("struct wl_compositor*", proxy)
    elseif iface == "wl_shm" then
        local proxy = wl.registry_bind(registry, name, wl._wl.wl_shm_interface, 1)
        state.shm = ffi.cast("struct wl_shm*", proxy)
    elseif iface == "zwlr_layer_shell_v1" then
        local proxy = wl.registry_bind(registry, name, wl.zwlr_layer_shell_v1_interface, 4)
        state.layer_shell = ffi.cast("struct zwlr_layer_shell_v1*", proxy)
    elseif iface == "wl_output" then
        local proxy = wl.registry_bind(registry, name, wl._wl.wl_output_interface, 1)
        local output = ffi.cast("struct wl_output*", proxy)
        table.insert(state.outputs, { output = output, name = name })
    end
end

local function handle_global_remove(data, registry, name)
    for i, out in ipairs(state.outputs) do
        if out.name == name then
            table.remove(state.outputs, i)

            break
        end
    end
end

local function main(args)
    parse_args(args)







    if state.config.image then
        state.loaded_image = load_image(state.config.image)
        if not state.loaded_image then
            log.warn("Failed to load image, falling back to color")
        end
    end

    state.display = wl.display_connect(nil)
    if wl.is_null(state.display) then
        log.error("Failed to connect to Wayland display")
        return 1
    end


    state.registry = wl.display_get_registry(state.display)
    if wl.is_null(state.registry) then
        log.error("Failed to get registry")
        return 1
    end

    local global_cb = wl.persistent_callback(
        "void(*)(void*, struct wl_registry*, uint32_t, const char*, uint32_t)",
        handle_global
    )
    local global_remove_cb = wl.persistent_callback(
        "void(*)(void*, struct wl_registry*, uint32_t)",
        handle_global_remove
    )

    local registry_listener = ffi.new("struct wl_registry_listener")
    registry_listener.global = global_cb
    registry_listener.global_remove = global_remove_cb
    table.insert(wl._prevent_gc, registry_listener)

    wl.registry_add_listener(state.registry, registry_listener, nil)
    wl.display_roundtrip(state.display)

    if not state.layer_shell then
        log.error("Compositor does not support wlr-layer-shell")
        return 1
    end

    if not state.compositor then
        log.error("Compositor does not export wl_compositor")
        return 1
    end

    if not state.shm then
        log.error("Compositor does not export wl_shm")
        return 1
    end

    for _, output_data in ipairs(state.outputs) do
        if state.config.output == "*" then
            create_surface_for_output(output_data)
        end
    end

    wl.display_roundtrip(state.display)
    while state.running do
        if wl.display_dispatch(state.display) < 0 then
            break
        end
    end

    if state.loaded_image then
        state.loaded_image:free()
    end
    for _, surf_data in ipairs(state.surfaces) do
        if surf_data.buffer then
            wl.buffer_destroy(surf_data.buffer)
        end
        if surf_data.buffer_data and surf_data.buffer_size then
            ffi.C.munmap(surf_data.buffer_data, surf_data.buffer_size)
        end
    end
    wl.display_disconnect(state.display)

    return 0
end

return main
