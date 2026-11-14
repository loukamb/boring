-- plugins/notifications.lua
-- Notifications: cards stacked in a corner of the screen.
--
--   local notifications = plugin("@boring/notifications"):mount({
--       corner = "top-right",      -- or top-left, bottom-right, bottom-left
--       width = 360,
--       timeout = 5000,            -- ms, when the sender doesn't say
--       max_visible = 4,
--       history = 100,             -- how many to remember
--       dbus = "sd-bus",           -- force a D-Bus library (default: whichever works)
--       theme = { ... },           -- library/ui theme overrides
--   })
--   ["Mod4+n"] = notifications.actions.dismiss_all,
--   ["Mod4+Shift+n"] = notifications.actions.toggle_dnd,   -- do not disturb
--
-- With `screenshots` (default true), saved screenshots show a card too.
--
-- Applications reach it over D-Bus (org.freedesktop.Notifications, e.g.
-- `notify-send`), through whichever D-Bus library is installed
-- (shared/dbus). Without one, or without a session bus, it warns and only
-- shows what plugins send with `notifications.notify({ title, body, ... })`.
--
-- Clicking a card runs its default action (or just dismisses it); its
-- buttons run the other actions. Critical notifications stay until
-- dismissed; with do not disturb on, others go straight to the history
-- (`notifications.history()`, also over ipc).

local ui = require("@boring/library/ui")
local animate = require("@boring/library/animate")
local desktop = require("@boring/library/desktop")
local dbus = require("shared.dbus")

local plugin = { name = "notifications" }

local PATH = "/org/freedesktop/Notifications"
local IFACE = "org.freedesktop.Notifications"

local EXPIRED, DISMISSED, CLOSED = 1, 2, 3

-- Notification bodies may carry a little markup; cards show plain text.
local function plain(s)
    s = (s or ""):gsub("<[^>]*>", "")
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
    return s
end

local function icon_path(name, size)
    if not name or name == "" then return nil end
    name = name:gsub("^file://", "")
    return desktop.icon(name, size)
end

