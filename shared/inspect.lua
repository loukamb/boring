-- Values as readable Lua-ish text, for printing results (ipc, the REPL).
--
--   inspect({ 1, 2, name = "x" })  --> { 1, 2, name = "x" }
--
-- Keys are sorted, long tables span lines, nesting stops at a depth.

local inspect

local function key_text(k)
    if type(k) == "string" and k:match("^[%a_][%w_]*$") then return k end
    return "[" .. inspect(k, 1) .. "]"
end

local function sorted_keys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta < tb end
        if ta == "number" or ta == "string" then return a < b end
        return tostring(a) < tostring(b)
    end)
    return keys
end

local function render(v, depth, indent, seen)
    local tv = type(v)
    if tv == "string" then return string.format("%q", v) end
    if tv ~= "table" then return tostring(v) end
    if seen[v] then return "<cycle>" end
    if depth <= 0 then return "{...}" end
    seen[v] = true
    local n = #v
    local parts = {}
    for i = 1, n do parts[#parts + 1] = render(v[i], depth - 1, indent .. "  ", seen) end
    for _, k in ipairs(sorted_keys(v)) do
        if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
            parts[#parts + 1] = key_text(k) .. " = " .. render(v[k], depth - 1, indent .. "  ", seen)
        end
    end
    seen[v] = nil
    if #parts == 0 then return "{}" end
    local flat = "{ " .. table.concat(parts, ", ") .. " }"
    if #flat <= 72 and not flat:find("\n", 1, true) then return flat end
    return "{\n" .. indent .. "  " .. table.concat(parts, ",\n" .. indent .. "  ") .. "\n" .. indent .. "}"
end

--- Text for a value; tables up to `depth` levels deep (default 3).
inspect = function(v, depth)
    return render(v, depth or 3, "", {})
end

return inspect
