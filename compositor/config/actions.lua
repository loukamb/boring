-- `actions`: ready-made callbacks for shortcuts in configuration files.
--
--   ["Mod4+Return"] = actions.execute("foot"),
--   ["Mod4+q"] = actions.close,
--   ["Super+LeftMouseDrag"] = actions.move_window,
--
-- Functions run when the shortcut fires; strings (move_window, ...) are
-- interpreted by the pointer for mouse shortcuts.

local process = require("compositor.process")

local function boring()
    return require("compositor.api").current()
end

local actions = {}

--- Run a shell command.
function actions.execute(cmd, args)
    return function()
        if args and #args > 0 then
            process.new({ cmd = cmd, args = args }):start()
        else
            process.spawn(cmd)
        end
    end
end

--- Run one of boring's own programs (e.g. "clients.wallpaper").
function actions.start(program, args)
    return function()
        process.new({ program = program, args = args or {} }):start()
    end
end

function actions.exit() boring().exit() end
function actions.reload() boring().reload() end
function actions.close() boring().close_focused() end
function actions.cycle() boring().cycle_focus() end

--- Restart the compositor in place.
function actions.restart()
    process.spawn(string.format("cd '%s' && exec luajit boring.lua", process.cwd()))
    boring().exit()
end

function actions.fullscreen()
    local w = boring().focused()
    if w then boring().layout.toggle_fullscreen(w) end
end

function actions.exit_fullscreen()
    local w = boring().focused()
    if w and w.monitor then boring().layout.exit_fullscreen(w.monitor) end
end

function actions.split_horizontal()
    return boring().layout.split(boring().focused(), "horizontal")
end

function actions.split_vertical()
    return boring().layout.split(boring().focused(), "vertical")
end

-- Mouse actions, handled by compositor/pointer.lua.
actions.move_window = "move_window"
actions.drag_window = "move_window"
actions.resize_window = "resize_window"
actions.toggle_fullscreen = "fullscreen"

return actions
