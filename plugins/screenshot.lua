-- plugins/screenshot.lua
-- Screenshots, with nothing to install: the compositor captures the screen
-- itself (library/capture), lets you pick an area and mark it up, saves a
-- PNG (libvips) and copies it to the clipboard.
--
--   local screenshot = plugin("@boring/screenshot"):mount({
--       directory = "~/Pictures/Screenshots",  -- default: $XDG_PICTURES_DIR/Screenshots or ~/Pictures/Screenshots
--       save = true,                            -- write a file
--       clipboard = true,                       -- and/or copy it
--       edit = true,                            -- mark up an area before saving
--       colors = { "#ef4444", "#f59e0b", "#22c55e", "#3b82f6", "#ffffff" },
--       theme = { accent = "#f59e0b" },         -- library/ui theme overrides
--   })
--   ["PrintScreen"] = screenshot.actions.area,        -- drag an area, or click a window
--   ["Ctrl+PrintScreen"] = screenshot.actions.fullscreen,
--   ["Alt+PrintScreen"] = screenshot.actions.window,  -- the focused window
--
-- Picking an area: drag over the frozen screen; a click without dragging
-- takes the window under the cursor; Enter takes the whole output; Escape
-- cancels. Then, with `edit`, the editor: drag inside the area with a tool
--   b  blur        p  pen        r  rectangle        a  arrow
--   c  next colour   Ctrl+z undo   Enter  done   Ctrl+c copy   Ctrl+s save   Escape cancel
-- or click the toolbar. Emits screenshot:taken(path or nil, png bytes).

local ui = require("@boring/library/ui")
local capture = require("@boring/library/capture")
local pixels = require("@boring/library/pixels")
local scene = require("@boring/library/scene")
local color = require("shared.color")
local image = require("shared.image")
local fs = require("shared.fs")

local plugin = { name = "screenshot" }

local BUTTON_LEFT = 0x110

local function expand(path)
    return (path:gsub("^~", os.getenv("HOME") or "."))
end

local function default_directory()
    local pictures = os.getenv("XDG_PICTURES_DIR") or "~/Pictures"
    return pictures .. "/Screenshots"
end

-- A canvas as an image under `tree`, shown at width x height layout pixels
-- at (x, y).
local function show(tree, canvas, x, y, width, height)
    local node = scene.image(tree, canvas)
    node:set_position(x, y)
    node:set_size(width, height)
    return node
end

