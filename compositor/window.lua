-- Windows: the one object layouts, plugins and config see for a toplevel,
-- whatever protocol it comes from.
--
-- A window is a plain table. Its methods are shared functions stored on it
-- (no metatable); role-specific behaviour comes from `impl`, provided by the
-- shell that created it (compositor/xdg_shell.lua, plugins/xwayland.lua):
--
--   impl = {
--       role = "toplevel" | "xwayland" | ...,
--       geometry = function() -> x, y, width, height   -- in window-local coordinates
--       set_size = function(width, height)
--       set_activated = function(bool)
--       close = function()
--       title = function() -> string|nil
--       app_id = function() -> string|nil
--       moved = function(x, y)                           -- optional (X11 needs it)
--       set_fullscreen = function(bool)                  -- optional
--       set_maximized = function(bool)                   -- optional
--       set_tiled = function(bool)                       -- optional
--       positioned = true                                -- optional: the client
--                                                        -- picks its position (X11)
--   }
--
-- Where a window goes is up to plugins; core only puts a new window at the
-- origin of the output under the cursor. Plugins may keep their own
-- per-window state in `window.data`.
--
-- `window.props` are properties plugins share, set before the window maps
-- (window:configure, e.g. by the rules plugin) and read by whichever plugin
-- understands them: floating, size = { w, h }, position = { x, y },
-- workspace, output, fullscreen, maximized, border = false, focus = false
-- (don't focus it when it maps). Unknown ones are ignored.

local wl = require("shared.wl")

local window = {}

local next_id = 0

local function position(w)
    local node = w.tree.node
    return node.x, node.y
end

local function set_position(w, x, y)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    w.tree.node:set_position(x, y)
    if w.impl.moved then w.impl.moved(x, y) end
end

--- Window geometry (the part without client-side shadows), relative to
--- the window's scene position: { x, y, width, height }.
local function geometry(w)
    local x, y, width, height = w.impl.geometry()
    return { x = x, y = y, width = width, height = height }
end

--- Size of the window geometry.
local function size(w)
    local _, _, width, height = w.impl.geometry()
    return width, height
end

--- Geometry in layout coordinates.
local function bounds(w)
    local px, py = position(w)
    local x, y, width, height = w.impl.geometry()
    return { x = px + x, y = py + y, width = width, height = height }
end

local function set_size(w, width, height)
    width, height = math.floor(width + 0.5), math.floor(height + 0.5)
    if width < 1 or height < 1 then return end
    w.impl.set_size(width, height)
end

local function set_enabled(w, enabled)
    w.tree.node:set_enabled(enabled)
end

--- Shown (not hidden by a plugin with set_enabled(false)).
local function visible(w)
    return w.tree.node.enabled
end

--- Tell the client it's fullscreen (or not). Where the window goes is the
--- caller's business. Emits window:fullscreen(w).
local function set_fullscreen(w, on)
    on = on and true or false
    if w.fullscreen == on then return end
    w.fullscreen = on
    if w.impl.set_fullscreen then w.impl.set_fullscreen(on) end
    w.server.events:emit("window:fullscreen", w)
end

--- Tell the client it's tiled (or not): it then fills the size it's given
--- exactly instead of rounding it (terminals to whole cells).
local function set_tiled(w, on)
    on = on and true or false
    if w.tiled == on then return end
    w.tiled = on
    if w.impl.set_tiled then w.impl.set_tiled(on) end
end

--- Mark the window as wanting attention (or not). Focusing it clears it.
--- Emits window:urgent(w).
local function set_urgent(w, on)
    on = on and true or false
    if w.urgent == on then return end
    w.urgent = on
    w.server.events:emit("window:urgent", w)
end

--- Tell the client it's maximized (or not). Emits window:maximize(w).
local function set_maximized(w, on)
    on = on and true or false
    if w.maximized == on then return end
    w.maximized = on
    if w.impl.set_maximized then w.impl.set_maximized(on) end
    w.server.events:emit("window:maximize", w)
end

local function raise(w)
    w.tree.node:raise_to_top()
end

local function close(w)
    w.impl.close()
end

local function title(w)
    return w.impl.title and w.impl.title() or nil
end

local function app_id(w)
    return w.impl.app_id and w.impl.app_id() or nil
end

--- Clip the window's surfaces to a box in window-local coordinates (nil to
--- clear). Used by tiling layouts for windows larger than their tile.
local function set_clip(w, box)
    local clip = nil
    if box then
        clip = wl.ffi.new("struct wlr_box", { box.x, box.y, box.width, box.height })
    end
    wl.lib.wlr_scene_subsurface_tree_set_clip(w.tree.node, clip)
end

--- Create a window. Not mapped yet; the shell maps it through
--- compositor/windows.lua when the client is ready.
---@param server table
---@param surface ffi.cdata* struct wlr_surface
---@param tree ffi.cdata* struct wlr_scene_tree holding the window's surfaces
---@param impl table role implementation (see above)
function window.new(server, surface, tree, impl)
    next_id = next_id + 1
    return {
        id = next_id,
        role = impl.role,
        surface = surface,
        tree = tree,
        impl = impl,
        server = server,
        mapped = false,
        activated = false,
        fullscreen = false,
        maximized = false,
        urgent = false,
        props = {},
        data = {},

        position = position,
        set_position = set_position,
        geometry = geometry,
        size = size,
        bounds = bounds,
        set_size = set_size,
        set_enabled = set_enabled,
        visible = visible,
        set_fullscreen = set_fullscreen,
        set_maximized = set_maximized,
        set_tiled = set_tiled,
        set_urgent = set_urgent,
        raise = raise,
        close = close,
        title = title,
        app_id = app_id,
        set_clip = set_clip,
    }
end

return window
