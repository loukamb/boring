local wl = require("shared.wayland.server")
local Box = require("shared.wayland.box")
local Scope = require("shared.scope")

local Output = {}
Output.__index = Output

function Output.find_mode(wlr_output, width, height, refresh_rate)
    if not width or not height then
        return nil
    end

    local modes = wl._ffi.cast("struct wl_list*",
        wl._ffi.cast("char*", wlr_output) + wl.offsetof("struct wlr_output", "modes"))
    local pos = modes.next
    while pos ~= nil and pos ~= wl._ffi.NULL and wl.ptr_to_num(pos) ~= wl.ptr_to_num(modes) do
        local mode = wl.container_of(pos, "struct wlr_output_mode", "link")
        if mode.width == width and mode.height == height then
            if not refresh_rate or refresh_rate == 0 or mode.refresh == refresh_rate * 1000 then
                return mode
            end
        end
        pos = pos.next
    end

    return nil
end

function Output.new(args)
    args = args or {}
    return setmetatable({
        _wlr_output = assert(args.wlr_output, "Output requires wlr_output"),
        _layout = args.output_layout,
        _layout_output = args.layout_output,
        _scene_output = args.scene_output,
        _scope = args.scope or Scope.new(args.name or "output"),
        name = args.name,
    }, Output)
end

function Output:raw()
    return self._wlr_output
end

function Output:scope()
    return self._scope
end

function Output:layout_output()
    return self._layout_output
end

function Output:set_layout_output(layout_output)
    self._layout_output = layout_output
end

function Output:scene_output()
    return self._scene_output
end

function Output:set_scene_output(scene_output)
    self._scene_output = scene_output
end

function Output:dimensions()
    local output = self._wlr_output
    if output and wl.roots.output_effective_resolution then
        local width = wl._ffi.new("int[1]")
        local height = wl._ffi.new("int[1]")
        local ok = pcall(wl.roots.output_effective_resolution, output, width, height)
        if ok and width[0] > 0 and height[0] > 0 then
            return width[0], height[0]
        end
    end
    return output.width, output.height
end

function Output:position()
    if not self._layout then
        return 0, 0
    end
    local box = Box.new():to_wlr()
    wl.roots.output_layout_get_box(self._layout, self._wlr_output, box)
    return box.x, box.y
end

function Output:box()
    local x, y = self:position()
    local width, height = self:dimensions()
    return Box.new(x, y, width, height)
end

function Output:close()
    self._scope:close()
end

return Output
