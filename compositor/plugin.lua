-- Plugins: loading, mounting, and keeping them across config reloads.
--
-- A plugin is a Lua file returning a table:
--
--   local plugin = { name = "my-plugin" }
--   function plugin:mount(config, ctx)
--       ctx.scope:subscribe(boring.events, "window:map", function(w) ... end)
--       ctx.state.count = (ctx.state.count or 0) + 1   -- survives reloads
--       return { ... }                                 -- what :mount() returns
--   end
--   function plugin:unmount() end                      -- optional
--   return plugin
--
-- `ctx.scope` is closed when the plugin is unmounted, so anything registered
-- through it is undone. `ctx.state` belongs to the plugin's name and outlives
-- reloads (not restarts).
--
-- On a config reload, a plugin whose file and config are unchanged stays
-- mounted; the config gets the same return value back. Plugins the new config
-- doesn't mount are unmounted afterwards.
--
-- Libraries (`require("@boring/library/<name>")`) are shared code for
-- plugins. Each loads once per compositor and is kept across reloads.

local log = require("shared.log")
local paths = require("compositor.config.paths")
local equal = require("shared.equal")

local plugin = {}

local function registry(server)
    local r = server.plugins
    if not r then
        r = {
            mounted = {},   -- name -> entry
            order = {},     -- names, in mount order
            state = {},     -- name -> ctx.state
            libraries = {}, -- path -> value
            reloading = nil, -- name -> true for plugins not yet mounted again
        }
        server.plugins = r
    end
    return r
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function boring_api()
    return require("compositor.api").current()
end

-- The environment plugin and library code runs in: the config globals
-- (`boring`, `color`, `actions`, ...) and a `require` that knows `@boring/`.
-- One per server, so it doesn't depend on which config loaded the plugin.
local function environment(server)
    local r = registry(server)
    if r.env then return r.env end
    local env = {}
    for k, v in pairs(require("compositor.config").default_environment) do env[k] = v end
    env.boring = boring_api()
    env.require = function(name) return plugin.require(server, name) end
    setmetatable(env, { __index = _G })
    r.env = env
    return env
end

local function run_file(server, path, source)
    local fn, err = loadstring(source, "@" .. path)
    if not fn then return nil, err end
    setfenv(fn, environment(server))
    local ok, result = xpcall(fn, debug.traceback)
    if not ok then return nil, result end
    return result
end

--- `require` for config and plugins: `@boring/...` and paths to .lua files
--- resolve like plugins and load once per compositor; anything else is Lua's.
function plugin.require(server, name)
    local is_path = name:match("%.lua$") and name:find("/", 1, true)
    if name:sub(1, 1) ~= "@" and not is_path then return require(name) end
    local r = registry(server)
    local path = paths.resolve_plugin(name)
    if not path then error("module not found: " .. name, 2) end
    local cached = r.libraries[path]
    if cached ~= nil then return cached end
    local result, err = run_file(server, path, read(path))
    if err then error(string.format("loading %s: %s", name, err), 2) end
    if result == nil then result = true end
    r.libraries[path] = result
    return result
end

local function remove_from_order(r, name)
    for i, n in ipairs(r.order) do
        if n == name then
            table.remove(r.order, i)
            return
        end
    end
end

--- Unmount a plugin by name.
function plugin.unmount(server, name)
    local r = registry(server)
    local entry = r.mounted[name]
    if not entry then return end
    r.mounted[name] = nil
    remove_from_order(r, name)
    if entry.module.unmount then
        local ok, err = xpcall(entry.module.unmount, debug.traceback, entry.module)
        if not ok then log.error("plugin %s: unmount failed: %s", name, tostring(err)) end
    end
    entry.scope:close()
end

--- Mount a plugin (by name, as given to `plugin(...)`) with a config table.
--- Returns what the plugin's mount returned, or nil if it failed.
function plugin.mount(server, name, config)
    local r = registry(server)
    config = config or {}
    local path = paths.resolve_plugin(name)
    if not path then
        log.error("plugin %s not found", name)
        return nil
    end
    local source = read(path)

    local entry = r.mounted[name]
    if entry then
        if r.reloading and r.reloading[name] then
            r.reloading[name] = nil
            if entry.source == source and equal(entry.config, config) then
                -- Unchanged: keep it, in the new config's order.
                remove_from_order(r, name)
                table.insert(r.order, name)
                return entry.result
            end
        else
            log.warn("plugin %s is already mounted", name)
            return entry.result
        end
        plugin.unmount(server, name)
    end

    local module, err = run_file(server, path, source)
    if type(module) ~= "table" and not err then err = "a plugin must return a table" end
    if err then
        log.error("plugin %s: %s", name, tostring(err))
        return nil
    end

    r.state[name] = r.state[name] or {}
    local ctx = {
        name = name,
        path = path,
        scope = server.scope:child("plugin " .. name),
        state = r.state[name],
    }
    local result
    if module.mount then
        local ok, res = xpcall(module.mount, debug.traceback, module, config, ctx)
        if not ok then
            log.error("plugin %s: mount failed: %s", name, tostring(res))
            ctx.scope:close()
            return nil
        end
        result = res
    end
    if result == nil then result = {} end

    r.mounted[name] = {
        module = module,
        source = source,
        config = config,
        scope = ctx.scope,
        result = result,
    }
    table.insert(r.order, name)
    return result
end

--- What `plugin(name)` returns in the config: a handle with :mount/:unmount.
function plugin.handle(server, name)
    return {
        mount = function(_, config) return plugin.mount(server, name, config) end,
        unmount = function() plugin.unmount(server, name) end,
    }
end

--- Before running a reloaded config: every mounted plugin is pending until
--- the new config mounts it again.
function plugin.begin_reload(server)
    local r = registry(server)
    r.reloading = {}
    for name in pairs(r.mounted) do r.reloading[name] = true end
end

--- After the config ran: unmount what it didn't mount (`ok`), or keep
--- everything if it failed part-way.
function plugin.end_reload(server, ok)
    local r = registry(server)
    local pending = r.reloading or {}
    r.reloading = nil
    if not ok then return end
    for i = #r.order, 1, -1 do
        local name = r.order[i]
        if pending[name] then plugin.unmount(server, name) end
    end
end

--- Unmount every plugin, last mounted first.
function plugin.unmount_all(server)
    local r = registry(server)
    for i = #r.order, 1, -1 do
        plugin.unmount(server, r.order[i])
    end
end

--- Names of the mounted plugins, in mount order.
function plugin.list(server)
    local r = registry(server)
    local out = {}
    for i, name in ipairs(r.order) do out[i] = name end
    return out
end

return plugin