function plugin:mount(config, ctx)
    local theme = ui.theme(config.theme)
    local width = config.width or 360
    local corner = config.corner or "top-right"
    local default_timeout = config.timeout or 5000
    local max_visible = config.max_visible or 4
    local keep = config.history or 100
    local margin, gap = 12, 10

    ctx.state.next_id = ctx.state.next_id or 1
    ctx.state.history = ctx.state.history or {}
    local history = ctx.state.history
    local shown = {}     -- cards on screen, newest first
    local by_id = {}     -- id -> card
    local dnd = ctx.state.dnd or false
    local bus = nil

    local function output()
        local w = boring.focused()
        if w then
            local b = w:bounds()
            local o = boring.output_at(b.x + b.width / 2, b.y + b.height / 2)
            if o then return o end
        end
        return boring.output_at(boring.cursor()) or boring.outputs()[1]
    end

    -- Where each card goes, newest nearest the corner.
    local function layout()
        local o = output()
        if not o then return end
        local area = o.usable
        local right = corner:find("right") ~= nil
        local bottom = corner:find("bottom") ~= nil
        local x = right and area.x + area.width - width - margin or area.x + margin
        local offset = margin
        for i, card in ipairs(shown) do
            local visible = i <= max_visible
            local y = bottom and area.y + area.height - offset - card.view.height or area.y + offset
            card.target = { x, y }
            card.offscreen = { right and area.x + area.width + 20 or area.x - width - 20, y }
            if visible then offset = offset + card.view.height + gap end
            if card.position then
                animate.to(card.position, visible and card.target or card.offscreen, { duration = 220 })
            else
                card.position = animate.bind(nil, animate.ease({ from = card.offscreen, to = card.target,
                    duration = 260, easing = "out-back" }), function(p)
                    if card.view.tree then card.view.tree.node:set_position(math.floor(p[1]), math.floor(p[2])) end
                end)
            end
        end
    end

    local close

    local function remember(n)
        table.insert(history, 1, n)
        while #history > keep do table.remove(history) end
    end

    local function invoke(card, key)
        if bus then bus:emit(PATH, IFACE, "ActionInvoked", "us", card.n.id, key) end
        if card.n.on_action then
            local ok, err = xpcall(card.n.on_action, debug.traceback, key)
            if not ok then boring.log.error("notifications: %s", tostring(err)) end
        end
        close(card.n.id, DISMISSED)
    end

    local function render(card)
        local n = card.n
        local icon = icon_path(n.icon, 40)
        local header = ui.row({
            ui.text(n.app ~= "" and n.app or "Notification", { style = "muted", max_width = width - 140 }),
            ui.text(os.date("%H:%M", n.time), { style = "muted" }),
        }, { gap = 8 })
        local text = { header, ui.text(n.title, { style = "title", max_width = width - 90 }) }
        if n.body ~= "" then text[#text + 1] = ui.text(n.body, { wrap = width - 90 }) end
        local buttons = {}
        for _, a in ipairs(n.actions) do
            if a.key ~= "default" then
                buttons[#buttons + 1] = ui.button(a.label, function() invoke(card, a.key) end)
            end
        end
        if #buttons > 0 then text[#text + 1] = ui.row(buttons, { gap = 6 }) end
        local body = ui.column(text, { gap = 4, align = "start" })
        local content = icon and ui.row({ ui.image(icon, { size = 40 }), body }, { gap = 12, align = "start" }) or body
        return ui.box(content, {
            width = width, padding = 14, radius = theme.radius + 4,
            background = n.urgency == 2 and (config.critical_background or "#3b0d0df0") or theme.background,
            border = theme.border,
        })
    end

    -- Clicks: buttons first, then the card's default action. The view's
    -- tree is new after every update, so this is redone then.
    local function listen(card)
        local n = card.n
        if card.off_click then card.off_click() end
        card.off_click = boring.on_click(card.view.tree.node, function(_, button)
            local x, y = boring.cursor()
            if button == 0x111 then return close(n.id, DISMISSED) end -- right click
            if not card.view:click(x, y, button) then
                local default = nil
                for _, a in ipairs(n.actions) do if a.key == "default" then default = a end end
                if default then invoke(card, "default") else close(n.id, DISMISSED) end
            end
        end)
    end

    local function refresh(card)
        card.view:update()
        listen(card)
        local p = card.position and card.position.current
        if p then card.view.tree.node:set_position(math.floor(p[1]), math.floor(p[2])) end
    end

    local function show(n)
        local card = { n = n }
        card.view = ui.view({ theme = theme, layer = "overlay", render = function() return render(card) end,
            place = function() return -10000, -10000 end })
        listen(card)
        by_id[n.id] = card
        table.insert(shown, 1, card)
        if n.timeout > 0 then
            card.cancel_expiry = boring.after(n.timeout, function() close(n.id, EXPIRED) end)
        end
        layout()
    end

    -- Take a card off the screen (sliding out), and tell the sender.
    close = function(id, reason)
        local card = by_id[id]
        if not card then return false end
        by_id[id] = nil
        for i, c in ipairs(shown) do
            if c == card then table.remove(shown, i) break end
        end
        if card.cancel_expiry then card.cancel_expiry() end
        card.off_click()
        if card.position then animate.stop(card.position) end
        local view = card.view
        local from = card.target or { -10000, -10000 }
        animate.run(nil, animate.ease({ from = 0, to = 1, duration = 180 }), function(p)
            if view.tree then
                view.tree.node:set_position(math.floor(from[1] + (card.offscreen[1] - from[1]) * p), math.floor(from[2]))
                view:set_opacity(1 - p)
            end
        end, function() view:close() end)
        if bus then bus:emit(PATH, IFACE, "NotificationClosed", "uu", id, reason or CLOSED) end
        layout()
        return true
    end

    --- Show a notification: { title, body, app, icon, urgency (0-2),
    --- timeout (ms; 0 = until dismissed), actions = { { key, label } },
    --- replaces (an id), on_action = fn(key) }. Returns its id.
    local function notify(opts)
        local id = opts.replaces and opts.replaces > 0 and by_id[opts.replaces] and opts.replaces or nil
        if not id then
            id = ctx.state.next_id
            ctx.state.next_id = id + 1
        end
        local urgency = opts.urgency or 1
        local timeout = opts.timeout
        if timeout == nil or timeout < 0 then timeout = default_timeout end
        if urgency == 2 then timeout = 0 end
        local n = {
            id = id, app = opts.app or "", title = plain(opts.title), body = plain(opts.body),
            icon = opts.icon, urgency = urgency, timeout = timeout, actions = opts.actions or {},
            time = os.time(), on_action = opts.on_action,
        }
        remember(n)
        local existing = by_id[id]
        if existing then
            existing.n = n
            refresh(existing)
            if existing.cancel_expiry then existing.cancel_expiry() end
            existing.cancel_expiry = n.timeout > 0 and boring.after(n.timeout, function() close(id, EXPIRED) end) or nil
            layout()
        elseif not dnd or urgency == 2 then
            show(n)
        end
        return id
    end

    -- D-Bus --------------------------------------------------------------------

    local conn, err = dbus.session({ backend = config.dbus, watch = boring.on_readable })
    if not conn then
        boring.log.warn("notifications: D-Bus isn't available (%s); applications can't send notifications", err)
    else
        local ok, why = conn:own(IFACE)
        if not ok then
            boring.log.warn("notifications: can't own %s (%s); is another notification daemon running?", IFACE, why)
            conn:close()
        else
            bus = conn
            boring.log.info("notifications: on D-Bus through %s", conn.backend)
            conn:export(PATH, IFACE, {
                GetCapabilities = { "", "as", function()
                    return { "body", "actions", "icon-static", "persistence" }
                end },
                GetServerInformation = { "", "ssss", function()
                    return "boring", "boring", "1", "1.2"
                end },
                CloseNotification = { "u", "", function(id) close(id, CLOSED) end },
                Notify = { "susssasa{sv}i", "u", function(app, replaces, icon, summary, body, actions, hints, timeout)
                    local list = {}
                    for i = 1, #actions - 1, 2 do list[#list + 1] = { key = actions[i], label = actions[i + 1] } end
                    hints = hints or {}
                    local hint_icon = hints["image-path"] or hints["image_path"]
                    if (not icon or icon == "") and hints["desktop-entry"] then icon = hints["desktop-entry"] end
                    return notify({
                        app = app, replaces = replaces, icon = hint_icon or icon, title = summary, body = body,
                        actions = list, urgency = tonumber(hints.urgency) or 1, timeout = timeout,
                    })
                end },
            })
        end
    end

    -- Saved screenshots, with the picture as the icon.
    if config.screenshots ~= false then
        ctx.scope:subscribe(boring.events, "screenshot:taken", function(path)
            notify({ app = "Screenshot", title = path and "Screenshot saved" or "Screenshot copied",
                body = path or "", icon = path, timeout = 3000 })
        end)
    end

    ctx.scope:defer(function()
        local ids = {}
        for id in pairs(by_id) do ids[#ids + 1] = id end
        for _, id in ipairs(ids) do close(id, CLOSED) end
        if bus then bus:close() end
        bus = nil
    end)

    local actions = {}
    function actions.dismiss() if shown[1] then close(shown[1].n.id, DISMISSED) end end
    function actions.dismiss_all()
        local ids = {}
        for id in pairs(by_id) do ids[#ids + 1] = id end
        for _, id in ipairs(ids) do close(id, DISMISSED) end
    end
    function actions.toggle_dnd()
        dnd = not dnd
        ctx.state.dnd = dnd
        if dnd then actions.dismiss_all() end
    end

    return {
        actions = actions,
        notify = notify,
        close = function(id) return close(id, CLOSED) end,
        history = function() return history end,
        shown = function()
            local out = {}
            for i, c in ipairs(shown) do out[i] = c.n end
            return out
        end,
        dnd = function() return dnd end,
        backend = bus and bus.backend or nil,
    }
end

return plugin
