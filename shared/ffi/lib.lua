-- Load shared libraries and expose their symbols through one table.
--
-- Libraries are loaded by soname (the runtime file, not the -devel symlink).
-- Symbols are resolved lazily, in library order and then the process (libc),
-- and cached. Unknown symbols resolve to nil so callers can feature-test
-- optional APIs: `if lib.wlr_some_new_function then ... end`.

local ffi = require("ffi")

local lib = {}

local function lookup(namespace, name)
    return namespace[name]
end

---@param sonames string[] e.g. { "libwlroots-0.20.so", "libwayland-server.so.0" }
---@return table symbols
function lib.open(sonames)
    local handles = {}
    for i, soname in ipairs(sonames) do
        handles[i] = ffi.load(soname)
    end
    handles[#handles + 1] = ffi.C

    -- Indexing a library for a symbol it lacks throws, hence pcall; it runs
    -- once per symbol thanks to the cache.
    return setmetatable({}, {
        __index = function(cache, name)
            for _, handle in ipairs(handles) do
                local ok, sym = pcall(lookup, handle, name)
                if ok then
                    rawset(cache, name, sym)
                    return sym
                end
            end
            return nil
        end,
    })
end

return lib
