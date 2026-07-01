local args = {}

function args.parse(...)
    local results = { positional = {} }
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v ~= nil then
            if v:sub(1, 2) == "--" then
                local iq = v:find("=")
                results[v:sub(3, iq and iq - 1 or #v)] = iq and v:sub(iq + 1) or true
            else
                results.positional[#results.positional + 1] = v
            end
        end
    end
    return results
end

return args
