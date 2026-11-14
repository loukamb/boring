#!/usr/bin/env luajit
-- boring's entry point. Run from the repository:
--
--   ./boring.lua [--config=path] [--protocols[=missing|implemented]]
--                                       start the compositor
--   ./boring.lua run <module> [options] run one of boring's programs
--                                       (e.g. clients.wallpaper)
package.path = "./?/init.lua;./?.lua;" .. package.path

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
