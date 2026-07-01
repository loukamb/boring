-- services/render_service.lua - Render service
--
-- Rendering is handled by wlr_scene.

local wl = require("shared.wayland.server")
local log = require("shared.log")
local ffi = wl._ffi

local core_service = require("compositor.services.core")

local render_service = {
    initialized = false,
}

--------------------------------------------------------------------------------
-- Main Render Entry Point
--------------------------------------------------------------------------------

function render_service:render_output(output)
    if not output or not output.raw then return end

    local surface_service = require("compositor.services.surface")
    local scene = surface_service:get_scene()
    if not scene then return end

    local scene_output = wl.roots.scene_get_scene_output(scene, output:raw())
    if scene_output == nil or scene_output == ffi.NULL then return end

    if not wl.roots.scene_output_commit(scene_output, nil) then
        log.warn("Scene output commit failed")
        return
    end

    local now = wl.get_time()
    wl.roots.scene_output_send_frame_done(scene_output, now)
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function render_service:init()
    if self.initialized then
        return
    end

    self.initialized = true
end

function render_service:get_renderer()
    return core_service:get_renderer()
end

function render_service:shutdown()

end

return render_service
