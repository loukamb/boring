return function(t)
    local protocol = require("shared.wayland.protocol")

    t.test("protocol parse assigns sequential opcodes per interface", function()
        local parsed = protocol.parse([[
            <protocol name="p">
              <interface name="a" version="1">
                <request name="first"/>
                <request name="second"><arg name="target" type="object" allow-null="true"/></request>
                <event name="done"/>
              </interface>
              <interface name="b" version="1">
                <request name="only"/>
              </interface>
            </protocol>
        ]])

        t.eq(parsed.interfaces.a.requests.first, 0)
        t.eq(parsed.interfaces.a.requests.second, 1)
        t.eq(parsed.interfaces.b.requests.only, 0)
        t.eq(parsed.interfaces.a.requests[1].signature, "?o")
        t.eq(protocol._private.build_signature({ { type = "string" }, { type = "fd" } }), "sh")
    end)
end
