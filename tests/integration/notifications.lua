-- Notifications over D-Bus, through each installed client library. Uses the
-- session bus the tests run under (DBUS_SESSION_BUS_ADDRESS).

return function(t)
    local compositor = require("tests.harness.compositor")

    local function have(cmd)
        return os.execute("command -v " .. cmd .. " >/dev/null 2>&1") == 0
    end

    local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

    local function with_compositor(fn)
        local c, log = compositor.start({ config = "tests/fixtures/minimal_ipc_config.lua" })
        if not c then error("compositor failed to start:\n" .. tostring(log)) end
        local function ipc(code) return c.exec("luajit boring.lua -e " .. quote(code)) end
        local ok, err = pcall(fn, c, ipc)
        local final_log = c.stop()
        if not ok then error(tostring(err) .. "\ncompositor log:\n" .. final_log, 0) end
        t.ok(not final_log:match("err!"), final_log)
        return final_log
    end

    local function bus_available()
        return os.getenv("DBUS_SESSION_BUS_ADDRESS") ~= nil and have("gdbus") and have("notify-send")
    end

    for _, backend in ipairs({ "sd-bus", "libdbus" }) do
        t.test("notifications over D-Bus with " .. backend, function()
            if not bus_available() then t.skip("no session bus or gdbus/notify-send") end
            with_compositor(function(c, ipc)
                local out, ok = ipc(string.format([[n = plugin("@boring/notifications"):mount({ dbus = %q })
return n.backend]], backend))
                t.ok(ok and out:find(backend, 1, true), out)

                out = c.exec("gdbus call --session --dest org.freedesktop.Notifications "
                    .. "--object-path /org/freedesktop/Notifications "
                    .. "--method org.freedesktop.Notifications.GetServerInformation")
                t.ok(out:find("'boring'", 1, true), out)

                out = c.exec("notify-send -p 'Hello' 'World <b>bold</b> &amp; more'")
                local id = tonumber(out:match("(%d+)"))
                t.ok(id, out)
                t.eq(ipc("n.shown()[1].title"), '"Hello"')
                t.eq(ipc("n.shown()[1].body"), '"World bold & more"')

                -- Replace it, with an action, critical (no expiry).
                out = c.exec("gdbus call --session --dest org.freedesktop.Notifications "
                    .. "--object-path /org/freedesktop/Notifications "
                    .. "--method org.freedesktop.Notifications.Notify \"'app'\" 'uint32 " .. id
                    .. "' \"''\" \"'Again'\" \"'Body'\" \"['ok', 'OK']\" \"{'urgency': <byte 2>}\" 'int32 -1'")
                t.ok(out:find("uint32 " .. id, 1, true), out)
                t.eq(ipc("#n.shown()"), "1")
                t.eq(ipc("n.shown()[1].title .. n.shown()[1].timeout .. n.shown()[1].actions[1].key"), '"Again0ok"')

                c.exec("gdbus call --session --dest org.freedesktop.Notifications "
                    .. "--object-path /org/freedesktop/Notifications "
                    .. "--method org.freedesktop.Notifications.CloseNotification " .. id)
                t.eq(ipc("#n.shown()"), "0")
                t.eq(ipc("#n.history()"), "2")
            end)
        end)
    end

    t.test("notifications without D-Bus warn and still work for plugins", function()
        with_compositor(function(_, ipc)
            local out, ok = ipc([[n = plugin("@boring/notifications"):mount({ dbus = "none" })
return n.notify({ title = "Local", timeout = 50 })]])
            t.ok(ok, out)
            t.eq(ipc("#n.shown()"), "1")
            require("os").execute("sleep 0.4")
            t.eq(ipc("#n.shown()"), "0")
        end)
    end)
end
