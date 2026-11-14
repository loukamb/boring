-- The clipboard, offered by the compositor itself: a wlr_data_source whose
-- callbacks are Lua.
--
--   clipboard.set(server, "some text")
--   clipboard.set(server, { ["image/png"] = png_bytes })
--
-- A string is offered as text (text/plain;charset=utf-8, UTF8_STRING, ...).
-- Clients that paste get the bytes written to their pipe from the event
-- loop, without blocking it. All sources share one impl: three C callbacks.

local ffi = require("ffi")
local wl = require("shared.wl")
local log = require("shared.log")
local loop = require("compositor.loop")

local lib, C = wl.lib, wl.C

local clipboard = {}

local TEXT_TYPES = { "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "TEXT", "STRING" }

local sources = {} -- addr(source) -> { source = cdata, data = { mime -> bytes } }
local impl = nil
local current_server = nil

local function write_out(server, fd, bytes)
    C.fcntl(fd, C.F_SETFL, ffi.cast("int", C.O_NONBLOCK))
    local offset = 1
    local stop
    stop = loop.writable(server, fd, function()
        while offset <= #bytes do
            local chunk = bytes:sub(offset, offset + 65535)
            local n = tonumber(C.write(fd, chunk, #chunk))
            if n < 0 then
                if ffi.errno() == C.EAGAIN then return end
                break -- the reader went away
            end
            offset = offset + n
        end
        stop()
        C.close(fd)
    end)
end

local function make_impl()
    impl = ffi.new("struct wlr_data_source_impl")
    impl.send = ffi.cast("void (*)(struct wlr_data_source *, const char *, int32_t)", function(source, mime, fd)
        local entry = sources[wl.addr(source)]
        local bytes = entry and entry.data[ffi.string(mime)]
        if not bytes then
            C.close(fd)
            return
        end
        local ok, err = pcall(write_out, current_server, fd, bytes)
        if not ok then
            log.error("clipboard: %s", tostring(err))
            C.close(fd)
        end
    end)
    impl.destroy = ffi.cast("void (*)(struct wlr_data_source *)", function(source)
        sources[wl.addr(source)] = nil
    end)
end

--- Put data on the clipboard: a string (text) or { mime = bytes }.
function clipboard.set(server, data)
    if not impl then make_impl() end
    current_server = server
    if type(data) == "string" then
        local text = data
        data = {}
        for _, mime in ipairs(TEXT_TYPES) do data[mime] = text end
    end
    local source = ffi.new("struct wlr_data_source")
    lib.wlr_data_source_init(source, impl)
    for mime in pairs(data) do
        local p = ffi.cast("char **", lib.wl_array_add(source.mime_types, ffi.sizeof("char *")))
        p[0] = C.strdup(mime)
    end
    sources[wl.addr(source)] = { source = source, data = data }
    lib.wlr_seat_set_selection(server.seat, source, lib.wl_display_next_serial(server.display))
end

return clipboard
