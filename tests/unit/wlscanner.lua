return function(t)
    package.path = "./?.lua;" .. package.path
    local protocol = require("shared.wayland.protocol")
    local wlscanner = require("tools.wlscanner")

    local proto = protocol.parse([[
        <protocol name="test">
          <interface name="test_manager" version="2">
            <request name="get_thing">
              <arg name="id" type="new_id" interface="test_thing"/>
              <arg name="surface" type="object" interface="wl_surface"/>
            </request>
            <request name="bind_any">
              <arg name="id" type="new_id"/>
            </request>
            <enum name="error">
              <entry name="role" value="0"/>
              <entry name="defunct" value="0x2"/>
            </enum>
          </interface>
          <interface name="test_thing" version="1">
            <event name="configure">
              <arg name="width" type="int"/>
              <arg name="scale" type="fixed"/>
              <arg name="default" type="string"/>
              <arg name="child" type="new_id" interface="test_thing"/>
            </event>
          </interface>
        </protocol>
    ]])

    t.test("protocol parser keeps document order", function()
        t.eq(proto.interface_list[1].name, "test_manager")
        t.eq(proto.interface_list[2].name, "test_thing")
        local entries = proto.interface_list[1].enum_list[1].entries
        t.eq(entries[1].name, "role")
        t.eq(entries[2].value, 2)
    end)

    t.test("wlscanner server header: externs, enums, request structs", function()
        local h = wlscanner.header(proto, "server")
        t.ok(h:find("extern const struct wl_interface test_manager_interface;", 1, true))
        t.ok(h:find("struct wl_surface;", 1, true), "foreign interfaces are forward-declared")
        t.ok(h:find("TEST_MANAGER_ERROR_DEFUNCT = 2,", 1, true))
        t.ok(h:find("void (*get_thing)(struct wl_client *client, struct wl_resource *resource, uint32_t id, struct wl_resource *surface);", 1, true))
        t.ok(h:find("const char *interface, uint32_t version, uint32_t id", 1, true), "untyped new_id expands")
        t.ok(not h:find("_listener", 1, true))
    end)

    t.test("wlscanner client header: listener structs with typed objects", function()
        local h = wlscanner.header(proto, "client")
        t.ok(h:find("struct test_thing_listener {", 1, true))
        t.ok(h:find("void (*configure)(void *data, struct test_thing *test_thing, int32_t width, wl_fixed_t scale, const char *default_, struct test_thing *child);", 1, true))
        t.ok(not h:find("struct test_manager_interface {", 1, true))
    end)
end
