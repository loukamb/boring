-- Drive a headless compositor with real Wayland clients. Each test skips if
-- its client isn't installed (the dev VM has them all; see dev/lima.yaml).

return function(t)
    local compositor = require("tests.harness.compositor")

    local function have(cmd)
        return os.execute("command -v " .. cmd .. " >/dev/null 2>&1") == 0
    end

    -- Pixel (r, g, b) at x, y of a binary PPM file.
    local function ppm_pixel(path, x, y)
        local f = assert(io.open(path, "rb"))
        local data = f:read("*a")
        f:close()
        local w, h, header_end = data:match("^P6%s+(%d+)%s+(%d+)%s+255%s()")
        assert(w, "not a PPM file")
        local offset = header_end + (y * tonumber(w) + x) * 3
        return data:byte(offset, offset + 2)
    end

    local function with_compositor(fn)
        local c, log = compositor.start({ config = "tests/fixtures/clients_config.lua" })
        if not c then
            error("compositor failed to start:\n" .. tostring(log))
        end
        local ok, err = pcall(fn, c)
        local final_log = c.stop()
        if not ok then error(tostring(err) .. "\ncompositor log:\n" .. final_log, 0) end
        t.ok(not final_log:match("err!"), final_log)
        t.ok(not final_log:match("fatal:"), final_log)
    end

    local function marker(c, name)
        local f = io.open(c.runtime_dir .. "/" .. name, "r")
        if f then f:close() end
        return f ~= nil
    end

    t.test("virtual keyboard triggers compositor shortcuts", function()
        if not have("wtype") then t.skip("wtype not installed") end
        with_compositor(function(c)
            local out, ok = c.exec("wtype -M logo -k F12 -m logo")
            t.ok(ok, out)
            c.exec("sleep 0.3")
            t.ok(marker(c, "key-shortcut"), "Super+F12 didn't fire")
        end)
    end)

    t.test("virtual pointer drives mouse shortcuts", function()
        if not (have("wtype") and have("wlrctl")) then t.skip("wtype/wlrctl not installed") end
        with_compositor(function(c)
            local out, ok = c.exec("wtype -M logo -s 1500 -m logo & sleep 0.5; wlrctl pointer click left; wait")
            t.ok(ok, out)
            c.exec("sleep 0.3")
            t.ok(marker(c, "mouse-shortcut"), "Super+LeftMouseDrag didn't fire")
        end)
    end)

    t.test("clipboard and primary selection round-trip", function()
        if not have("wl-copy") then t.skip("wl-clipboard not installed") end
        with_compositor(function(c)
            -- wl-copy forks a daemon to serve the selection: detach its output.
            c.exec("wl-copy 'hello boring' >/dev/null 2>&1")
            local out = c.exec("wl-paste --no-newline")
            t.eq(out, "hello boring")
            c.exec("wl-copy --primary 'middle click' >/dev/null 2>&1")
            out = c.exec("wl-paste --primary --no-newline")
            t.eq(out, "middle click")
        end)
    end)

    t.test("output management lists outputs", function()
        if not have("wlr-randr") then t.skip("wlr-randr not installed") end
        with_compositor(function(c)
            local out, ok = c.exec("wlr-randr")
            t.ok(ok, out)
            t.ok(out:find("HEADLESS%-1"), out)
        end)
    end)

    t.test("session lock blanks the screen and survives a crashed locker", function()
        if not (have("swaylock") and have("grim")) then t.skip("swaylock/grim not installed") end
        with_compositor(function(c)
            local before = c.runtime_dir .. "/before.ppm"
            c.exec("grim -t ppm " .. before)
            local r, g, b = ppm_pixel(before, 10, 10)
            t.eq(r + g + b, 255 * 3, "wallpaper should be white before locking")

            c.exec("swaylock --color 0000ff >/dev/null 2>&1 & echo $! > " .. c.runtime_dir .. "/swaylock.pid; sleep 1")
            local locked = c.runtime_dir .. "/locked.ppm"
            c.exec("grim -t ppm " .. locked)
            r, g, b = ppm_pixel(locked, 10, 10)
            t.ok(r < 30 and g < 30 and b > 200, string.format("expected the blue lock screen, got %d,%d,%d", r, g, b))

            -- Kill the locker without unlocking: the screen must stay covered.
            c.exec("kill -9 $(cat " .. c.runtime_dir .. "/swaylock.pid); sleep 0.5")
            local crashed = c.runtime_dir .. "/crashed.ppm"
            c.exec("grim -t ppm " .. crashed)
            r, g, b = ppm_pixel(crashed, 10, 10)
            t.eq(r + g + b, 0, "screen must stay blanked after the locker dies")
        end)
    end)
end
