-- Iterate wl_list (wl_list_for_each and friends are macros in C).
--
--   for mode in list.each(output.modes, "struct wlr_output_mode", "link") do
--       print(mode.width, mode.height)
--   end
--
-- Iteration is removal-safe: the next element is read before yielding.

local ffi = require("ffi")

local list = {}

local voidp = ffi.typeof("void *")
local charp = ffi.typeof("char *")
local wl_list_ptr = ffi.typeof("struct wl_list *")

local cache = {}
local function container(ctype, member)
    local key = ctype .. "\0" .. member
    local c = cache[key]
    if not c then
        c = { offset = ffi.offsetof(ctype, member), ptr = ffi.typeof(ctype .. " *") }
        assert(c.offset, "list: " .. ctype .. " has no member " .. member)
        cache[key] = c
    end
    return c
end

--- Iterator over the containers linked into `head`.
---@param head ffi.cdata* struct wl_list (the list head)
---@param ctype string container type, e.g. "struct wlr_output_mode"
---@param member string name of the struct wl_list member in the container
function list.each(head, ctype, member)
    local c = container(ctype, member)
    local head_ptr = ffi.cast(wl_list_ptr, head)
    local head_addr = ffi.cast(voidp, head_ptr)
    local pos = head_ptr.next
    return function()
        if pos == nil or ffi.cast(voidp, pos) == head_addr then
            return nil
        end
        local current = pos
        pos = pos.next
        return ffi.cast(c.ptr, ffi.cast(charp, current) - c.offset)
    end
end

--- Number of elements in a list.
function list.length(head)
    local head_ptr = ffi.cast(wl_list_ptr, head)
    local head_addr = ffi.cast(voidp, head_ptr)
    local n, pos = 0, head_ptr.next
    while ffi.cast(voidp, pos) ~= head_addr do
        n = n + 1
        pos = pos.next
    end
    return n
end

--- The container struct that `ptr` (pointing at `member`) is embedded in.
function list.container_of(ptr, ctype, member)
    local c = container(ctype, member)
    return ffi.cast(c.ptr, ffi.cast(charp, ptr) - c.offset)
end

return list
