-- shared/wayland/base.lua
-- Centralized FFI utilities and constants shared between client and server modules

local ffi = require("ffi")
local bit = require("bit")
local log = require("shared.log")

local base = {}

-- Core exports
base.ffi = ffi
base.bit = bit
base.C = ffi.C

---@param ctype string
---@param ... any
function base.new(ctype, ...)
    return ffi.new(ctype, ...)
end

---@param ctype string
---@param ptr any
function base.cast(ctype, ptr)
    return ffi.cast(ctype, ptr)
end

---@param ptr any
---@return boolean
function base.is_null(ptr)
    return ptr == nil or ptr == ffi.NULL
end

---@param ptr any
---@return number
function base.ptr_to_num(ptr)
    return tonumber(ffi.cast("intptr_t", ffi.cast("void*", ptr))) or 0
end

---@param ctype string
---@return number
function base.sizeof(ctype)
    return ffi.sizeof(ctype)
end

---@param ptr any
---@return string|nil
function base.string(ptr)
    if ptr == nil or ptr == ffi.NULL then
        return nil
    end
    return ffi.string(ptr)
end

-- GC prevention helpers

---@param target table
function base.init_prevent_gc(target)
    target._prevent_gc = {}
end

---@param target table
---@param signature string
---@param fn function
function base.persistent_callback(target, signature, fn)
    local cb = ffi.cast(signature, fn)
    table.insert(target._prevent_gc, cb)
    return cb
end

-- Time utilities

local CLOCK_MONOTONIC = 1

ffi.cdef [[
int clock_gettime(int clock_id, struct timespec *tp);
]]

function base.get_time()
    local ts = ffi.new("struct timespec")
    ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
    return ts
end

-- Safe cdef with error reporting

---@param cdef string
---@return boolean, string|nil
function base.safe_cdef(cdef)
    local ok, err = pcall(function()
        ffi.cdef(cdef)
    end)
    if not ok then
        log.error("FFI cdef error: %s", err)
        local line_num = err:match("declaration specifier expected near line (%d+)")
            or err:match("at line (%d+)")
        if line_num then
            local lines = {}
            for line in cdef:gmatch("[^\n]+") do
                table.insert(lines, line)
            end
            local n = tonumber(line_num) or 0
            log.error("Context around line %d:", n)
            for i = math.max(1, n - 3), math.min(#lines, n + 3) do
                log.error("  %d: %s", i, lines[i])
            end
        end
        return false, err
    end
    return true, nil
end

-- Protocol constants (shared between client/server)

base.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND = 0
base.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM = 1
base.ZWLR_LAYER_SHELL_V1_LAYER_TOP = 2
base.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY = 3

base.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP = 1
base.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM = 2
base.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT = 4
base.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT = 8

return base
