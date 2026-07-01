return function(t)
    local args = require("shared.args")

    t.test("parses flags, key-value options, and positionals", function()
        local parsed = args.parse("compositor", "--debug", "--socket=wayland-1", "tail")
        t.eq(parsed.debug, true)
        t.eq(parsed.socket, "wayland-1")
        t.eq(parsed.positional[1], "compositor")
        t.eq(parsed.positional[2], "tail")
    end)

    t.test("does not truncate varargs after nil", function()
        local parsed = args.parse("before", nil, "--after=yes")
        t.eq(parsed.positional[1], "before")
        t.eq(parsed.after, "yes")
    end)
end
