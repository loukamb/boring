#!/usr/bin/env luajit
-- boring's entry point. Run from the repository:
--
--   ./boring.lua [--config=path] [--protocols[=missing|implemented]]
--                                       start the compositor
--   ./boring.lua run <module> [options] run one of boring's programs
--                                       (e.g. clients.wallpaper)
--   ./boring.lua -e '<lua>' | -e - | -i run Lua in the running compositor
--                                       (needs the ipc plugin)
package.path = "./?/init.lua;./?.lua;" .. package.path

local raw = { ... }
for i, v in ipairs(raw) do
    if v == "-e" or v == "-i" then
        local code = v == "-e" and raw[i + 1] or nil
        if v == "-e" and not code then
            io.stderr:write("usage: ./boring.lua -e '<lua>' | -e -\n")
            os.exit(1)
        end
        local rest = {}
        for j, x in ipairs(raw) do
            if j ~= i and not (v == "-e" and j == i + 1) then rest[#rest + 1] = x end
        end
        require("clients.ipc")(v == "-i" and "repl" or "eval", code, require("shared.args").parse(unpack(rest)))
        return
    end
end

local args = require("shared.args").parse(...)

if args.positional[1] == "run" then
    table.remove(args.positional, 1)
    local program = table.remove(args.positional, 1)
    if not program then
        io.stderr:write("usage: ./boring.lua run <module> [options]\n")
        os.exit(1)
    end
    require(program)(args)
else
    require("compositor")(args)
end
