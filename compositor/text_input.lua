-- Input methods (fcitx5, ibus, ...): relays between text-input-v3, spoken by
-- applications, and input-method-v2, spoken by the input method.
--
-- The text input of the focused window's client is the active one. When it
-- enables, the input method is activated and fed its surrounding text and
-- content type; what the input method commits (preedit, text, deletions) is
-- sent back to it. Keyboard grabs are routed by compositor/keyboard.lua.

local wl = require("shared.wl")

local lib = wl.lib

local text_input = {}

local function same_client(resource_a, resource_b)
    return lib.wl_resource_get_client(resource_a) == lib.wl_resource_get_client(resource_b)
end

function text_input.setup(server)
    local relay = { inputs = {}, im = nil, active = nil }
    server.text_input_relay = relay

    local function im_send_state(ti)
        local im = relay.im
        if im == nil then return end
        local current = ti.current
        if current.surrounding.text ~= nil then
            lib.wlr_input_method_v2_send_surrounding_text(im, current.surrounding.text,
                current.surrounding.cursor, current.surrounding.anchor)
        end
        lib.wlr_input_method_v2_send_text_change_cause(im, current.text_change_cause)
        lib.wlr_input_method_v2_send_content_type(im, current.content_type.hint, current.content_type.purpose)
        lib.wlr_input_method_v2_send_done(im)
    end

    local function activate(ti)
        relay.active = ti
        if relay.im ~= nil then
            lib.wlr_input_method_v2_send_activate(relay.im)
            im_send_state(ti)
        end
    end

    local function deactivate(ti)
        if relay.active ~= ti then return end
        relay.active = nil
        if relay.im ~= nil then
            lib.wlr_input_method_v2_send_deactivate(relay.im)
            lib.wlr_input_method_v2_send_done(relay.im)
        end
    end

    -- Give text inputs focus when their client's window is focused.
    local function update_focus(surface)
        for _, ti in ipairs(relay.inputs) do
            local focused = ti.focused_surface
            if focused ~= nil and (surface == nil or focused ~= surface) then
                deactivate(ti)
                lib.wlr_text_input_v3_send_leave(ti)
            end
            if surface ~= nil and ti.focused_surface == nil and same_client(ti.resource, surface.resource) then
                lib.wlr_text_input_v3_send_enter(ti, surface)
            end
        end
    end
    server.events:on("window:focus", function(w) update_focus(w.surface) end)
    server.events:on("window:blur", function() update_focus(server.focused and server.focused.surface or nil) end)

    local ti_manager = lib.wlr_text_input_manager_v3_create(server.display)
    server.scope:listen(ti_manager.events.new_text_input, function(ti)
        table.insert(relay.inputs, ti)
        local scope = server.scope:child("text input")
        scope:listen(ti.events.enable, function() activate(ti) end)
        scope:listen(ti.events.commit, function()
            if relay.active == ti then im_send_state(ti) end
        end)
        scope:listen(ti.events.disable, function() deactivate(ti) end)
        scope:listen(ti.events.destroy, function()
            deactivate(ti)
            for i, x in ipairs(relay.inputs) do
                if x == ti then table.remove(relay.inputs, i) break end
            end
            scope:close()
        end)
        local focused = server.focused
        if focused and same_client(ti.resource, focused.surface.resource) then
            lib.wlr_text_input_v3_send_enter(ti, focused.surface)
        end
    end, "struct wlr_text_input_v3")

    local im_manager = lib.wlr_input_method_manager_v2_create(server.display)
    server.scope:listen(im_manager.events.new_input_method, function(im)
        if relay.im ~= nil then
            lib.wlr_input_method_v2_send_unavailable(im)
            return
        end
        relay.im = im
        local scope = server.scope:child("input method")

        scope:listen(im.events.commit, function()
            local ti = relay.active
            if ti == nil then return end
            local current = im.current
            if current.preedit.text ~= nil then
                lib.wlr_text_input_v3_send_preedit_string(ti, current.preedit.text,
                    current.preedit.cursor_begin, current.preedit.cursor_end)
            else
                lib.wlr_text_input_v3_send_preedit_string(ti, nil, 0, 0)
            end
            if current.commit_text ~= nil then
                lib.wlr_text_input_v3_send_commit_string(ti, current.commit_text)
            end
            if current.delete.before_length ~= 0 or current.delete.after_length ~= 0 then
                lib.wlr_text_input_v3_send_delete_surrounding_text(ti,
                    current.delete.before_length, current.delete.after_length)
            end
            lib.wlr_text_input_v3_send_done(ti)
        end)

        scope:listen(im.events.grab_keyboard, function(grab)
            server.input_method_grab = grab
            local kb = lib.wlr_seat_get_keyboard(server.seat)
            if kb ~= nil then lib.wlr_input_method_keyboard_grab_v2_set_keyboard(grab, kb) end
            local grab_scope = scope:child("input method grab")
            grab_scope:listen(grab.events.destroy, function()
                if server.input_method_grab == grab then server.input_method_grab = nil end
                grab_scope:close()
            end)
        end, "struct wlr_input_method_keyboard_grab_v2")

        scope:listen(im.events.destroy, function()
            relay.im = nil
            server.input_method_grab = nil
            scope:close()
        end)

        if relay.active ~= nil then activate(relay.active) end
    end, "struct wlr_input_method_v2")

    return { "zwp_text_input_manager_v3", "zwp_text_input_v3",
        "zwp_input_method_manager_v2", "zwp_input_method_v2", "zwp_input_method_keyboard_grab_v2" }
end

return text_input
