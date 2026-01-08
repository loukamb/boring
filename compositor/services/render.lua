-- services/render_service.lua - Render service
--
-- Rendering is handled by wlr_scene with buffer scaling for zoom.
-- The whiteboard layout sets dest_size on scene buffers to achieve visual zoom.

local wl = require("shared.wayland.server")
local ffi = wl._ffi

local core_service = require("compositor.services.core")

local render_service = {
    initialized = false,
}

--------------------------------------------------------------------------------
-- Main Render Entry Point
--------------------------------------------------------------------------------

function render_service:render_output(output)
    if not output or not output.wlr_output then return end

    local surface_service = require("compositor.services.surface")
    local scene = surface_service:get_scene()
    if not scene then return end

    local scene_output = wl.roots.scene_get_scene_output(scene, output.wlr_output)
    if scene_output == nil or scene_output == ffi.NULL then return end

    -- Use wlr_scene for all rendering
    -- The whiteboard layout sets scene buffer dest_size for zoom scaling
    wl.roots.scene_output_commit(scene_output, nil)

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
