-- COMPATIBILITY wrapper around shared.wl.scope for unported code: accepts the
-- old `scope:listen(signal, function(handle, data) ... end, user_data)` form,
-- where the callback reads user_data with wl.Listener.get_data(handle).
-- New code: require("shared.wl.scope") and `scope:listen(signal, fn, ctype)`.

local wl_scope = require("shared.wl.scope")
local listener = require("shared.wl.listener")

local Scope = {}

local function listen(s, signal, fn, data)
    if data == nil or type(data) == "string" then
        return wl_scope.new().listen(s, signal, fn, data)
    end
    local handle = { data = data }
    local id = listener.connect(signal, function(d) return fn(handle, d) end)
    s:defer(function() listener.disconnect(id) end)
    return handle
end

function Scope.new(name)
    local s = wl_scope.new(name)
    s.listen = listen
    return s
end

return Scope
