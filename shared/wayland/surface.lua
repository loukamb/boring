local wl = require("shared.wayland.server")
local ffi = wl._ffi
local Box = require("shared.wayland.box")
local SceneNode = require("shared.wayland.scene_node")
local Scope = require("shared.scope")

local Surface = {}
Surface.__index = Surface

function Surface.new(args)
    args = args or {}
    local id = args.wlr_surface and tostring(wl.ptr_to_num(args.wlr_surface)) or "0"
    return setmetatable({
        id = id,
        _wlr_surface = args.wlr_surface,
        _role = args.role,
        _role_obj = args.role_obj,
        _scene_tree = args.scene_tree,
        _monitor_state = nil,
        _scope = args.scope or Scope.new(args.role or "surface"),
        mapped = false,
        activated = false,
    }, Surface)
end

function Surface:raw()
    return self._wlr_surface
end

function Surface:role()
    return self._role
end

function Surface:set_role(role, role_obj, scene_tree)
    self._role = role
    self._role_obj = role_obj
    self._scene_tree = scene_tree
end

function Surface:role_object()
    return self._role_obj
end

function Surface:scene_tree()
    return self._scene_tree
end

function Surface:scene_node()
    if not self._scene_tree then
        return nil
    end
    return SceneNode.new(self._scene_tree)
end

function Surface:position()
    local node = self:scene_node()
    if not node then
        return 0, 0
    end
    return node:position()
end

function Surface:set_position(x, y)
    local node = self:scene_node()
    if node then
        node:set_position(x, y)
    end
end

function Surface:set_enabled(enabled)
    local node = self:scene_node()
    if node then
        node:set_enabled(enabled)
    end
end

function Surface:raise_to_top()
    local node = self:scene_node()
    if node then
        node:raise_to_top()
    end
end

function Surface:geometry()
    local role = self._role_obj
    if self._role == "xwayland" and role and role ~= ffi.NULL then
        return Box.new(0, 0, role.width or 0, role.height or 0)
    end
    if role and role ~= ffi.NULL and role.base then
        local geo = (role.base.current and role.base.current.geometry) or role.base.geometry
        if geo then
            return Box.from_wlr(geo)
        end
    end
    if self._wlr_surface and self._wlr_surface ~= ffi.NULL then
        local current = self._wlr_surface.current
        if current then
            return Box.new(0, 0, current.width, current.height)
        end
    end
    return Box.new()
end

function Surface:full_bounds()
    local x, y = self:position()
    local geo = self:geometry()
    return Box.new(x + geo.x, y + geo.y, geo.width, geo.height)
end

function Surface:set_size(width, height)
    if self._role == "toplevel" and self._role_obj then
        wl.roots.xdg_toplevel_set_size(self._role_obj, width, height)
    elseif self._role == "xwayland" and self._role_obj and wl.roots.xwayland_surface_configure then
        local x, y = self:position()
        wl.roots.xwayland_surface_configure(self._role_obj, x, y, width, height)
    end
end

function Surface:close()
    if self._role == "toplevel" and self._role_obj then
        wl.roots.xdg_toplevel_send_close(self._role_obj)
    elseif self._role == "xwayland" and self._role_obj and wl.roots.xwayland_surface_close then
        wl.roots.xwayland_surface_close(self._role_obj)
    end
end

function Surface:set_activated(activated)
    if self._role == "toplevel" and self._role_obj then
        wl.roots.xdg_toplevel_set_activated(self._role_obj, activated)
    end
    self.activated = activated
end

function Surface:scope()
    return self._scope
end

function Surface:monitor_state()
    return self._monitor_state
end

function Surface:set_monitor_state(monitor_state)
    self._monitor_state = monitor_state
end

function Surface:close_scope()
    self._scope:close()
end

return Surface