function plugin:mount(config, ctx)
    local theme = ui.theme(config.theme)
    local directory = expand(config.directory or default_directory())
    local save_file = config.save ~= false
    local copy = config.clipboard ~= false
    local edit = config.edit ~= false
    local palette = config.colors or { "#ef4444", "#f59e0b", "#22c55e", "#3b82f6", "#ffffff" }
    local session = nil -- the screenshot being taken

    -- Finishing ----------------------------------------------------------------

    local function deliver(canvas, do_save, do_copy)
        if not image.available then
            boring.log.warn("screenshot: libvips isn't installed; can't encode PNG")
            return
        end
        local png, err = image.png(canvas.data, canvas.width, canvas.height)
        if not png then
            boring.log.error("screenshot: %s", tostring(err))
            return
        end
        local path = nil
        if do_save then
            fs.mkdir_p(directory)
            path = string.format("%s/screenshot-%s.png", directory, os.date("%Y%m%d-%H%M%S"))
            local f = io.open(path, "wb")
            if f then
                f:write(png)
                f:close()
                boring.log.info("screenshot saved to %s", path)
            else
                boring.log.error("screenshot: can't write %s", path)
                path = nil
            end
        end
        if do_copy then boring.set_clipboard({ ["image/png"] = png }) end
        boring.events:emit("screenshot:taken", path, png)
    end

    local function stop()
        local s = session
        if not s then return end
        session = nil
        if s.release_keyboard then s.release_keyboard() end
        if s.release_pointer then s.release_pointer() end
        if s.toolbar then s.toolbar:close() end
        s.tree:destroy()
    end

    -- The picture: frozen screen, dimmed outside the selection ---------------------

    local function redraw(s)
        if s.layer then s.layer:destroy() end
        s.layer = scene.tree(s.tree)
        local box, sel = s.box, s.selection
        local dim = { 0, 0, 0, 0.45 }
        local function rect(x, y, w, h, c)
            if w <= 0 or h <= 0 then return end
            scene.rect(s.layer, w, h, c):set_position(x, y)
        end
        if not sel then
            rect(box.x, box.y, box.width, box.height, dim)
            return
        end
        rect(box.x, box.y, box.width, sel.y - box.y, dim)
        rect(box.x, sel.y + sel.height, box.width, box.y + box.height - sel.y - sel.height, dim)
        rect(box.x, sel.y, sel.x - box.x, sel.height, dim)
        rect(sel.x + sel.width, sel.y, box.x + box.width - sel.x - sel.width, sel.height, dim)
        -- The edited area, on top.
        if s.work then show(s.layer, s.work, sel.x, sel.y, sel.width, sel.height) end
        local accent = theme.accent
        rect(sel.x - 1, sel.y - 1, sel.width + 2, 1, accent)
        rect(sel.x - 1, sel.y + sel.height, sel.width + 2, 1, accent)
        rect(sel.x - 1, sel.y, 1, sel.height, accent)
        rect(sel.x + sel.width, sel.y, 1, sel.height, accent)
        -- The toolbar stays on top.
        if s.toolbar and s.toolbar.tree then s.toolbar.tree:raise_to_top() end
    end

    -- Editing --------------------------------------------------------------------

    local TOOLS = { { "blur", "Blur", "b" }, { "pen", "Pen", "p" }, { "rect", "Box", "r" }, { "arrow", "Arrow", "a" } }

    local function stroke_color(s)
        local c = color.parse(palette[s.color_index], { 1, 0, 0, 1 })
        return pixels.argb(c[1], c[2], c[3], c[4])
    end

    -- Canvas coordinates of a layout point inside the selection.
    local function to_canvas(s, x, y)
        return (x - s.selection.x) * s.scale, (y - s.selection.y) * s.scale
    end

    local function finish(s, do_save, do_copy)
        local canvas = s.work
        stop()
        deliver(canvas, do_save, do_copy)
    end

    local function undo(s)
        local previous = table.remove(s.history)
        if previous then
            s.work = previous
            redraw(s)
        end
    end

    local open_toolbar

    -- The selection's pixels, from the frozen screen.
    local function crop(s)
        local sel = s.selection
        s.scale = s.canvas.width / s.box.width
        return pixels.crop(s.canvas, math.floor((sel.x - s.box.x) * s.scale), math.floor((sel.y - s.box.y) * s.scale),
            math.floor(sel.width * s.scale), math.floor(sel.height * s.scale))
    end

    local function start_editing(s)
        s.mode = "edit"
        s.work = crop(s)
        s.history, s.tool, s.color_index = {}, "pen", 1
        redraw(s)
        open_toolbar(s)
    end

    open_toolbar = function(s)
        if s.toolbar then s.toolbar:close() end
        s.toolbar = ui.view({
            theme = theme,
            parent = s.tree,
            render = function()
                local buttons = {}
                for _, t in ipairs(TOOLS) do
                    buttons[#buttons + 1] = ui.button(t[2], function()
                        s.tool = t[1]
                        s.toolbar:update()
                    end, { selected = s.tool == t[1] })
                end
                buttons[#buttons + 1] = ui.box(nil, { width = 22, height = 22, radius = 11,
                    background = palette[s.color_index], border = "#ffffff",
                    on_click = function()
                        s.color_index = s.color_index % #palette + 1
                        s.toolbar:update()
                    end })
                buttons[#buttons + 1] = ui.button("Undo", function() undo(s) end)
                if copy then buttons[#buttons + 1] = ui.button("Copy", function() finish(s, false, true) end) end
                buttons[#buttons + 1] = ui.button("Save", function() finish(s, true, copy) end, { selected = true })
                buttons[#buttons + 1] = ui.button("Cancel", stop)
                return ui.box(ui.row(buttons, { gap = 6 }), { padding = 8, radius = theme.radius,
                    background = theme.background, border = theme.border })
            end,
            place = function(width, height)
                local sel, box = s.selection, s.box
                local x = math.max(box.x + 8, math.min(sel.x + (sel.width - width) / 2, box.x + box.width - width - 8))
                local y = sel.y + sel.height + 12
                if y + height > box.y + box.height - 8 then y = math.max(box.y + 8, sel.y - height - 12) end
                return x, y
            end,
        })
    end

    -- Tool strokes: from the press to the release.
    local function begin_stroke(s, x, y)
        local cx, cy = to_canvas(s, x, y)
        s.stroke = { base = pixels.copy(s.work), x = cx, y = cy, last_x = cx, last_y = cy }
    end

    local function update_stroke(s, x, y)
        local st = s.stroke
        local cx, cy = to_canvas(s, x, y)
        local width = 4 * s.scale
        local p = stroke_color(s)
        if s.tool == "pen" then
            pixels.line(s.work, st.last_x, st.last_y, cx, cy, width, p)
            st.last_x, st.last_y = cx, cy
        else
            s.work = pixels.copy(st.base)
            local x0, y0 = math.min(st.x, cx), math.min(st.y, cy)
            local w, h = math.abs(cx - st.x), math.abs(cy - st.y)
            if s.tool == "rect" then
                pixels.outline(s.work, x0, y0, w, h, width, p)
            elseif s.tool == "arrow" then
                pixels.arrow(s.work, st.x, st.y, cx, cy, width, p)
            elseif s.tool == "blur" then
                pixels.outline(s.work, x0, y0, w, h, 1, pixels.argb(1, 1, 1, 0.8))
            end
        end
        redraw(s)
    end

    local function end_stroke(s, x, y)
        local st = s.stroke
        s.stroke = nil
        if not st then return end
        if s.tool == "blur" then
            local cx, cy = to_canvas(s, x, y)
            s.work = pixels.copy(st.base)
            pixels.blur(s.work, math.min(st.x, cx), math.min(st.y, cy), math.abs(cx - st.x), math.abs(cy - st.y),
                math.floor(8 * s.scale))
        else
            update_stroke(s, x, y)
        end
        s.history[#s.history + 1] = st.base
        redraw(s)
    end

    -- Picking ----------------------------------------------------------------------

    local function inside(rect, x, y)
        return x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height
    end

    local function pick(s, sel)
        -- Keep it on the output.
        local box = s.box
        local x0, y0 = math.max(box.x, sel.x), math.max(box.y, sel.y)
        local x1 = math.min(box.x + box.width, sel.x + sel.width)
        local y1 = math.min(box.y + box.height, sel.y + sel.height)
        if x1 - x0 < 1 or y1 - y0 < 1 then return end
        s.selection = { x = x0, y = y0, width = x1 - x0, height = y1 - y0 }
        if edit then
            start_editing(s)
        else
            local canvas = crop(s)
            stop()
            deliver(canvas, save_file, copy)
        end
    end

    local function on_key(ev)
        local s = session
        if not s or not ev.pressed then return end
        local name, ctrl = ev.name, ev.mods.ctrl
        if name == "Escape" then return stop() end
        if s.mode == "pick" then
            if name == "Return" or name == "KP_Enter" then pick(s, s.box) end
            return
        end
        if name == "Return" or name == "KP_Enter" then finish(s, save_file, copy)
        elseif ctrl and name == "c" then finish(s, false, true)
        elseif ctrl and name == "s" then finish(s, true, false)
        elseif ctrl and name == "z" then undo(s)
        elseif name == "c" then
            s.color_index = s.color_index % #palette + 1
            s.toolbar:update()
        else
            for _, t in ipairs(TOOLS) do
                if name == t[3] then
                    s.tool = t[1]
                    s.toolbar:update()
                end
            end
        end
    end

    local function on_button(button, pressed)
        local s = session
        if not s then return true end
        local x, y = boring.cursor()
        if s.mode == "pick" then
            if button ~= BUTTON_LEFT then return false end
            if pressed then
                s.drag = { x = x, y = y }
            elseif s.drag then
                local d = s.drag
                s.drag = nil
                if math.abs(x - d.x) < 4 and math.abs(y - d.y) < 4 then
                    -- A click: the window under the cursor.
                    local w = boring.window_at(x, y)
                    if w then pick(s, w:bounds()) end
                else
                    pick(s, { x = math.min(d.x, x), y = math.min(d.y, y), width = math.abs(x - d.x),
                        height = math.abs(y - d.y) })
                end
            end
            return false
        end
        -- Editing.
        if pressed then
            if s.toolbar and s.toolbar:contains(x, y) then
                s.toolbar:click(x, y, button)
            elseif button == BUTTON_LEFT and inside(s.selection, x, y) then
                begin_stroke(s, x, y)
            end
        elseif s.stroke then
            end_stroke(s, x, y)
        end
        return false
    end

    local function on_motion(x, y)
        local s = session
        if not s then return end
        if s.mode == "pick" and s.drag then
            local d = s.drag
            s.selection = { x = math.min(d.x, x), y = math.min(d.y, y), width = math.abs(x - d.x),
                height = math.abs(y - d.y) }
            redraw(s)
            s.selection = nil
        elseif s.stroke then
            update_stroke(s, x, y)
        end
    end

    -- Start a session on an output: the frozen screen, then picking.
    local function begin(o)
        stop()
        if not o then return end
        local canvas = capture.output(o)
        local box = o:box()
        local s = { output = o, box = box, canvas = canvas, mode = "pick" }
        s.redraw = function() redraw(s) end -- for scripts changing s.work
        s.tree = scene.tree(scene.layer("overlay"))
        show(s.tree, canvas, box.x, box.y, box.width, box.height)
        session = s
        redraw(s)
        s.release_keyboard = boring.grab_keyboard({ key = on_key })
        s.release_pointer = boring.grab_pointer({ cursor = "crosshair", motion = on_motion, button = on_button })
    end

    -- Direct captures: no picking, no editing.
    local function direct(box)
        local o = boring.output_at(box.x + box.width / 2, box.y + box.height / 2) or boring.outputs()[1]
        if not o then return end
        local canvas = capture.region(box, { scale = o:scale() })
        deliver(canvas, save_file, copy)
    end

    ctx.scope:defer(stop)

    local actions = {}
    function actions.area()
        begin(boring.output_at(boring.cursor()) or boring.outputs()[1])
    end
    function actions.fullscreen()
        local o = boring.output_at(boring.cursor()) or boring.outputs()[1]
        if o then direct(o:box()) end
    end
    function actions.window()
        local w = boring.focused()
        if w then direct(w:bounds()) end
    end
    --- Mark up the focused window (the editor, without picking).
    function actions.edit_window()
        local w = boring.focused()
        if not w then return end
        local b = w:bounds()
        local o = boring.output_at(b.x + b.width / 2, b.y + b.height / 2) or boring.outputs()[1]
        begin(o)
        if session then pick(session, b) end
    end

    return { actions = actions, session = function() return session end }
end

return plugin
