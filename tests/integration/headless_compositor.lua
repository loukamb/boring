return function(t)
    local compositor = require("tests.harness.compositor")

    t.test("headless compositor starts and stays alive until timeout", function()
        if not compositor.has_timeout() then
            t.skip("timeout command is unavailable")
        end

        local result = compositor.run({ timeout = "3s" })

        if result.status == 1 and result.log:match("Failed to create backend") then
            t.skip("wlroots headless backend is unavailable")
        end

        t.eq(result.status, 124, result.log)
        t.ok(not result.log:match("Fatal error"), result.log)
    end)
end
