return function(t)
    local clib = require("shared.clib")._private
    local protocol = require("shared.wayland.protocol")

    t.test("clib removes nested attributes without corrupting declarations", function()
        local src = "int a __attribute__((aligned(16), cleanup(foo))); int b;"
        local stripped = clib.remove_attributes(src)
        t.ok(not stripped:find("__attribute__", 1, true))
        t.ok(stripped:find("int a", 1, true))
        t.ok(stripped:find("int b;", 1, true))
    end)

    t.test("clib identifies static inline and problematic types", function()
        t.ok(clib.is_static_inline("static inline int f(void) { return 0; }"))
        t.ok(clib.has_problematic_types("typedef __m256 bad;"))
    end)

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
