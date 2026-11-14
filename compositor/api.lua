-- The `boring` API: what configuration files and plugins use to talk to the
-- compositor. Available as the global `boring` in both.
--
-- Events (boring.events:on(name, fn)):
--   window:map(w)   window:unmap(w)   window:focus(w)   window:blur(w)
--   window:commit(w)                  window:title(w)
--   window:fullscreen(w)              window:maximize(w)   (state changed)
--   output:add(o)   output:change(o)  output:usable(o)     output:remove(o)
--   ready()         shutdown()
--
-- What clients (or mouse shortcuts and actions) ask for; plugins that
-- manage windows answer them, core does nothing on its own:
--   window:request_move(w)            window:request_resize(w, edges)
--   window:request_fullscreen(w, on)  window:request_maximize(w, on)
--   window:request_minimize(w)
--   window:request_geometry(w, box)   (X11 windows asking for a place and size)
--
-- Windows and outputs are the records described in compositor/window.lua and
-- compositor/output.lua.

local wl = require("shared.wl")
local log = require("shared.log")
local registry = require("shared.wayland.registry")
local window = require("compositor.window")
local windows = require("compositor.windows")
local pointer = require("compositor.pointer")
local output = require("compositor.output")
local process = require("compositor.process")
local timer = require("compositor.timer")

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
    function boring.blur() windows.blur(server) end
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
    --- Free move/resize: the window follows the pointer until the button
    --- is released.
    function boring.begin_move(w) pointer.begin_move(server, w) end
    function boring.begin_resize(w, edges) pointer.begin_resize(server, w, edges) end

    --- Take the pointer: { motion = fn(x, y), button = fn(button, pressed)
    --- -> true to end, finish = fn(cancelled), cursor = name, window = w }.
    --- Without `button`, releasing a button ends the grab. Returns a
    --- function that ends it.
    function boring.grab_pointer(handlers) return pointer.grab(server, handlers) end

    --- The cursor name for resizing by `edges` ("se-resize", ...).
    boring.resize_cursor = pointer.resize_cursor

    --- Call fn(window, button) when a scene node (or one of its children) is
    --- clicked, e.g. a title bar. Returns a function that removes the handler.
    function boring.on_click(node, fn)
        local key = wl.addr(node)
        server.click_handlers[key] = fn
        return function() server.click_handlers[key] = nil end
    end

    -- Compositor ------------------------------------------------------------

    function boring.spawn(cmd) return process.spawn(cmd) end

    --- Run fn after `ms` milliseconds; if it returns a number, again after
    --- that many. Returns a function that cancels it.
    function boring.after(ms, fn) return timer.after(server, ms, fn) end

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
