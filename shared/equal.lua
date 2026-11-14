-- Structural equality, for telling whether a reloaded config changed.
--
-- Tables are equal when they have equal keys and values (table keys are
-- matched structurally too). Functions are equal when they're the same
-- function, or Lua functions with the same bytecode and equal upvalues:
-- a config recreates its closures every time it runs, so identity alone
-- would make every config with a callback look changed.

local equal

local function find_key(t, key, seen)
    if t[key] ~= nil then return key end
    if type(key) ~= "table" then return nil end
    for k in pairs(t) do
        if type(k) == "table" and equal(k, key, seen) then return k end
    end
    return nil
end

local function same_function(a, b, seen)
    local ia, ib = debug.getinfo(a, "Su"), debug.getinfo(b, "Su")
    if ia.what == "C" or ib.what == "C" then return false end
    if ia.nups ~= ib.nups then return false end
    if string.dump(a, true) ~= string.dump(b, true) then return false end
    for i = 1, ia.nups do
        local _, va = debug.getupvalue(a, i)
        local _, vb = debug.getupvalue(b, i)
        if not equal(va, vb, seen) then return false end
    end
    return true
end

function equal(a, b, seen)
    if rawequal(a, b) then return true end
    local ta = type(a)
    if ta ~= type(b) then return false end
    if ta ~= "table" and ta ~= "function" then
        return ta == "cdata" and a == b or false
    end

    -- Pairs being compared already: assume equal (handles cycles).
    seen = seen or {}
    local s = seen[a]
    if s and s[b] then return true end
    if not s then s = {}; seen[a] = s end
    s[b] = true

    if ta == "function" then return same_function(a, b, seen) end

    local count = 0
    for k, v in pairs(a) do
        count = count + 1
        local kb = find_key(b, k, seen)
        if kb == nil or not equal(v, b[kb], seen) then return false end
    end
    for _ in pairs(b) do count = count - 1 end
    return count == 0
end

return equal
