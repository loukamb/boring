-- plugins/workspaces.lua
-- Workspaces per output, with actions for shortcuts. Panels see them over
-- ext-workspace-v1.
--
--   local ws = plugin("@boring/workspaces"):mount({
--       count = 9,                      -- per output
--       names = { "web", "code" },      -- optional; the rest are numbered
--   })
--   ["Mod4+1"] = ws.actions.switch(1),
--   ["Mod4+Shift+1"] = ws.actions.send(1),
--   ["Mod4+Tab"] = ws.actions.next,
--
-- Needs a layout plugin (stacking, tiling, kiosk): workspaces are spaces.

local workspaces = require("@boring/library/workspaces")

local plugin = { name = "workspaces" }

function plugin:mount(config, ctx)
    workspaces.configure({ count = config.count or 9, names = config.names })
    -- Unmounted for good (not remounted by the same reload): back to one.
    ctx.scope:defer(workspaces.reset_soon)

    local actions = {}
    function actions.switch(i)
        return function() workspaces.switch(i) end
    end
    function actions.send(i)
        return function()
            local w = boring.focused()
            if w then workspaces.send(w, i) end
        end
    end
    --- Send the focused window and follow it.
    function actions.take(i)
        return function()
            local w = boring.focused()
            if w then workspaces.send(w, i) end
            workspaces.switch(i)
            if w then boring.focus(w) end
        end
    end
    function actions.next() workspaces.step(1) end
    function actions.previous() workspaces.step(-1) end

    return { actions = actions, workspaces = workspaces }
end

return plugin
