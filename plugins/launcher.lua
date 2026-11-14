-- plugins/launcher.lua
-- A search field in the middle of the screen: type, pick, Enter.
--
--   local launcher = plugin("@boring/launcher"):mount({
--       terminal = "foot",               -- for Terminal=true applications
--       max_results = 8,
--       commands = {                     -- extra entries
--           { title = "Lock", run = actions.execute("swaylock -f"), icon = "system-lock-screen" },
--       },
--       sources = { ... },               -- your own: function(query) -> items
--       theme = { accent = "#f59e0b" },  -- library/ui theme overrides
--   })
--   ["Mod4+space"] = launcher.actions.toggle,
--
-- Results come from sources: installed applications (desktop entries), open
-- windows, a calculator and `commands`. A source is a function taking the
-- query and returning items { title, subtitle, icon, run, id, keywords };
-- `icon` is an icon name or a path, `id` keys how often it was picked, which
-- ranks it higher next time. With an empty query, the most used ones show.
--
-- Keys: type to search; Up/Down (or Ctrl+p/n, Tab) to choose; Enter to run;
-- Escape (or clicking outside) to close.

local ui = require("@boring/library/ui")
local desktop = require("@boring/library/desktop")
local animate = require("@boring/library/animate")

local plugin = { name = "launcher" }

--------------------------------------------------------------------------------
-- Matching
--------------------------------------------------------------------------------

local function is_boundary(t, i)
    if i <= 1 then return true end
    local prev = t:sub(i - 1, i - 1)
    return prev:match("[%s%-_./]") ~= nil
end

--- How well `query` matches `text` (higher is better), or nil if it
--- doesn't: a prefix beats a word start beats a substring beats letters
--- in order.
local function fuzzy(query, text)
    if not text or text == "" then return nil end
    local q, t = query:lower(), text:lower()
    if q == "" then return 0 end
    if t:sub(1, #q) == q then return 100 + 10 * #q / #t end
    local s = t:find(q, 1, true)
    if s then return (is_boundary(t, s) and 80 or 60) - s * 0.1 end
    local score, ti, last = 0, 1, nil
    for qi = 1, #q do
        local c = q:sub(qi, qi)
        local found = t:find(c, ti, true)
        if not found then return nil end
        if last and found == last + 1 then score = score + 3 end
        if is_boundary(t, found) then score = score + 4 end
        score = score - (found - ti) * 0.2
        last, ti = found, found + 1
    end
    return 20 + score
end

local function best_match(query, item)
    local best = fuzzy(query, item.title)
    local function try(text, weight)
        local s = fuzzy(query, text)
        if s and (not best or s * weight > best) then best = s * weight end
    end
    try(item.subtitle, 0.6)
    for _, k in ipairs(item.keywords or {}) do try(k, 0.8) end
    return best
end

--------------------------------------------------------------------------------
-- Sources
--------------------------------------------------------------------------------

local function applications_source(config)
    local apps, scanned_at = nil, 0
    return function()
        -- Rescan at most every few seconds (new installs show up).
        local now = boring.now()
        if not apps or now - scanned_at > 5000 then
            apps, scanned_at = desktop.applications(), now
        end
        local items = {}
        for _, app in ipairs(apps) do
            local keywords = { app.generic, app.exec:match("^%S+"):match("[^/]+$") }
            for _, k in ipairs(app.keywords) do keywords[#keywords + 1] = k end
            items[#items + 1] = {
                id = "app:" .. app.id,
                title = app.name,
                subtitle = app.comment or app.generic or "Application",
                icon = app.icon,
                keywords = keywords,
                run = function() boring.spawn(desktop.command(app, { terminal = config.terminal })) end,
            }
        end
        return items
    end
end

local function windows_source()
    return function(query)
        if query == "" then return {} end
        local items = {}
        for _, w in ipairs(boring.windows()) do
            local title = w:title() or w:app_id() or "Window"
            items[#items + 1] = {
                title = title,
                subtitle = "Window" .. (w:app_id() and (" · " .. w:app_id()) or ""),
                icon = w:app_id(),
                keywords = { w:app_id() },
                run = function() if w.mapped then boring.focus(w) end end,
            }
        end
        return items
    end
end

-- Arithmetic only: digits, operators, parentheses and math functions.
local MATH = setmetatable({}, { __index = math })
local function calculator_source()
    return function(query)
        if not query:match("[%d%)]") or not query:match("[%+%-%*/%^%%(]") then return {} end
        if query:match("[^%w%s%.%+%-%*/%^%%%(%),]") then return {} end
        local fn = loadstring("return " .. query)
        if not fn then return {} end
        setfenv(fn, MATH)
        local ok, value = pcall(fn)
        if not ok or type(value) ~= "number" or value ~= value then return {} end
        local text = value == math.floor(value) and math.abs(value) < 1e15 and string.format("%d", value)
            or string.format("%.10g", value)
        return { {
            title = text,
            subtitle = "= " .. query .. (boring.set_clipboard and " · Enter to copy" or ""),
            icon = "accessories-calculator",
            score = 1000,
            run = boring.set_clipboard and function() boring.set_clipboard(text) end or nil,
        } }
    end
end

local function commands_source(commands)
    return function()
        local items = {}
        for _, c in ipairs(commands) do
            items[#items + 1] = { id = "command:" .. c.title, title = c.title, subtitle = c.subtitle or "Command",
                icon = c.icon, run = c.run, keywords = c.keywords }
        end
        return items
    end
end

--------------------------------------------------------------------------------
-- Usage, saved between sessions
--------------------------------------------------------------------------------

local function usage_path()
    local dir = os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or ".") .. "/.local/state")
    return dir .. "/boring", dir .. "/boring/launcher-usage.lua"
