return function(t)
    local scope = require("shared.wl.scope")
    local plugins = require("compositor.plugin")

    local function server()
        return { scope = scope.new("test server") }
    end

    -- A plugin file recording what happens to it in `log`.
    local function write_plugin(dir, name, body)
        local path = dir .. "/" .. name .. ".lua"
        local f = assert(io.open(path, "w"))
        f:write(body or [[
local plugin = { name = "probe" }
function plugin:mount(config, ctx)
    ctx.state.mounts = (ctx.state.mounts or 0) + 1
    probe_log[#probe_log + 1] = "mount " .. tostring(config.value)
    ctx.scope:defer(function() probe_log[#probe_log + 1] = "closed" end)
    return { mounts = ctx.state.mounts, value = config.value }
end
return plugin
]])
        f:close()
        return path
    end

    local function setup()
        _G.probe_log = {}
        local dir = t.tmpdir("boring-plugins")
        return server(), dir
    end

    t.test("mount passes config and ctx; unmount closes ctx.scope", function()
        local s, dir = setup()
        local path = write_plugin(dir, "probe")
        local result = plugins.mount(s, path, { value = 1 })
        t.eq(result.value, 1)
        t.eq(plugins.list(s)[1], path)
        plugins.unmount(s, path)
        t.eq(table.concat(probe_log, ","), "mount 1,closed")
        t.eq(#plugins.list(s), 0)
    end)

    t.test("reload keeps unchanged plugins mounted and remounts changed ones", function()
        local s, dir = setup()
        local path = write_plugin(dir, "probe")
        local first = plugins.mount(s, path, { value = 1, cb = function() return 1 end })

        plugins.begin_reload(s)
        local again = plugins.mount(s, path, { value = 1, cb = function() return 1 end })
        plugins.end_reload(s, true)
        t.eq(again, first, "same config: same mount")
        t.eq(table.concat(probe_log, ","), "mount 1")

        plugins.begin_reload(s)
        local changed = plugins.mount(s, path, { value = 2 })
        plugins.end_reload(s, true)
        t.eq(changed.value, 2)
        t.eq(changed.mounts, 2, "ctx.state survives the remount")
        t.eq(table.concat(probe_log, ","), "mount 1,closed,mount 2")
    end)

    t.test("reload unmounts plugins the new config no longer mounts, unless it failed", function()
        local s, dir = setup()
        local path = write_plugin(dir, "probe")
        plugins.mount(s, path, { value = 1 })

        plugins.begin_reload(s)
        plugins.end_reload(s, false)
        t.eq(#plugins.list(s), 1, "a failed reload keeps plugins")

        plugins.begin_reload(s)
        plugins.end_reload(s, true)
        t.eq(#plugins.list(s), 0)
        t.eq(table.concat(probe_log, ","), "mount 1,closed")
    end)

    t.test("a plugin that fails to mount is reported and leaves nothing behind", function()
        local s, dir = setup()
        local path = write_plugin(dir, "broken", [[
return { name = "broken", mount = function(self, config, ctx)
    ctx.scope:defer(function() probe_log[#probe_log + 1] = "closed" end)
    error("nope")
end }
]])
        t.eq(plugins.mount(s, path, {}), nil)
        t.eq(#plugins.list(s), 0)
        t.eq(table.concat(probe_log, ","), "closed")
    end)

    t.test("libraries load once per compositor", function()
        local s, dir = setup()
        local path = write_plugin(dir, "library", [[
probe_log[#probe_log + 1] = "loaded"
return { value = 1 }
]])
        local a = plugins.require(s, path)
        local b = plugins.require(s, path)
        t.eq(a, b)
        t.eq(table.concat(probe_log, ","), "loaded")
        t.ok(not pcall(plugins.require, s, "@boring/does-not-exist"))
    end)
end
