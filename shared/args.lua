local args = {}

function args.parse(...)
    local results = { positional = {} }
    for i, v, _ in ipairs({ ... }) do
        if v:sub(1, 2) == "--" then
            local iq = v:find("=")
            results[v:sub(3, iq and iq - 1 or #v)] = iq and v:sub(iq + 1) or true
        else
            results.positional[#results.positional + 1] = v
        end
    end
    return results
end

return args
