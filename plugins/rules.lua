-- plugins/rules.lua
-- Window rules: functions that look at a window before it maps and return
-- properties for it.
--
--   plugin("@boring/rules"):mount({
--       function(w)
--           if w:app_id() == "pavucontrol" then
--               return { floating = true, size = { 640, 480 } }
--           end
--       end,
--       function(w)
--           local title = w:title() or ""
--           if title:find("Picture-in-Picture", 1, true) then
--               return { floating = true, border = false, position = { 20, 20 } }
--           end
--           if w:app_id() == "firefox" then return { workspace = 2 } end
--       end,
--   })
--
-- `mount` also takes a single function. Every rule runs, in order; the
-- tables they return are merged into w.props (later rules win). Plugins
-- read the properties they understand (see compositor/window.lua):
--   floating                 tiling: keep out of the tree
--   size = { w, h }          stacking, floating windows
--   position = { x, y }      stacking (relative to the output)
--   maximized                stacking
--   fullscreen               every layout (library/spaces)
--   workspace = n            workspaces
--   output = "DP-1"          the output it opens on (library/spaces)
--   border = false           borders
--   focus = false            core: don't focus it when it opens

local plugin = { name = "rules" }

function plugin:mount(config, ctx)
    local rules = type(config) == "function" and { config } or config
    ctx.scope:subscribe(boring.events, "window:configure", function(w)
        for i, rule in ipairs(rules) do
            local ok, props = xpcall(rule, debug.traceback, w)
            if not ok then
                boring.log.error("rules: rule %d failed: %s", i, tostring(props))
            elseif type(props) == "table" then
                for k, v in pairs(props) do w.props[k] = v end
            end
        end
    end)
end

return plugin
