-- Layouts: per-monitor window arrangement, implemented by plugins.
--
-- A layout is a table of functions, called with the layout itself as `self`
-- (so implementations can use `function layout:on_window_add(monitor, w)`).
-- All are optional:
--
--   init(monitor)                    shutdown(monitor)
--   on_window_add(monitor, w)        on_window_remove(monitor, w)
--   position_window(monitor, w)      on_usable_area(monitor)
--   begin_move(monitor, w, x, y)     -> true if the layout handles the grab
--   update_move(monitor, x, y)       end_move(monitor)
--   begin_resize(monitor, w, x, y, edges) -> true if handled
--   update_resize(monitor, x, y)     end_resize(monitor)
--   enter_fullscreen(monitor, w)     exit_fullscreen(monitor)
--   split(monitor, w, "horizontal"|"vertical")
--
-- A monitor is a plain table: { output, layout_name, layout, config, windows,
-- fullscreen_surface }, plus whatever the layout stores on it.

local wl = require("shared.wl")
local log = require("shared.log")

local addr = wl.addr

local layout = {}

local DEFAULT = "stacking"

local function call(monitor, name, ...)
    local impl = monitor.layout
    local fn = impl and impl[name]
    if fn then
        return fn(impl, monitor, ...)
    end
end

local function bind(monitor, impl)
    if monitor.layout then call(monitor, "shutdown") end
    monitor.layout = impl
    if impl then
        call(monitor, "init")
        for _, w in ipairs(monitor.windows) do
            call(monitor, "on_window_add", w)
        end
    end
end

--- Register a layout implementation under a name. Monitors configured for
--- that name (or waiting for the default) pick it up immediately.
function layout.register(server, name, impl)
    server.layouts[name] = impl
    for _, monitor in pairs(server.monitors) do
        if monitor.layout_name == name and monitor.layout ~= impl then
            bind(monitor, impl)
        end
    end
end

function layout.unregister(server, name)
    server.layouts[name] = nil
    for _, monitor in pairs(server.monitors) do
        if monitor.layout_name == name then
            bind(monitor, nil)
        end
    end
end

--- Create layout state for a new output.
function layout.add_monitor(server, output, config)
    config = config or {}
    local name = config.mode or DEFAULT
    local monitor = {
        output = output,
        layout_name = name,
        layout = nil,
        config = {
            gap = config.gap or 4,
            gaps = config.gaps or { inner = 4, outer = 4, smart = true },
        },
        windows = {},
        fullscreen_surface = nil,
    }
    server.monitors[addr(output.wlr)] = monitor
    local impl = server.layouts[name]
    if not impl and name ~= DEFAULT then
        log.warn("layout '%s' isn't registered (yet); windows on %s stay unmanaged", name, output.name)
    end
    bind(monitor, impl)
    return monitor
end

function layout.remove_monitor(server, output)
    local key = addr(output.wlr)
    local monitor = server.monitors[key]
    if not monitor then return end
    call(monitor, "shutdown")
    server.monitors[key] = nil
    -- Move its windows to another monitor.
    local fallback = layout.primary(server)
    for _, w in ipairs(monitor.windows) do
        w.monitor = nil
        if fallback then layout.add_window(server, w, fallback) end
    end
end

function layout.monitor_for(server, output)
    return server.monitors[addr(output.wlr)]
end

--- The monitor of the first output, if any.
function layout.primary(server)
    local output = server.outputs[1]
    return output and server.monitors[addr(output.wlr)] or nil
end

--- The monitor whose output contains a point in layout coordinates.
function layout.monitor_at(server, x, y)
    for _, output in ipairs(server.outputs) do
        local b = output:box()
        if x >= b.x and y >= b.y and x < b.x + b.width and y < b.y + b.height then
            return server.monitors[addr(output.wlr)]
        end
    end
    return layout.primary(server)
end

function layout.add_window(server, w, monitor)
    if not monitor then
        -- New windows open on the monitor under the cursor.
        local cursor = server.cursor
        monitor = cursor ~= nil and layout.monitor_at(server, cursor.x, cursor.y) or layout.primary(server)
    end
    if not monitor then return end
    w.monitor = monitor
    table.insert(monitor.windows, w)
    call(monitor, "on_window_add", w)
end

function layout.remove_window(server, w)
    local monitor = w.monitor
    if not monitor then return end
    if monitor.fullscreen_surface == w then
        monitor.fullscreen_surface = nil
    end
    for i, x in ipairs(monitor.windows) do
        if x == w then
            table.remove(monitor.windows, i)
            break
        end
    end
    call(monitor, "on_window_remove", w)
    w.monitor = nil
end

function layout.position_window(w)
    if w.monitor then call(w.monitor, "position_window", w) end
end

--- Tell the layout its output's usable area changed (panels, resolution).
function layout.usable_area_changed(server, output)
    local monitor = server.monitors[addr(output.wlr)]
    if monitor then call(monitor, "on_usable_area") end
end

function layout.begin_move(w, x, y)
    return w.monitor ~= nil and call(w.monitor, "begin_move", w, x, y) == true
end

function layout.update_move(monitor, x, y) call(monitor, "update_move", x, y) end
function layout.end_move(monitor) call(monitor, "end_move") end

function layout.begin_resize(w, x, y, edges)
    return w.monitor ~= nil and call(w.monitor, "begin_resize", w, x, y, edges) == true
end

function layout.update_resize(monitor, x, y) call(monitor, "update_resize", x, y) end
function layout.end_resize(monitor) call(monitor, "end_resize") end

function layout.enter_fullscreen(w)
    local monitor = w.monitor
    if not monitor then return false end
    if monitor.fullscreen_surface and monitor.fullscreen_surface ~= w then
        layout.exit_fullscreen(monitor)
    end
    if call(monitor, "enter_fullscreen", w) then
        monitor.fullscreen_surface = w
        if w.impl.set_fullscreen then w.impl.set_fullscreen(true) end
        return true
    end
    return false
end

function layout.exit_fullscreen(monitor)
    local w = monitor and monitor.fullscreen_surface
    if not w then return false end
    call(monitor, "exit_fullscreen")
    monitor.fullscreen_surface = nil
    if w.impl.set_fullscreen then w.impl.set_fullscreen(false) end
    return true
end

function layout.toggle_fullscreen(w)
    if w.monitor and w.monitor.fullscreen_surface == w then
        return layout.exit_fullscreen(w.monitor)
    end
    return layout.enter_fullscreen(w)
end

function layout.split(w, direction)
    if w and w.monitor then
        return call(w.monitor, "split", w, direction) == true
    end
    return false
end

return layout
