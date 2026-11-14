return function(t)
    local ffi = require("ffi")
    local wl = require("shared.wl")
    local listener = wl.listener

    local function new_signal()
        local signal = ffi.new("struct wl_signal")
        listener.signal_init(signal)
        return signal
    end

    t.test("thousands of listeners share one callback slot", function()
        -- More than LuaJIT could ever give out as individual ffi callbacks.
        local signal = new_signal()
        local before = listener.count()
        local ids, hits = {}, 0
        for i = 1, 5000 do
            ids[i] = listener.connect(signal, function() hits = hits + 1 end)
        end
        listener.emit(signal, nil)
        t.eq(hits, 5000)
        for _, id in ipairs(ids) do
            listener.disconnect(id)
        end
        t.eq(listener.count(), before)
    end)

    t.test("listener data is cast to the requested ctype", function()
        local signal = new_signal()
        local box = ffi.new("struct wlr_box", { 1, 2, 3, 4 })
        local seen
        local id = listener.connect(signal, function(b) seen = b.width end, "struct wlr_box")
        listener.emit(signal, box)
        listener.disconnect(id)
        t.eq(seen, 3)
    end)

    t.test("a listener can disconnect itself and others while notified", function()
        local signal = new_signal()
        local calls = {}
        local a, b, c
        a = listener.connect(signal, function()
            calls[#calls + 1] = "a"
            listener.disconnect(a)
        end)
        b = listener.connect(signal, function()
            calls[#calls + 1] = "b"
        end)
        c = listener.connect(signal, function()
            calls[#calls + 1] = "c"
        end)
        listener.emit(signal, nil)
        listener.emit(signal, nil)
        listener.disconnect(b)
        listener.disconnect(c)
        listener.disconnect(a) -- already gone: no-op
        t.eq(table.concat(calls, ","), "a,b,c,b,c")
    end)

    t.test("an erroring listener doesn't stop the others", function()
        local signal = new_signal()
        local reached = false
        local x = listener.connect(signal, function() error("boom") end)
        local y = listener.connect(signal, function() reached = true end)
        listener.emit(signal, nil)
        listener.disconnect(x)
        listener.disconnect(y)
        t.ok(reached)
    end)

    t.test("metatype methods resolve wlroots functions by prefix", function()
        local box = ffi.new("struct wlr_box", { 0, 0, 10, 10 })
        t.ok(box:contains(5, 5))
        t.ok(not box:contains(10, 5))
        t.ok(not box:empty())
        local zero = ffi.new("struct wlr_box")
        t.ok(zero:empty())
    end)

    t.test("wl.list iterates container structs", function()
        local head = ffi.new("struct wl_list")
        head.prev, head.next = head, head
        local nodes = {}
        for i = 1, 3 do
            local l = ffi.new("struct wl_listener")
            nodes[i] = l
            l.link.prev = head.prev
            l.link.next = head
            head.prev.next = l.link
            head.prev = l.link
        end
        local n = 0
        for item in wl.list.each(head, "struct wl_listener", "link") do
            n = n + 1
            t.eq(wl.addr(item), wl.addr(nodes[n]))
        end
        t.eq(n, 3)
        t.eq(wl.list.length(head), 3)
    end)
end
