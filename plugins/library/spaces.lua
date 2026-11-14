-- plugins/library/spaces.lua
-- Spaces: areas of an output, the windows in them and how they're arranged.
--
--   local spaces = require("@boring/library/spaces")
--   local unregister = spaces.register("tiling", arrangement, { outputs = { "DP-1" } })
--
-- Core doesn't manage windows; this library is how the layout plugins do.
-- Every output gets a space when it appears; more can be added (that's what
-- `library/workspaces` does), and one per output is shown. A window belongs
-- to one space, the shown space of the output it opened on.
--
-- An arrangement is a table of optional functions, called with the
-- arrangement as `self`:
--
--   init(space)            shutdown(space)     -- bound to / unbound from a space
--   add(space, w)          remove(space, w)    -- a window joins / leaves it
--   arrange(space)                             -- usable area changed, fullscreen ended
--   commit(space, w)                           -- the window committed (new size)
--   move(space, w)         resize(space, w, edges)
--                                              -- the window asks to be moved/resized;
--                                              -- without these it follows the pointer
--
-- Fullscreen and minimize are the same for every arrangement. A fullscreen
-- window fills its output (library/fullscreen) until it leaves fullscreen,
-- and then the arrangement re-arranges. A minimized window is hidden and
-- taken out of the arrangement (`remove`) until it's focused again (a
-- taskbar activating it, or spaces.minimize(w, false)).
--
-- A space is a plain table:
--   { output, name, windows = { ... }, shown, fullscreen = w|nil,
--     minimized = { [w] = true }, arrangement = name|nil,
--     impl = arrangement|nil, data = {} }
-- `windows` includes minimized ones; arrangements see the others (`add` is
-- only called for those, and `spaces.arranged(space)` lists them). They
-- keep per-space state in `space.data`, and can tell their windows by
-- `spaces.of(w).impl == self`.
--
-- Which arrangement a space uses: the one registered for its output's name,
-- else one registered for every output; the last registered wins. A space
-- can also be given one by name (`spaces.set_arrangement`).
--
-- Events on boring.events: space:add(space), space:remove(space),
-- space:show(space), space:window(w, space) (a window changed space).

local fullscreen = require("@boring/library/fullscreen")

local spaces = {}

local scope = boring.scope("spaces")

local registered = {}  -- list of { name, impl, outputs = set|nil }
local outputs = {}     -- output -> { list = { space, ... }, shown = space }
local by_window = {}   -- window -> space

--------------------------------------------------------------------------------
-- Arrangements
--------------------------------------------------------------------------------

local function call(space, name, ...)
    local impl = space.impl
    local fn = impl and impl[name]
    if fn then return fn(impl, space, ...) end
end

local function entry_for(space)
    if space.arrangement then
        for i = #registered, 1, -1 do
            if registered[i].name == space.arrangement then return registered[i] end
        end
        return nil
    end
    local name = space.output.name
    for i = #registered, 1, -1 do
        local e = registered[i]
        if e.outputs and e.outputs[name] then return e end
    end
    for i = #registered, 1, -1 do
        if not registered[i].outputs then return registered[i] end
    end
end

local function bind(space)
    local entry = entry_for(space)
    local impl = entry and entry.impl
    if space.impl == impl then return end
    if space.impl then call(space, "shutdown") end
    space.impl = impl
    space.data = {}
    if impl then
        call(space, "init")
        for _, w in ipairs(space.windows) do
            if not space.minimized[w] then call(space, "add", w) end
        end
    end
end

