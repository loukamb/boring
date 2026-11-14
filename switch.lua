#!/usr/bin/luajit
package.path = "./?/init.lua;./?.lua;" .. package.path

local args = require("shared.args").parse(...)
local switch_to = table.remove(args.positional, 1)

if not switch_to then
    print("Usage: luajit switch.lua <module> [options]")
    os.exit(1)
end
require(switch_to)(args)
