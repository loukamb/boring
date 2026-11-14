-- Small filesystem helpers over libc (no lfs dependency).
--
--   for _, e in ipairs(fs.list(dir)) do print(e.name, e.dir) end
--   fs.is_dir(path), fs.is_file(path), fs.mtime(path)

local bit = require("bit")
local ffi = require("ffi")
require("shared.ffi.libc")

local C = ffi.C

local fs = {}

local DT_DIR, DT_LNK, DT_UNKNOWN = 4, 10, 0
local STATX_MTIME = 0x40

local st = ffi.new("struct statx")

local function stat(path, mask)
    if C.statx(C.AT_FDCWD, path, 0, mask, st) ~= 0 then return nil end
    return st
end

function fs.is_dir(path)
    local s = stat(path, C.STATX_TYPE)
    return s ~= nil and bit.band(s.stx_mode, C.S_IFMT) == C.S_IFDIR
end

function fs.is_file(path)
    local s = stat(path, C.STATX_TYPE)
    return s ~= nil and bit.band(s.stx_mode, C.S_IFMT) == C.S_IFREG
end

--- Modification time in seconds, or nil.
function fs.mtime(path)
    local s = stat(path, STATX_MTIME)
    return s and tonumber(s.stx_mtime.tv_sec)
end

--- Entries of a directory (without . and ..): { name, dir = bool }.
--- Empty if it can't be read.
function fs.list(dir)
    local out = {}
    local d = C.opendir(dir)
    if d == nil then return out end
    while true do
        local e = C.readdir(d)
        if e == nil then break end
        local name = ffi.string(e.d_name)
        if name ~= "." and name ~= ".." then
            local is_dir = e.d_type == DT_DIR
            if e.d_type == DT_LNK or e.d_type == DT_UNKNOWN then is_dir = fs.is_dir(dir .. "/" .. name) end
            out[#out + 1] = { name = name, dir = is_dir }
        end
    end
    C.closedir(d)
    return out
end

--- Is `name` an executable in $PATH (or an existing path)?
function fs.in_path(name)
    if name:find("/", 1, true) then return fs.is_file(name) end
    for dir in (os.getenv("PATH") or "/usr/bin:/bin"):gmatch("[^:]+") do
        if fs.is_file(dir .. "/" .. name) then return true end
    end
    return false
end

return fs
