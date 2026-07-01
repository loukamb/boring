#!/usr/bin/env luajit

package.path = "./?/init.lua;./?.lua;" .. package.path

local function parse_args(...)
    local parsed = { positional = {} }
    local i = 1
    local n = select("#", ...)
    while i <= n do
        local value = select(i, ...)
        if value and value:sub(1, 2) == "--" then
            local eq = value:find("=", 1, true)
            if eq then
                parsed[value:sub(3, eq - 1)] = value:sub(eq + 1)
            else
                local key = value:sub(3)
                local next_value = i < n and select(i + 1, ...) or nil
                if next_value and next_value:sub(1, 2) ~= "--" then
                    parsed[key] = next_value
                    i = i + 1
                else
                    parsed[key] = true
                end
            end
        elseif value ~= nil then
            table.insert(parsed.positional, value)
        end
        i = i + 1
    end
    return parsed
end

local args = parse_args(...)

local suites = {
    unit = { "tests/unit" },
    service = { "tests/service" },
    integration = { "tests/integration" },
}
suites.all = { "tests/unit", "tests/service", "tests/integration" }

local selected_suite = args.suite or "all"
local format = args.format or (os.getenv("CI") and "tap" or "pretty")

if not suites[selected_suite] then
    io.stderr:write(string.format("unknown suite %q\n", selected_suite))
    os.exit(2)
end

if format ~= "pretty" and format ~= "tap" then
    io.stderr:write(string.format("unknown format %q\n", format))
    os.exit(2)
end

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function discover(paths)
    local files = {}
    for _, path in ipairs(paths) do
        local command = "find " .. shell_quote(path) .. " -type f -name '*.lua' | sort"
        local pipe = io.popen(command)
        if pipe then
            for file in pipe:lines() do
                if file ~= "" then
                    table.insert(files, file)
                end
            end
            pipe:close()
        end
    end
    return files
end

local files = discover(suites[selected_suite])
local total = 0
local failed = 0
local skipped = 0

local function render(value)
    if type(value) == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end

local function escape_tap(value)
    return tostring(value):gsub("\\", "\\\\"):gsub("\n", "\\n")
end

local function report(status, name, err)
    if format == "tap" then
        if status == "ok" then
            io.write(string.format("ok %d - %s\n", total, escape_tap(name)))
        elseif status == "skip" then
            io.write(string.format("ok %d - %s # SKIP %s\n", total, escape_tap(name), escape_tap(err)))
        else
            io.write(string.format("not ok %d - %s\n", total, escape_tap(name)))
            io.write("  ---\n")
            io.write(string.format("  message: %q\n", tostring(err)))
            io.write("  ...\n")
        end
        return
    end

    if status == "ok" then
        io.write(string.format("ok %d - %s\n", total, name))
    elseif status == "skip" then
        io.write(string.format("skip %d - %s: %s\n", total, name, err))
    else
        io.stderr:write(string.format("not ok %d - %s\n%s\n", total, name, err))
    end
end

local ctx = {
    _cleanups = nil,
}

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

function ctx.near(actual, expected, epsilon, message)
    epsilon = epsilon or 0.000001
    if type(actual) ~= "number" or type(expected) ~= "number" or math.abs(actual - expected) > epsilon then
        error(string.format(
            "%s\nexpected: %s +/- %s\nactual:   %s",
            message or "values are not near",
            render(expected),
            render(epsilon),
            render(actual)
        ), 2)
    end
end

function ctx.matches(value, pattern, message)
    if type(value) ~= "string" or not value:match(pattern) then
        error(string.format(
            "%s\nexpected %s to match %q",
            message or "pattern did not match",
            render(value),
            pattern
        ), 2)
    end
end

function ctx.raises(fn, pattern, message)
    local ok, err = pcall(fn)
    if ok then
        error(message or "expected function to raise", 2)
    end
    if pattern and not tostring(err):match(pattern) then
        error(string.format(
            "%s\nexpected error matching %q\nactual: %s",
            message or "unexpected error",
            pattern,
            tostring(err)
        ), 2)
    end
    return err
end

function ctx.spy(fn)
    local spy = {
        calls = {},
        count = 0,
    }

    setmetatable(spy, {
        __call = function(_, ...)
            spy.count = spy.count + 1
            spy.calls[spy.count] = { n = select("#", ...), ... }
            if fn then
                return fn(...)
            end
        end,
    })

    return spy
end

function ctx.cleanup(fn)
    assert(type(fn) == "function", "cleanup must be a function")
    if not ctx._cleanups then
        ctx._cleanups = {}
    end
    table.insert(ctx._cleanups, fn)
end

function ctx.tmpdir(prefix)
    prefix = prefix or "boring-test"
    prefix = tostring(prefix):gsub("[^%w_.-]", "-")
    local pipe = io.popen(string.format("mktemp -d ${TMPDIR:-/tmp}/%s.XXXXXX", prefix))
    assert(pipe, "failed to run mktemp")
    local path = pipe:read("*l")
    pipe:close()
    assert(path and path ~= "", "failed to create temporary directory")
    ctx.cleanup(function()
        os.execute("rm -rf " .. shell_quote(path))
    end)
    return path
end

function ctx.skip(message)
    error({ skip = true, message = message or "skipped" }, 2)
end

local function run_cleanups(cleanups)
    local cleanup_failed = nil
    for i = #cleanups, 1, -1 do
        local ok, err = xpcall(cleanups[i], debug.traceback)
        if not ok and not cleanup_failed then
            cleanup_failed = err
        end
    end
    return cleanup_failed
end

function ctx.test(name, fn)
    total = total + 1
    ctx._cleanups = {}

    local ok, err = xpcall(fn, debug.traceback)
    local cleanup_err = run_cleanups(ctx._cleanups)
    ctx._cleanups = nil

    if not ok and type(err) == "table" and err.skip then
        skipped = skipped + 1
        report("skip", name, err.message)
    elseif ok and not cleanup_err then
        report("ok", name)
    else
        failed = failed + 1
        report("fail", name, cleanup_err or err)
    end
end

if format == "tap" then
    io.write("TAP version 13\n")
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

if format == "tap" then
    io.write(string.format("1..%d\n", total))
end

if failed > 0 then
    io.stderr:write(string.format("%d/%d tests failed (%d skipped)\n", failed, total, skipped))
    os.exit(1)
end

if format == "pretty" then
    io.write(string.format("%d tests passed", total - skipped))
    if skipped > 0 then
        io.write(string.format(" (%d skipped)", skipped))
    end
    io.write("\n")
end
