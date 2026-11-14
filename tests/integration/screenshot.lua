-- Screenshots without external tools: capture, save, copy, edit.

return function(t)
    local compositor = require("tests.harness.compositor")

    local function have(cmd)
        return os.execute("command -v " .. cmd .. " >/dev/null 2>&1") == 0
    end

    local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

    local function with_compositor(fn)
        local c, log = compositor.start({ config = "tests/fixtures/screenshot_config.lua" })
        if not c then error("compositor failed to start:\n" .. tostring(log)) end
        local function ipc(code) return c.exec("luajit boring.lua -e " .. quote(code)) end
        local ok, err = pcall(fn, c, ipc)
        local final_log = c.stop()
        if not ok then error(tostring(err) .. "\ncompositor log:\n" .. final_log, 0) end
        t.ok(not final_log:match("err!"), final_log)
    end

    t.test("capture reads the scene back", function()
        with_compositor(function(_, ipc)
            local out = ipc([[local c = require("@boring/library/capture").region({ x = 5, y = 5, width = 4, height = 4 })
return string.format("%dx%d %08x", c.width, c.height, c.data[0])]])
            t.eq(out, '"4x4 ffff0000"')
        end)
    end)

    t.test("fullscreen saves a PNG and copies it", function()
        with_compositor(function(c, ipc)
            local out, ok = ipc("screenshot.actions.fullscreen()")
            t.ok(ok, out)
            local files = c.exec("ls " .. c.runtime_dir .. "/shots")
            t.ok(files:match("screenshot%-.*%.png"), files)
            local magic = c.exec("head -c 8 " .. c.runtime_dir .. "/shots/*.png | od -An -c | tr -d ' \\n'")
            t.ok(magic:find("PNG", 1, true), magic)
            if have("wl-paste") then
                local types = c.exec("wl-paste --list-types")
                t.ok(types:find("image/png", 1, true), types)
                local pasted = c.exec("wl-paste -t image/png | head -c 4 | od -An -c | tr -d ' \\n'")
                t.ok(pasted:find("PNG", 1, true), pasted)
            end
        end)
    end)

    t.test("the editor marks up a window and saves on Enter", function()
        if not (have("foot") and have("wtype")) then t.skip("foot/wtype not installed") end
        with_compositor(function(c, ipc)
            c.exec("setsid foot >/dev/null 2>&1 &")
            for _ = 1, 50 do
                if ipc("#boring.windows()") == "1" then break end
                c.exec("sleep 0.1")
            end
            c.exec("sleep 0.3")
            ipc("screenshot.actions.edit_window()")
            t.eq(ipc("screenshot.session().mode"), '"edit"')
            -- Draw on it through the editor's own code path, then finish.
            ipc([[local s = screenshot.session() s.work.data[0] = 0xff00ff00]])
            c.exec("wtype -k Return; sleep 0.3")
            t.eq(ipc("screenshot.session() == nil"), "true")
            local files = c.exec("ls " .. c.runtime_dir .. "/shots")
            t.ok(files:match("%.png"), files)
        end)
    end)
end