end

local function load_usage()
    local _, path = usage_path()
    local fn = loadfile(path)
    if not fn then return {} end
    setfenv(fn, {})
    local ok, t = pcall(fn)
    return ok and type(t) == "table" and t or {}
end

local function save_usage(usage)
    local dir, path = usage_path()
    if not require("shared.fs").mkdir_p(dir) then return end
    local f = io.open(path .. ".tmp", "w")
    if not f then return end
    f:write("return {\n")
    for id, n in pairs(usage) do f:write(string.format("    [%q] = %d,\n", id, n)) end
    f:write("}\n")
    f:close()
    os.rename(path .. ".tmp", path)
end

--------------------------------------------------------------------------------
-- The launcher
--------------------------------------------------------------------------------

function plugin:mount(config, ctx)
    local theme = ui.theme(config.theme)
    local max_results = config.max_results or 8
    local width = config.width or 640
    ctx.state.usage = ctx.state.usage or load_usage()
    local usage = ctx.state.usage

    local sources = { applications_source(config), windows_source(), calculator_source(),
        commands_source(config.commands or {}) }
    for _, s in ipairs(config.sources or {}) do sources[#sources + 1] = s end

    local field, results, selected = { value = "", cursor = 0 }, {}, 1
    local view, release_keyboard, release_pointer, fade = nil, nil, nil, nil
    local output = nil

    local function search()
        local query = field.value:match("^%s*(.-)%s*$")
        local scored = {}
        for _, source in ipairs(sources) do
            local ok, items = pcall(source, query)
            if not ok then
                boring.log.error("launcher: a source failed: %s", tostring(items))
                items = {}
            end
            for _, item in ipairs(items) do
                local used = item.id and usage[item.id] or 0
                local s
                if query == "" then
                    s = used > 0 and used or nil
                else
                    s = item.score or best_match(query, item)
                    if s then s = s + math.min(20, 6 * math.log(1 + used)) end
                end
                if s then scored[#scored + 1] = { item = item, score = s } end
            end
        end
        table.sort(scored, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.item.title < b.item.title
        end)
        results = {}
        for i = 1, math.min(max_results, #scored) do results[i] = scored[i].item end
        selected = math.min(math.max(1, selected), math.max(1, #results))
    end

    local close

    local function run(item)
        if not item then return end
        close()
        if item.id then
            usage[item.id] = (usage[item.id] or 0) + 1
            save_usage(usage)
        end
        if item.run then
            local ok, err = xpcall(item.run, debug.traceback)
            if not ok then boring.log.error("launcher: %s", tostring(err)) end
        end
    end

    local function render()
        local rows = {
            ui.input({ value = field.value, cursor = field.cursor, placeholder = config.placeholder or "Search" }),
        }
        if #results > 0 then
            rows[#rows + 1] = ui.box(nil, { height = 1, background = theme.border })
            rows[#rows + 1] = ui.list(results, {
                selected = selected,
                render = function(item, _, is_selected)
                    local icon = desktop.icon(item.icon, theme.icon_size)
                    return ui.row({
                        icon and ui.image(icon, { size = theme.icon_size }) or ui.spacer(theme.icon_size, theme.icon_size),
                        ui.text(item.title, { color = is_selected and theme.selection_foreground or nil,
                            max_width = width * 0.5 }),
                        ui.text(item.subtitle or "", { style = "muted",
                            color = is_selected and theme.selection_foreground or nil, max_width = width * 0.35 }),
                    }, { gap = 10 })
                end,
            })
            rows[#rows].on_click = function(item) run(item) end
        end
        return ui.box(ui.column(rows, { gap = 8 }), {
            width = width, padding = theme.padding, radius = theme.radius + 4,
            background = theme.background, border = theme.border,
        })
    end

    local function place(_, _)
        local b = output and output:box() or { x = 0, y = 0, width = 1280, height = 720 }
        return b.x + (b.width - width) / 2, b.y + b.height * 0.22
    end

    local function refresh()
        search()
        if view then view:update() end
    end

    close = function()
        if not view then return end
        if fade then animate.stop(fade) end
        local v = view
        view = nil
        if release_keyboard then release_keyboard() end
        if release_pointer then release_pointer() end
        release_keyboard, release_pointer = nil, nil
        v:close()
    end

    local function key(ev)
        if not ev.pressed then return end
        local name, ctrl = ev.name, ev.mods.ctrl
        if name == "Escape" then
            close()
        elseif name == "Return" or name == "KP_Enter" then
            run(results[selected])
        elseif name == "Down" or name == "Tab" or (ctrl and name == "n") then
            selected = selected % math.max(1, #results) + 1
            view:update()
        elseif name == "Up" or name == "ISO_Left_Tab" or (ctrl and name == "p") then
            selected = (selected - 2) % math.max(1, #results) + 1
            view:update()
        elseif ui.edit(field, ev) then
            selected = 1
            refresh()
        end
    end

    local function open()
        if view then return end
        local cx, cy = boring.cursor()
        local focused = boring.focused()
        output = boring.output_at(cx, cy) or boring.outputs()[1]
        if focused then
            local b = focused:bounds()
            output = boring.output_at(b.x + b.width / 2, b.y + b.height / 2) or output
        end
        field.value, field.cursor, selected = "", 0, 1
        search()
        view = ui.view({ theme = theme, layer = "overlay", render = render, place = place })
        view:set_opacity(0)
        fade = animate.run(nil, animate.ease({ from = 0, to = 1, duration = 120 }), function(a)
            if view then view:set_opacity(a) end
        end)
        release_keyboard = boring.grab_keyboard({ key = key })
        release_pointer = boring.grab_pointer({
            button = function(button, pressed)
                if not pressed then return false end
                local x, y = boring.cursor()
                if view and view:contains(x, y) then
                    view:click(x, y, button)
                    return false
                end
                close()
                return false
            end,
            axis = function(steps)
                if #results == 0 then return end
                selected = math.max(1, math.min(#results, selected + steps))
                view:update()
            end,
        })
    end

    ctx.scope:defer(close)

    local actions = {
        open = open,
        close = close,
        toggle = function() if view then close() else open() end end,
    }
    return {
        actions = actions,
        is_open = function() return view ~= nil end,
        query = function(text)
            field.value, field.cursor = text, #text
            refresh()
        end,
        results = function() return results end,
    }
end

plugin._private = { fuzzy = fuzzy }

return plugin
