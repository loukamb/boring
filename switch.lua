#!/usr/bin/luajit
package.path = "./?/init.lua;./?.lua;" .. package.path

local args = require("shared.args").parse(...)
local switch_to = table.remove(args.positional, 1)

-- Handle --ffi-cleanup to clear FFI cdef cache
if switch_to == "--ffi-cleanup" or args["ffi-cleanup"] then
    local cache_dir = os.getenv("HOME") .. "/.config/boring/ffi-cache"
    os.execute("rm -rf " .. cache_dir)
    print("FFI cache cleared: " .. cache_dir)
    os.exit(0)
end

if not switch_to then
    print("Usage: luajit switch.lua <module> [options]")
    print("       luajit switch.lua --ffi-cleanup")
    os.exit(1)
end
require(switch_to)(args)
