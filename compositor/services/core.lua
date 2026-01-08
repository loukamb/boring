-- services/core.lua - The universe container
-- Responsibility: wl_display, event_loop, backend, allocator, renderer

local wl = require("shared.wayland.server")
local events_mod = require("shared.events")
local ffi = wl._ffi

local core_service = {
    -- Core Wayland objects
    wl_display = nil,
    event_loop = nil,
    backend = nil,
    renderer = nil,
    allocator = nil,
    compositor = nil, -- wlr_compositor for XWayland

    -- Listeners (stored to prevent GC)
    listeners = {},

    -- State
    initialized = false,
    running = false,
    socket_name = nil,

    -- Events for plugins
    events = events_mod.new(),
}

-- Initialize the core Wayland infrastructure
function core_service:init()
    if self.initialized then
        return
    end


    -- Initialize wlroots logging
    wl.roots.log_init(wl.WLR_DEBUG, nil)

    -- Create Wayland display
    self.wl_display = wl.display_create()
    assert(self.wl_display ~= nil and self.wl_display ~= ffi.NULL, "Failed to create wl_display")

    -- Get event loop
    self.event_loop = wl.display_get_event_loop(self.wl_display)

    -- Create backend
    self.backend = wl.roots.backend_autocreate(self.event_loop, nil)
    assert(self.backend ~= nil and self.backend ~= ffi.NULL, "Failed to create backend")

    -- Create renderer
    self.renderer = wl.roots.renderer_autocreate(self.backend)
    assert(self.renderer ~= nil and self.renderer ~= ffi.NULL, "Failed to create renderer")
    wl.roots.renderer_init_wl_display(self.renderer, self.wl_display)

    -- Create allocator
    self.allocator = wl.roots.allocator_autocreate(self.backend, self.renderer)
    assert(self.allocator ~= nil and self.allocator ~= ffi.NULL, "Failed to create allocator")

    -- Create compositor interfaces
    self.compositor = wl.roots.compositor_create(self.wl_display, 5, self.renderer)
    wl.roots.subcompositor_create(self.wl_display)
    wl.roots.data_device_manager_create(self.wl_display)

    self.initialized = true
end

-- Start the backend and add socket
function core_service:start(startup_cmd)
    assert(self.initialized, "core_service not initialized")

    -- Add socket
    local socket = wl.display_add_socket_auto(self.wl_display)
    assert(socket ~= nil and socket ~= ffi.NULL, "Failed to add socket")
    self.socket_name = ffi.string(socket)


    -- Start backend
    assert(wl.roots.backend_start(self.backend), "Failed to start backend")

    -- Set WAYLAND_DISPLAY environment variable
    wl.setenv("WAYLAND_DISPLAY", self.socket_name)

    -- Launch startup command if provided
    if startup_cmd then
        wl.fork_exec(startup_cmd)
    end
end

-- Run the event loop
function core_service:run()
    assert(self.initialized, "core_service not initialized")

    self.running = true
    wl.display_run(self.wl_display)
    self.running = false
end

-- Terminate the event loop
function core_service:terminate()
    -- Stop all processes we started (graceful shutdown)
    local process = require("compositor.process")
    process.stop_all()

    if self.wl_display then
        wl.display_terminate(self.wl_display)
    end
end

-- Shutdown and cleanup
function core_service:shutdown()
    if self.wl_display then
        wl.display_destroy_clients(self.wl_display)
    end

    if self.allocator then
        wl.roots.allocator_destroy(self.allocator)
        self.allocator = nil
    end

    if self.renderer then
        wl.roots.renderer_destroy(self.renderer)
        self.renderer = nil
    end

    if self.backend then
        wl.roots.backend_destroy(self.backend)
        self.backend = nil
    end

    if self.wl_display then
        wl.display_destroy(self.wl_display)
        self.wl_display = nil
    end

    self.initialized = false
end

-- Getters for other services
function core_service:get_display()
    return self.wl_display
end

function core_service:get_backend()
    return self.backend
end

function core_service:get_renderer()
    return self.renderer
end

function core_service:get_allocator()
    return self.allocator
end

function core_service:get_event_loop()
    return self.event_loop
end

function core_service:get_socket_name()
    return self.socket_name
end

return core_service
