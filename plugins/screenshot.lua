-- plugins/screenshot.lua
-- Screenshots through grim (and slurp for areas), which capture through the
-- screencopy protocol boring implements.
--
--   local screenshot = plugin("@boring/screenshot"):mount({
--       directory = "~/Pictures/Screenshots",  -- default: $XDG_PICTURES_DIR or ~/Pictures
--       clipboard = false,                      -- also copy to the clipboard (wl-copy)
--   })
--   shortcuts = {
--       ["PrintScreen"] = screenshot.actions.area,
--       ["Ctrl+PrintScreen"] = screenshot.actions.fullscreen,
--       ["Alt+PrintScreen"] = screenshot.actions.window,
--   }

local plugin = { name = "screenshot" }

local function expand(path)
    local home = os.getenv("HOME") or "."
    return (path:gsub("^~", home))
end

local function quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

function plugin:mount(config)
    config = config or {}
    local directory = expand(config.directory or os.getenv("XDG_PICTURES_DIR") or "~/Pictures")

    local function target()
        return string.format("%s/screenshot-%s.png", directory, os.date("%Y%m%d-%H%M%S"))
    end

    -- grim with optional geometry ("x,y wxh" or a shell expression).
    local function shoot(geometry_expr)
        local file = target()
        local cmd = string.format("mkdir -p %s && grim %s %s",
            quote(directory), geometry_expr and ("-g " .. geometry_expr) or "", quote(file))
        if config.clipboard then
            cmd = cmd .. " && wl-copy < " .. quote(file)
        end
        boring.spawn(cmd)
    end

    return {
        actions = {
            fullscreen = function() shoot(nil) end,
            area = function() shoot('"$(slurp)"') end,
            window = function()
                local w = boring.focused()
                if not w then return end
                local b = w:bounds()
                shoot(quote(string.format("%d,%d %dx%d", b.x, b.y, b.width, b.height)))
            end,
        },
    }
end

function plugin:unmount() end

return plugin
