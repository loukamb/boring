-- The seat: input device hotplug, capabilities, cursor images and the
-- clipboard (selection and primary selection).

local wl = require("shared.wl")
local keyboard = require("compositor.keyboard")
local pointer = require("compositor.pointer")

local lib, C = wl.lib, wl.C

local input = {}

function input.update_capabilities(server)
    local caps = C.WL_SEAT_CAPABILITY_POINTER
    if #server.keyboards > 0 then
        caps = caps + C.WL_SEAT_CAPABILITY_KEYBOARD
    end
    server.seat:set_capabilities(caps)
end

function input.setup(server)
    local seat = lib.wlr_seat_create(server.display, "seat0")
    server.seat = seat
    local scope = server.scope

    scope:listen(server.backend.events.new_input, function(device)
        if device.type == C.WLR_INPUT_DEVICE_KEYBOARD then
            keyboard.add_device(server, device)
        elseif device.type == C.WLR_INPUT_DEVICE_POINTER then
            pointer.add_device(server, device)
        end
        input.update_capabilities(server)
    end, "struct wlr_input_device")

    -- Clients set the cursor image while they have pointer focus.
    scope:listen(seat.events.request_set_cursor, function(event)
        if seat.pointer_state.focused_client == event.seat_client and not server.grab then
            server.cursor:set_surface(event.surface, event.hotspot_x, event.hotspot_y)
        end
    end, "struct wlr_seat_pointer_request_set_cursor_event")

    scope:listen(seat.events.request_set_selection, function(event)
        seat:set_selection(event.source, event.serial)
    end, "struct wlr_seat_request_set_selection_event")

    lib.wlr_data_device_manager_create(server.display)

    return { "wl_seat", "wl_keyboard", "wl_pointer", "wl_touch",
        "wl_data_device_manager", "wl_data_device", "wl_data_offer", "wl_data_source" }
end

return input
