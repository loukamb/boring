-- plugins/library/workspaces.lua
-- Workspaces: several spaces per output, one shown at a time, published to
-- panels and pagers over ext-workspace-v1.
--
--   local workspaces = require("@boring/library/workspaces")
--   workspaces.configure({ count = 5, names = { "web", "code" } })
--   workspaces.switch(2)          -- on the focused output
--   workspaces.send(w, 3)         -- move a window to workspace 3 of its output
--
-- Workspaces are per output: every output has `count` of them, numbered
-- from 1. Clients activating a workspace through ext-workspace switch to it.

local spaces = require("@boring/library/spaces")

local wl = boring.wl
local lib, C, ffi = wl.lib, wl.C, wl.ffi

local workspaces = {}

local scope = boring.scope("workspaces")
local settings = { count = 1, names = {} }
local pending_reset = nil

-- ext-workspace ---------------------------------------------------------------

local manager = lib.wlr_ext_workspace_manager_v1_create(boring.server.display, 1)
local groups = {}  -- output -> group handle
local handles = {} -- space -> workspace handle
local by_handle = {} -- addr(handle) -> space
boring.implement("ext_workspace_manager_v1", "ext_workspace_group_handle_v1", "ext_workspace_handle_v1")

local function index_of(space)
    for i, s in ipairs(spaces.list(space.output)) do
        if s == space then return i end
    end
end

local function name_of(i)
    return settings.names[i] or tostring(i)
end

local function publish(space)
    local o = space.output
    local group = groups[o]
    if not group then
        group = lib.wlr_ext_workspace_group_handle_v1_create(manager, 0)
        lib.wlr_ext_workspace_group_handle_v1_output_enter(group, o.wlr)
        groups[o] = group
    end
    local h = handles[space]
    local i = index_of(space)
    if not i then return end
    if not h then
        h = lib.wlr_ext_workspace_handle_v1_create(manager, o.name .. "/" .. i,
            C.EXT_WORKSPACE_HANDLE_V1_WORKSPACE_CAPABILITIES_ACTIVATE)
        lib.wlr_ext_workspace_handle_v1_set_group(h, group)
        handles[space] = h
        by_handle[wl.addr(h)] = space
    end
    lib.wlr_ext_workspace_handle_v1_set_name(h, name_of(i))
    local coords = ffi.new("uint32_t[1]", i - 1)
    lib.wlr_ext_workspace_handle_v1_set_coordinates(h, coords, 1)
    lib.wlr_ext_workspace_handle_v1_set_active(h, space.shown)
end

local function unpublish(space)
    local h = handles[space]
    if not h then return end
    handles[space] = nil
    by_handle[wl.addr(h)] = nil
    lib.wlr_ext_workspace_handle_v1_destroy(h)
end

local function publish_output(o)
    for _, space in ipairs(spaces.list(o)) do publish(space) end
end

scope:listen(manager.events.commit, function(event)
    for req in wl.list.each(event.requests, "struct wlr_ext_workspace_v1_request", "link") do
        if req.type == C.WLR_EXT_WORKSPACE_V1_REQUEST_ACTIVATE and req.activate.workspace ~= nil then
            local space = by_handle[wl.addr(req.activate.workspace)]
            if space then spaces.show(space) end
        end
    end
end, "struct wlr_ext_workspace_v1_commit_event")

-- Spaces ----------------------------------------------------------------------

-- Give an output `settings.count` spaces.
local function fit(o)
    local list = spaces.list(o)
    for i = #list + 1, settings.count do
        spaces.new(o, { name = name_of(i) })
    end
    list = spaces.list(o)
    for i = #list, settings.count + 1, -1 do
        spaces.remove(list[i], list[1])
    end
    for i, space in ipairs(spaces.list(o)) do space.name = name_of(i) end
    publish_output(o)
end

scope:subscribe(boring.events, "output:add", fit)
scope:subscribe(boring.events, "output:remove", function(o)
    local group = groups[o]
    groups[o] = nil
    if group then lib.wlr_ext_workspace_group_handle_v1_destroy(group) end
end)
scope:subscribe(boring.events, "space:add", publish)
scope:subscribe(boring.events, "space:remove", unpublish)
scope:subscribe(boring.events, "space:show", function(space) publish_output(space.output) end)

-- The output commands act on: the focused window's, else the one under the
-- cursor.
local function current_output()
    local w = boring.focused()
    local space = w and spaces.of(w)
    if space then return space.output end
    return boring.output_at(boring.cursor()) or boring.outputs()[1]
end

--- { count = n, names = { [i] = name } }. Outputs get or lose workspaces to
--- match; windows on removed workspaces move to the first.
function workspaces.configure(opts)
    if pending_reset then
        pending_reset()
        pending_reset = nil
    end
    settings.count = math.max(1, opts.count or 1)
    settings.names = opts.names or {}
    for _, o in ipairs(boring.outputs()) do fit(o) end
end

--- Go back to one workspace per output, unless configure is called again
--- before the event loop runs (a plugin remounting with new settings).
function workspaces.reset_soon()
    if pending_reset then return end
    pending_reset = boring.after(0, function()
        pending_reset = nil
        workspaces.configure({ count = 1 })
    end)
end

--- The number of the shown workspace on an output (default: current).
function workspaces.current(o)
    o = o or current_output()
    local space = o and spaces.current(o)
    return space and index_of(space)
end

--- Show workspace i on an output (default: the current output).
function workspaces.switch(i, o)
    o = o or current_output()
    local space = o and spaces.list(o)[i]
    if space then spaces.show(space) end
end

--- Move a window to workspace i of its output.
function workspaces.send(w, i)
    local from = spaces.of(w)
    local space = from and spaces.list(from.output)[i]
    if space then spaces.move(w, space) end
end

--- The workspace after (step 1) or before (step -1) the shown one, wrapping.
function workspaces.step(step, o)
    o = o or current_output()
    local n = #spaces.list(o)
    local i = workspaces.current(o)
    if i and n > 0 then workspaces.switch((i - 1 + step) % n + 1, o) end
end

for _, o in ipairs(boring.outputs()) do fit(o) end

return workspaces
