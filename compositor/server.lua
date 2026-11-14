-- The server record: every wlroots object the compositor owns, in one plain
-- table that is passed to each module's setup(server). Nothing else holds
-- compositor state; modules don't reach into each other's globals.

local wl = require("shared.wl")
local emitter = require("shared.emitter")
local log = require("shared.log")

local lib, C = wl.lib, wl.C

local server = {}

local function check(ptr, what)
    if ptr == nil then
        error("failed to create " .. what, 2)
    end
    return ptr
end

--- Create the display, backend, renderer, allocator and scene graph.
function server.new()
    lib.wlr_log_init(os.getenv("BORING_DEBUG") and C.WLR_DEBUG or C.WLR_ERROR, nil)

    local s = {
        events = emitter.new(),
        scope = wl.scope.new("server"),
        outputs = {},   -- output records, in creation order
        windows = {},   -- mapped windows, most recently focused first
        surfaces = {},  -- addr(wlr_surface) -> window
        trees = {},     -- addr(window scene tree) -> window, for hit testing
        keyboards = {},
        layers = {},
        running = false,
        -- Hooks protocols fill in (compositor/protocols.lua):
        on_activity = function() end,             -- any input event (idle tracking)
        shortcuts_inhibited = function() return false end,
    }

    s.display = check(lib.wl_display_create(), "wl_display")
    s.event_loop = lib.wl_display_get_event_loop(s.display)
    s.backend = check(lib.wlr_backend_autocreate(s.event_loop, nil), "backend")
    s.renderer = check(lib.wlr_renderer_autocreate(s.backend), "renderer")
    s.renderer:init_wl_display(s.display)
    s.allocator = check(lib.wlr_allocator_autocreate(s.backend, s.renderer), "allocator")
    s.compositor = check(lib.wlr_compositor_create(s.display, 6, s.renderer), "wlr_compositor")

    s.output_layout = check(lib.wlr_output_layout_create(s.display), "output layout")
    s.scene = check(lib.wlr_scene_create(), "scene")
    s.scene_layout = check(lib.wlr_scene_attach_output_layout(s.scene, s.output_layout), "scene layout")

    -- Scene layers, bottom to top: wlr-layer-shell order, X11 popups, lock screen.
    for _, name in ipairs({ "background", "bottom", "windows", "top", "overlay", "unmanaged", "lock" }) do
        s.layers[name] = check(lib.wlr_scene_tree_create(s.scene.tree), "scene layer " .. name)
    end

    return s
end

--- Open the socket and start the backend. Sets WAYLAND_DISPLAY.
function server.start(s)
    local socket = lib.wl_display_add_socket_auto(s.display)
    if socket == nil then
        error("failed to open a Wayland socket")
    end
    s.socket = wl.string(socket)
    if not lib.wlr_backend_start(s.backend) then
        error("failed to start the backend")
    end
    C.setenv("WAYLAND_DISPLAY", s.socket, 1)
    log.info("listening on %s", s.socket)
end

function server.run(s)
    s.running = true
    lib.wl_display_run(s.display)
    s.running = false
end

function server.terminate(s)
    lib.wl_display_terminate(s.display)
end

--- Tear everything down, in reverse order of creation.
function server.destroy(s)
    require("compositor.loop").cancel_all()
    s.scope:close()
    lib.wl_display_destroy_clients(s.display)
    s.scene.tree.node:destroy()
    if s.cursor_mgr ~= nil then lib.wlr_xcursor_manager_destroy(s.cursor_mgr) end
    if s.cursor ~= nil then lib.wlr_cursor_destroy(s.cursor) end
    lib.wlr_allocator_destroy(s.allocator)
    lib.wlr_renderer_destroy(s.renderer)
    lib.wlr_backend_destroy(s.backend)
    lib.wl_display_destroy(s.display)
end

return server
