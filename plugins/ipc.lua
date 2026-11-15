-- plugins/ipc.lua
-- Run Lua inside the running compositor from a shell:
--
--   plugin("@boring/ipc"):mount()
--
--   ./boring.lua -e 'return #boring.windows()'
--   ./boring.lua -e 'boring.focused():close()'
--   echo 'return boring.outputs()[1].name' | ./boring.lua -e -
--   ./boring.lua -i                                -- a REPL
--
-- Code runs in the config environment: what the config defined (locals
-- excepted), then boring, require, actions, color, ...; globals it sets
-- persist between calls. Expressions don't need a
-- `return`. What it returns and prints is sent back.
--
-- The socket is $XDG_RUNTIME_DIR/boring-$WAYLAND_DISPLAY, mode 0600: only
-- you can use it. It's deliberately not a Wayland protocol, which any
-- client (sandboxed ones too) could reach.

local socket = require("shared.socket")
local inspect = require("shared.inspect")

local plugin = { name = "ipc" }

-- Run a chunk; returns ok and the text to send back.
local function evaluate(env, code)
    local fn, err = loadstring("return " .. code, "=ipc")
    if not fn then fn, err = loadstring(code, "=ipc") end
    if not fn then return false, err end
    local out = {}
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        out[#out + 1] = table.concat(parts, "\t")
    end
    setfenv(fn, env)
    local results = { xpcall(fn, debug.traceback) }
    if not results[1] then
        out[#out + 1] = tostring(results[2])
        return false, table.concat(out, "\n")
    end
    local values = {}
    for i = 2, table.maxn(results) do values[#values + 1] = inspect(results[i]) end
    if #values > 0 then out[#out + 1] = table.concat(values, "\t") end
    return true, table.concat(out, "\n")
end

function plugin:mount(config, ctx)
    -- Calls share globals: a table over the config's globals, then the
    -- plugin environment.
    local plugin_env = getfenv(1)
    local env = setmetatable({}, { __index = function(_, k)
        local config_env = boring.config_env()
        local v = config_env and rawget(config_env, k)
        if v ~= nil then return v end
        return plugin_env[k]
    end })
    local clients = {}
    local result = {}

    local function drop(client)
        if not clients[client] then return end
        clients[client].stop()
        clients[client] = nil
        socket.close(client)
    end

    local function serve(client)
        local c = clients[client]
        local status = socket.read_some(client, c.chunks)
        if status == "again" then return end
        if status == "eof" then
            local ok, text = evaluate(env, table.concat(c.chunks))
            socket.set_blocking(client)
            socket.write_all(client, (ok and "0\n" or "1\n") .. text)
        end
        drop(client)
    end

    -- Listen once the Wayland socket exists (the config runs before it does).
    local function start()
        local path = config.path or socket.path(boring.socket())
        if not path then
            boring.log.warn("ipc: no XDG_RUNTIME_DIR; not listening")
            return
        end
        local fd, err = socket.listen(path)
        if not fd then
            boring.log.warn("ipc: can't listen on %s: %s", path, tostring(err))
            return
        end
        result.path = path
        local stop_listening = boring.on_readable(fd, function()
            while true do
                local client = socket.accept(fd)
                if not client then return end
                clients[client] = { chunks = {} }
                clients[client].stop = boring.on_readable(client, function() serve(client) end)
            end
        end)
        ctx.scope:defer(function()
            stop_listening()
            for client in pairs(clients) do drop(client) end
            socket.close(fd)
            socket.unlink(path)
        end)
    end

    if boring.socket() then
        start()
    else
        local handle
        handle = ctx.scope:subscribe(boring.events, "ready", function()
            handle:off()
            start()
        end)
    end
    return result
end

return plugin
