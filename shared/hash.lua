--- Hash utilities module
--- Provides cryptographic hash functions for caching and integrity checks.
---@class shared.hash

local ffi = require("ffi")

local hash = {}

-- Use OpenSSL for SHA256 (widely available on Linux)
ffi.cdef [[
typedef struct SHA256state_st SHA256_CTX;
unsigned char *SHA256(const unsigned char *d, size_t n, unsigned char *md);
]]

local libcrypto
local function get_libcrypto()
    if libcrypto then return libcrypto end
    local ok, lib = pcall(ffi.load, "crypto")
    if ok then
        libcrypto = lib
        return lib
    end
    return nil
end

--- Compute SHA256 hash of a string
---@param data string Input data to hash
---@return string|nil hex Hex-encoded SHA256 hash, or nil if unavailable
function hash.sha256(data)
    local lib = get_libcrypto()
    if not lib then
        -- Fallback: use sha256sum command
        local handle = io.popen("printf '%s' " .. string.format("%q", data) .. " | sha256sum 2>/dev/null")
        if handle then
            local result = handle:read("*l")
            handle:close()
            if result then
                return result:match("^(%x+)")
            end
        end
        return nil
    end

    local digest = ffi.new("unsigned char[32]")
    lib.SHA256(data, #data, digest)

    -- Convert to hex string
    local hex = {}
    for i = 0, 31 do
        hex[i + 1] = string.format("%02x", digest[i])
    end
    return table.concat(hex)
end

--- Compute a quick hash for cache invalidation
--- Uses first 16 chars of SHA256 for brevity
---@param data string Input data to hash
---@return string|nil hash Short hash string, or nil if unavailable
function hash.short(data)
    local full = hash.sha256(data)
    if full then
        return full:sub(1, 16)
    end
    return nil
end

return hash