local function all_spaces()
    local list = {}
    for _, o in ipairs(boring.outputs()) do
        local s = outputs[o]
        if s then
            for _, space in ipairs(s.list) do list[#list + 1] = space end
        end
    end
    return list
end

local function rebind_all()
    for _, space in ipairs(all_spaces()) do bind(space) end
end

--- Register an arrangement under a name. `opts.outputs` limits it to
--- outputs by name (default: every output). Returns a function that
--- unregisters it.
function spaces.register(name, impl, opts)
    local set = nil
    if opts and opts.outputs and opts.outputs ~= "*" then
        set = {}
        for _, n in ipairs(type(opts.outputs) == "table" and opts.outputs or { opts.outputs }) do set[n] = true end
    end
    local entry = { name = name, impl = impl, outputs = set }
    registered[#registered + 1] = entry
    rebind_all()
    return function()
        for i, e in ipairs(registered) do
            if e == entry then
                table.remove(registered, i)
                break
            end
        end
        rebind_all()
    end
end

--- Use the arrangement registered as `name` for a space (nil: the default).
function spaces.set_arrangement(space, name)
    space.arrangement = name
    bind(space)
end

--------------------------------------------------------------------------------
-- Spaces and windows
--------------------------------------------------------------------------------

local function remove_from(list, item)
    for i, x in ipairs(list) do
        if x == item then
            table.remove(list, i)
            return true
        end
    end
end

--- The space a window is in.
function spaces.of(w) return by_window[w] end

--- The windows of a space its arrangement places (not minimized), oldest
--- first.
function spaces.arranged(space)
    local list = {}
    for _, w in ipairs(space.windows) do
        if not space.minimized[w] then list[#list + 1] = w end
    end
    return list
end

--- The shown space of an output.
function spaces.current(o)
    local s = outputs[o]
    return s and s.shown
end

--- The spaces of an output, in order.
function spaces.list(o)
    local s = outputs[o]
    local copy = {}
    if s then for i, space in ipairs(s.list) do copy[i] = space end end
    return copy
end

--- Re-arrange a space (e.g. after changing its arrangement's settings).
function spaces.arrange(space) call(space, "arrange") end

--- A new, hidden space on an output.
function spaces.new(o, opts)
    local s = outputs[o]
    if not s then error("spaces.new: unknown output", 2) end
    local space = {
        output = o,
        name = opts and opts.name,
        arrangement = opts and opts.arrangement,
        windows = {},
        minimized = {},
        shown = false,
        fullscreen = nil,
        data = {},
    }
    s.list[#s.list + 1] = space
    bind(space)
    boring.events:emit("space:add", space)
    return space
end

local function set_shown(space, shown)
    space.shown = shown
    for _, w in ipairs(space.windows) do w:set_enabled(shown and not space.minimized[w]) end
end

local function focus_next(space, except)
    for _, x in ipairs(boring.windows()) do
        if x ~= except and x:visible() then
            boring.focus(x)
            return
        end
    end
    boring.blur()
end

local exit_fullscreen

-- Take a window out of its space.
local function detach(w)
    local space = by_window[w]
    if not space then return end
    if space.fullscreen == w then exit_fullscreen(space, false) end
    by_window[w] = nil
    remove_from(space.windows, w)
    if space.minimized[w] then
        space.minimized[w] = nil
        w:set_enabled(true)
    else
        call(space, "remove", w)
    end
    return space
end

local function attach(w, space)
    by_window[w] = space
    space.windows[#space.windows + 1] = w
    w:set_enabled(space.shown)
    call(space, "add", w)
end

--- Minimize a window (or bring it back).
function spaces.minimize(w, on)
    local space = by_window[w]
    if not space or (space.minimized[w] or false) == (on and true or false) then return end
    if on then
        if space.fullscreen == w then exit_fullscreen(space, false) end
        space.minimized[w] = true
        w:set_enabled(false)
        call(space, "remove", w)
        if boring.focused() == w then focus_next(space, w) end
    else
        space.minimized[w] = nil
        w:set_enabled(space.shown)
        call(space, "add", w)
    end
end

--- Move a window to another space (possibly on another output).
function spaces.move(w, space)
    if by_window[w] == space then return end
    local was_focused = boring.focused() == w
    detach(w)
    attach(w, space)
    boring.events:emit("space:window", w, space)
    if was_focused and not space.shown then focus_next(space, w) end
end

--- Show a space, hiding the one its output showed before.
function spaces.show(space)
    local s = outputs[space.output]
    if not s or s.shown == space then return end
    local previous = s.shown
    if previous then set_shown(previous, false) end
    s.shown = space
    set_shown(space, true)
    call(space, "arrange")
    boring.events:emit("space:show", space)

    -- Keep focus on what's visible.
    local focused = boring.focused()
    if not focused or not focused:visible() then
        local next_w = nil
        for _, w in ipairs(boring.windows()) do
            if by_window[w] == space then next_w = w break end
        end
        if next_w then boring.focus(next_w)
        elseif focused then boring.blur() end
    end
end

--- Remove a space; its windows go to `into` (default: the output's shown
--- space, or its first other space).
function spaces.remove(space, into)
    local s = outputs[space.output]
    if not s then return end
    if not into or into == space then
        into = s.shown ~= space and s.shown or nil
        if not into then
            for _, other in ipairs(s.list) do
                if other ~= space then into = other break end
            end
        end
    end
    if not into then error("spaces.remove: an output keeps at least one space", 2) end
    local windows = {}
    for i, w in ipairs(space.windows) do windows[i] = w end
    for _, w in ipairs(windows) do spaces.move(w, into) end
    if s.shown == space then spaces.show(into) end
    remove_from(s.list, space)
    if space.impl then call(space, "shutdown") end
    space.impl = nil
    boring.events:emit("space:remove", space)
end

--------------------------------------------------------------------------------
-- Fullscreen
--------------------------------------------------------------------------------

local function enter_fullscreen(space, w)
    if space.fullscreen == w then return end
    if space.fullscreen then exit_fullscreen(space, true) end
    space.fullscreen = w
    fullscreen.enter(w, space.output)
end

exit_fullscreen = function(space, rearrange)
    local w = space.fullscreen
    if not w then return end
    space.fullscreen = nil
    fullscreen.exit(w)
    if rearrange ~= false then call(space, "arrange") end
end

--- Make a window fullscreen on its output (or stop).
function spaces.fullscreen(w, on)
    local space = by_window[w]
    if not space then return end
    if on then enter_fullscreen(space, w) elseif space.fullscreen == w then exit_fullscreen(space) end
end

--------------------------------------------------------------------------------
-- Outputs and events
--------------------------------------------------------------------------------

local function primary_space()
    local o = boring.outputs()[1]
    return o and spaces.current(o)
end

local function add_output(o)
    if outputs[o] then return end
    outputs[o] = { list = {}, shown = nil }
    local space = spaces.new(o)
    spaces.show(space)
end

local function remove_output(o)
    local s = outputs[o]
    if not s then return end
    outputs[o] = nil
    local fallback = primary_space()
    for _, space in ipairs(s.list) do
        if space.fullscreen then exit_fullscreen(space, false) end
        if space.impl then call(space, "shutdown") end
        space.impl = nil
        for _, w in ipairs(space.windows) do
            by_window[w] = nil
            if fallback then attach(w, fallback) end
        end
        boring.events:emit("space:remove", space)
    end
end

-- The output a window opened on: where its top-left corner is (core puts
-- new windows at the origin of the output under the cursor).
local function output_of(w)
    local b = w:bounds()
    return boring.output_at(b.x, b.y) or boring.output_at(boring.cursor()) or boring.outputs()[1]
end

local function add_window(w)
    if by_window[w] then return end
    local o = output_of(w)
    local space = o and spaces.current(o)
    if space then attach(w, space) end
end

local function each_space_of(o, fn)
    local s = outputs[o]
    if s then for _, space in ipairs(s.list) do fn(space) end end
end

scope:subscribe(boring.events, "output:add", add_output)
scope:subscribe(boring.events, "output:remove", remove_output)
scope:subscribe(boring.events, "output:usable", function(o) each_space_of(o, spaces.arrange) end)
scope:subscribe(boring.events, "output:change", function(o)
    each_space_of(o, function(space)
        if space.fullscreen then fullscreen.fit(space.fullscreen, o) end
    end)
end)

scope:subscribe(boring.events, "window:map", add_window)
scope:subscribe(boring.events, "window:unmap", function(w) detach(w) end)
scope:subscribe(boring.events, "window:commit", function(w)
    local space = by_window[w]
    if space and space.fullscreen ~= w then call(space, "commit", w) end
end)

scope:subscribe(boring.events, "window:request_move", function(w)
    local space = by_window[w]
    if not space or space.fullscreen == w then return end
    if space.impl and space.impl.move then call(space, "move", w) else boring.begin_move(w) end
end)
scope:subscribe(boring.events, "window:request_resize", function(w, edges)
    local space = by_window[w]
    if not space or space.fullscreen == w then return end
    if space.impl and space.impl.resize then call(space, "resize", w, edges) else boring.begin_resize(w, edges) end
end)
scope:subscribe(boring.events, "window:request_fullscreen", spaces.fullscreen)
scope:subscribe(boring.events, "window:request_minimize", function(w) spaces.minimize(w, true) end)
-- Focusing a minimized window (a taskbar, xdg-activation) brings it back,
-- on its space.
scope:subscribe(boring.events, "window:focus", function(w)
    local space = by_window[w]
    if not space then return end
    if space.minimized[w] then spaces.minimize(w, false) end
    if not space.shown then spaces.show(space) end
end)

-- Loaded after startup (a reload added the first layout plugin): take the
-- outputs and windows that are already there.
for _, o in ipairs(boring.outputs()) do add_output(o) end
for i = #boring.windows(), 1, -1 do add_window(boring.windows()[i]) end

return spaces
