-- Window management end to end: real clients, a headless compositor, and
-- the ipc plugin to look inside it.

return function(t)
    local compositor = require("tests.harness.compositor")

    local function have(cmd)
        return os.execute("command -v " .. cmd .. " >/dev/null 2>&1") == 0
    end

    local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

    local function with_compositor(fn)
        local c, log = compositor.start({ config = "tests/fixtures/windows_config.lua" })
        if not c then error("compositor failed to start:\n" .. tostring(log)) end
        local function ipc(code)
            local out, ok = c.exec("luajit boring.lua -e " .. quote(code))
            return out, ok
        end
        -- Wait until `code` returns true.
        local function wait(code, what)
            for _ = 1, 50 do
                if ipc(code) == "true" then return end
                c.exec("sleep 0.1")
            end
            error("timed out waiting for " .. what)
        end
        local ok, err = pcall(fn, c, ipc, wait)
        local final_log = c.stop()
        if not ok then error(tostring(err) .. "\ncompositor log:\n" .. final_log, 0) end
        t.ok(not final_log:match("err!"), final_log)
    end

    local function open(c, app_id)
        c.exec("setsid foot --app-id=" .. app_id .. " >/dev/null 2>&1 &")
    end

    -- Bounds of the window with an app id, as "x y w h".
    local function bounds(ipc, app_id)
        return (ipc(string.format([[
for _, w in ipairs(boring.windows()) do
    if w:app_id() == %q then local b = w:bounds() print(b.x .. " " .. b.y .. " " .. b.width .. " " .. b.height) end
end]], app_id)))
    end

    local function mapped(app_id)
        return string.format([[
for _, w in ipairs(boring.windows()) do if w:app_id() == %q and w:geometry().width > 0 then return true end end
return false]], app_id)
    end

    t.test("ipc runs Lua in the compositor and reports errors", function()
        with_compositor(function(_, ipc)
            local out, ok = ipc("1 + 2")
            t.ok(ok, out)
            t.eq(out, "3")
            out, ok = ipc("x = 5")
            t.ok(ok, out)
            t.eq(ipc("x * 2"), "10") -- globals persist
            t.eq(ipc("print('hi') return 'there'"), 'hi\n"there"')
            out, ok = ipc("error('nope')")
            t.ok(not ok)
            t.ok(out:find("nope", 1, true), out)
        end)
    end)

    t.test("tiling, rules, workspaces, fullscreen and minimize", function()
        if not have("foot") then t.skip("foot not installed") end
        with_compositor(function(c, ipc, wait)
            local out = ipc("local o = boring.outputs()[1] local b = o:box() print(b.width .. ' ' .. b.height)")
            local width, height = out:match("(%d+) (%d+)")
            width, height = tonumber(width), tonumber(height)

            open(c, "one")
            wait(mapped("one"), "one")
            c.exec("sleep 0.3")
            t.eq(bounds(ipc, "one"), string.format("0 0 %d %d", width, height))
            open(c, "two")
            wait(mapped("two"), "two")
            c.exec("sleep 0.3")
            -- Side by side.
            t.eq(bounds(ipc, "one"), string.format("0 0 %d %d", width / 2, height))
            t.eq(bounds(ipc, "two"), string.format("%d 0 %d %d", width / 2, width / 2, height))

            -- A rule: floating, 300x200, centred, out of the tree.
            open(c, "float-me")
            wait(mapped("float-me"), "float-me")
            c.exec("sleep 0.3")
            -- Untiled, foot rounds its size to whole cells.
            local x, y, w, h = bounds(ipc, "float-me"):match("(%d+) (%d+) (%d+) (%d+)")
            t.eq(tonumber(x) .. " " .. tonumber(y), string.format("%d %d", (width - 300) / 2, (height - 200) / 2))
            t.ok(math.abs(w - 300) < 20 and math.abs(h - 200) < 30, w .. "x" .. h)
            t.eq(bounds(ipc, "one"), string.format("0 0 %d %d", width / 2, height))

            -- A rule: straight to workspace 3, hidden.
            open(c, "third")
            wait(mapped("third"), "third")
            t.eq(ipc([[for _, w in ipairs(boring.windows()) do if w:app_id() == "third" then return w:visible() end end]]),
                "false")
            ipc([[require("@boring/library/workspaces").switch(3)]])
            t.eq(ipc([[for _, w in ipairs(boring.windows()) do if w:app_id() == "third" then return w:visible() end end]]),
                "true")
            t.eq(ipc("boring.focused():app_id()"), '"third"')
            ipc([[require("@boring/library/workspaces").switch(1)]])
            t.eq(ipc("boring.focused():visible()"), "true")

            -- Fullscreen fills the output; leaving it puts the tile back.
            local find_two = [[local w for _, x in ipairs(boring.windows()) do if x:app_id() == "two" then w = x end end ]]
            ipc(find_two .. [[boring.events:emit("window:request_fullscreen", w, true)]])
            c.exec("sleep 0.3")
            t.eq(bounds(ipc, "two"), string.format("0 0 %d %d", width, height))
            ipc(find_two .. [[boring.events:emit("window:request_fullscreen", w, false)]])
            c.exec("sleep 0.3")
            t.eq(bounds(ipc, "two"), string.format("%d 0 %d %d", width / 2, width / 2, height))

            -- Minimizing takes it out of the tree; focusing brings it back.
            ipc(find_two .. [[boring.events:emit("window:request_minimize", w)]])
            c.exec("sleep 0.3")
            t.eq(bounds(ipc, "one"), string.format("0 0 %d %d", width, height))
            ipc(find_two .. [[boring.focus(w)]])
            c.exec("sleep 0.3")
            t.eq(bounds(ipc, "two"), string.format("%d 0 %d %d", width / 2, width / 2, height))
        end)
    end)

    t.test("stacking maximizes; master and stack arranges", function()
        if not have("foot") then t.skip("foot not installed") end
        with_compositor(function(c, ipc, wait)
            local out = ipc("local b = boring.outputs()[1]:box() print(b.width .. ' ' .. b.height)")
            local width, height = out:match("(%d+) (%d+)")
            width, height = tonumber(width), tonumber(height)

            -- Swap tiling for stacking at runtime, through the same API a config uses.
            ipc([[plugin("@boring/layout-tiling"):unmount() stacking = plugin("@boring/layout-stacking"):mount()]])
            open(c, "one")
            wait(mapped("one"), "one")
            ipc("stacking.actions.maximize()")
            c.exec("sleep 0.3")
            t.eq(bounds(ipc, "one"), string.format("0 0 %d %d", width, height))
            ipc("stacking.actions.maximize()")
            c.exec("sleep 0.3")
            t.ok(bounds(ipc, "one") ~= string.format("0 0 %d %d", width, height))

            ipc([[plugin("@boring/layout-stacking"):unmount()
master = plugin("@boring/layout-master"):mount({ ratio = 0.5, gaps = { inner = 0, outer = 0 } })]])
            open(c, "two")
            wait(mapped("two"), "two")
            c.exec("sleep 0.3")
            -- The newest window is the master, on the left.
            t.eq(bounds(ipc, "two"), string.format("0 0 %d %d", width / 2, height))
            t.eq(bounds(ipc, "one"), string.format("%d 0 %d %d", width / 2, width / 2, height))
            ipc("master.actions.zoom()")
            c.exec("sleep 0.3")
            t.eq(bounds(ipc, "one"), string.format("0 0 %d %d", width / 2, height))
        end)
    end)

    t.test("idle turns the screens off after the timeout; input turns them on", function()
        with_compositor(function(c, ipc)
            ipc([[plugin("@boring/idle"):mount({ screens = { timeout = 0.5 } })]])
            t.eq(ipc("boring.outputs()[1].wlr.enabled"), "true")
            c.exec("sleep 1")
            t.eq(ipc("boring.outputs()[1].wlr.enabled"), "false")
            local out, ok = c.exec("wtype -k a 2>&1")
            if not ok then
                -- No virtual keyboard: count as input directly.
                ipc([[require("compositor.idle").activity(boring.server)]])
            end
            c.exec("sleep 0.2")
            t.eq(ipc("boring.outputs()[1].wlr.enabled"), "true", out)
        end)
    end)
end
