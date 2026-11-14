-- The `boring` API: what configuration files and plugins use to talk to the
-- compositor. Available as the global `boring` in both.
--
-- Events (boring.events:on(name, fn)):
--   window:map(w)   window:unmap(w)   window:focus(w)   window:blur(w)
--   window:commit(w)                  window:title(w)
--   output:add(o)   output:change(o)  output:remove(o)
--   ready()         shutdown()
--
-- Windows and outputs are the records described in compositor/window.lua and
-- compositor/output.lua.

local wl = require("shared.wl")
local log = require("shared.log")
local registry = require("shared.wayland.registry")
local window = require("compositor.window")
local windows = require("compositor.windows")
local layout = require("compositor.layout")
local pointer = require("compositor.pointer")
local output = require("compositor.output")
local process = require("compositor.process")

local api = {}

local current = nil

local function copy(list)
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    return out
end

--- Build the API for a server and make it current.
function api.create(server)
    local boring = {
        server = server, -- escape hatch: display, seat, compositor, scene, ...
        wl = wl,
        events = server.events,
        layers = server.layers,
        scene = server.scene,
        log = log,
        process = process,
    }

    --- A scope that closes with the compositor (or earlier, if you close it).
    function boring.scope(name)
        return server.scope:child(name)
    end

    -- Windows ---------------------------------------------------------------

    --- Mapped windows, most recently focused first.
    function boring.windows() return copy(server.windows) end
    function boring.focused() return server.focused end
    function boring.focus(w) windows.focus(server, w) end
    function boring.cycle_focus() windows.cycle(server) end
    function boring.window_at(x, y) return (windows.at(server, x, y)) end

    function boring.close_focused()
        if server.focused then server.focused:close() end
    end

    --- For shells implemented as plugins (XWayland): create, map, unmap and
    --- forget windows. See compositor/window.lua for `impl`.
    boring.window = {
        new = function(surface, tree, impl)
            local w = window.new(server, surface, tree, impl)
            windows.register(server, w)
            return w
        end,
        map = function(w) windows.map(server, w) end,
        unmap = function(w) windows.unmap(server, w) end,
        destroy = function(w)
            windows.unmap(server, w)
            windows.unregister(server, w)
        end,
        from_surface = function(surface) return windows.from_surface(server, surface) end,
    }

    -- Outputs ---------------------------------------------------------------

    function boring.outputs() return copy(server.outputs) end
    function boring.output_at(x, y) return output.at(server, x, y) end

    -- Pointer ---------------------------------------------------------------

    function boring.cursor() return server.cursor.x, server.cursor.y end
    function boring.set_cursor(name) pointer.set_cursor(server, name) end
    function boring.begin_move(w) pointer.begin_move(server, w) end
    function boring.begin_resize(w, edges) pointer.begin_resize(server, w, edges) end

    --- Call fn(window, button) when a scene node (or one of its children) is
    --- clicked, e.g. a title bar. Returns a function that removes the handler.
    function boring.on_click(node, fn)
        local key = wl.addr(node)
        server.click_handlers[key] = fn
        return function() server.click_handlers[key] = nil end
    end

    -- Layouts ---------------------------------------------------------------

    boring.layout = {
        register = function(name, impl) layout.register(server, name, impl) end,
        unregister = function(name) layout.unregister(server, name) end,
        monitor_at = function(x, y) return layout.monitor_at(server, x, y) end,
        monitor_for = function(o) return layout.monitor_for(server, o) end,
        enter_fullscreen = layout.enter_fullscreen,
        exit_fullscreen = layout.exit_fullscreen,
        toggle_fullscreen = layout.toggle_fullscreen,
        split = layout.split,
        position_window = layout.position_window,
    }

    -- Compositor ------------------------------------------------------------

    function boring.spawn(cmd) return process.spawn(cmd) end

    function boring.exit()
        process.stop_all()
        require("compositor.server").terminate(server)
    end

    function boring.reload()
        require("compositor.state").reload_config()
        require("compositor.keyboard").reconfigure_all(server)
    end

    --- Mark Wayland interfaces as implemented (for `--protocols`).
    function boring.implement(...)
        for _, name in ipairs({ ... }) do registry.implement(name) end
    end

    current = boring
    return boring
end

--- The API of the running compositor (nil before startup).
function api.current()
    return current
end

return api
