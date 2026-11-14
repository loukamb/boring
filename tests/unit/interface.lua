return function(t)
    local ffi = require("ffi")
    require("shared.ffi.client")
    local registry = require("shared.wayland.registry")
    local interface = require("shared.wayland.interface")

    local function message(list, i)
        return ffi.string(list[i].name), ffi.string(list[i].signature)
    end

    t.test("wl_interface is built from protocol XML like wayland-scanner would", function()
        if not registry.get_interface("zwlr_layer_surface_v1") then
            t.skip("wlr-protocols XML not installed")
        end
        local shell = interface.get("zwlr_layer_shell_v1")
        t.eq(ffi.string(shell.name), "zwlr_layer_shell_v1")
        t.eq(shell.method_count, 2)
        local name, sig = message(shell.methods, 0)
        t.eq(name, "get_layer_surface")
        t.eq(sig, "no?ous")
        -- Argument interfaces: new_id -> layer surface, object -> wl_surface.
        t.eq(ffi.string(shell.methods[0].types[0].name), "zwlr_layer_surface_v1")
        t.eq(ffi.string(shell.methods[0].types[1].name), "wl_surface")

        local surface = interface.get("zwlr_layer_surface_v1")
        t.eq(surface.event_count, 2)
        t.eq((message(surface.events, 0)), "configure")
        -- Requests added in later versions carry their version in the signature.
        local _, set_layer = message(surface.methods, 8)
        t.eq(set_layer, "2u")
        t.eq(interface.get("zwlr_layer_surface_v1"), surface, "interfaces are built once")
    end)

    t.test("untyped new_id expands to interface, version, id", function()
        if not registry.get_interface("wl_registry") then
            t.skip("wayland.xml not installed")
        end
        local reg = interface.get("wl_registry")
        local name, sig = message(reg.methods, 0)
        t.eq(name, "bind")
        t.eq(sig, "usun")
    end)
end
