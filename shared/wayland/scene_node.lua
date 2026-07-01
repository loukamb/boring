local wl = require("shared.wayland.server")
local ffi = wl._ffi

local SceneNode = {}
SceneNode.__index = SceneNode

local function node_ptr(raw)
    if raw == nil or raw == ffi.NULL then
        return nil
    end
    return raw.node or raw
end

function SceneNode.new(raw)
    return setmetatable({ _raw = raw }, SceneNode)
end

function SceneNode:raw()
    return self._raw
end

function SceneNode:node()
    return node_ptr(self._raw)
end

function SceneNode:position()
    local node = self:node()
    if not node then
        return 0, 0
    end
    return node.x, node.y
end

function SceneNode:set_position(x, y)
    local node = self:node()
    if node then
        wl.roots.scene_node_set_position(node, x, y)
    end
end

function SceneNode:set_enabled(enabled)
    local node = self:node()
    if node then
        wl.roots.scene_node_set_enabled(node, enabled)
    end
end

function SceneNode:raise_to_top()
    local node = self:node()
    if node then
        wl.roots.scene_node_raise_to_top(node)
    end
end

function SceneNode:destroy()
    local node = self:node()
    if node then
        wl.roots.scene_node_destroy(node)
    end
    self._raw = nil
end

return SceneNode
