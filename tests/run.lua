#!/usr/bin/env luajit

package.path = "./?/init.lua;./?.lua;" .. package.path

local files = {
    "tests/test_args.lua",
    "tests/test_xml.lua",
    "tests/test_runtime.lua",
    "tests/test_events.lua",
    "tests/test_input.lua",
    "tests/test_color_hash.lua",
    "tests/test_clib_protocol.lua",
    "tests/test_monitor_output.lua",
    "tests/test_tiling.lua",
    "tests/test_borders.lua",
    "tests/test_listeners.lua",
}

local total = 0
local failed = 0

local function render(value)
    if type(value) == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end

local ctx = {}

function ctx.ok(value, message)
    if not value then
        error(message or "expected truthy value", 2)
    end
end

function ctx.eq(actual, expected, message)
    if actual ~= expected then
        error(string.format(
            "%s\nexpected: %s\nactual:   %s",
            message or "values differ",
            render(expected),
            render(actual)
        ), 2)
    end
end

function ctx.test(name, fn)
    total = total + 1
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        io.write(string.format("ok %d - %s\n", total, name))
    else
        failed = failed + 1
        io.stderr:write(string.format("not ok %d - %s\n%s\n", total, name, err))
    end
end

for _, file in ipairs(files) do
    local chunk, err = loadfile(file)
    if not chunk then
        error(err)
    end
    local tests = chunk()
    if type(tests) == "function" then
        tests(ctx)
    end
end

if failed > 0 then
    io.stderr:write(string.format("%d/%d tests failed\n", failed, total))
    os.exit(1)
end

io.write(string.format("%d tests passed\n", total))
