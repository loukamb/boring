local xml = {}

local function decode_entities(value)
    return (value:gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&amp;", "&")
        :gsub("&quot;", '"')
        :gsub("&apos;", "'"))
end

local function parse_attributes(attr_str)
    local attrs = {}
    for name, value in attr_str:gmatch('([%w_-]+)%s*=%s*"([^"]*)"') do
        attrs[name] = decode_entities(value)
    end
    for name, value in attr_str:gmatch("([%w_-]+)%s*=%s*'([^']*)'") do
        attrs[name] = decode_entities(value)
    end
    return attrs
end

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

local function find_tag_end(text, start_pos)
    local quote = nil
    local i = start_pos + 1
    while i <= #text do
        local c = text:sub(i, i)
        if quote then
            if c == quote then
                quote = nil
            end
        elseif c == '"' or c == "'" then
            quote = c
        elseif c == ">" then
            return i
        end
        i = i + 1
    end
    return nil
end

function xml.parse(text, handlers)
    handlers = handlers or {}
    local pos = 1
    local len = #text

    while pos <= len do
        local start_pos = text:find("<", pos)
        if not start_pos then break end

        if start_pos > pos then
            local content = trim(text:sub(pos, start_pos - 1))
            if content ~= "" and handlers.text then
                handlers.text(decode_entities(content))
            end
        end

        if text:sub(start_pos, start_pos + 3) == "<!--" then
            local end_pos = text:find("-->", start_pos + 4)
            if end_pos then
                pos = end_pos + 3
            else
                break
            end
        elseif text:sub(start_pos, start_pos + 1) == "<?" then
            local end_pos = text:find("?>", start_pos + 2)
            if end_pos then
                pos = end_pos + 2
            else
                break
            end
        elseif text:sub(start_pos, start_pos + 8) == "<!DOCTYPE" then
            local end_pos = text:find(">", start_pos + 9)
            if end_pos then
                pos = end_pos + 1
            else
                break
            end
        elseif text:sub(start_pos, start_pos + 8) == "<![CDATA[" then
            local end_pos = text:find("]]>", start_pos + 9)
            if end_pos then
                local cdata = text:sub(start_pos + 9, end_pos - 1)
                if handlers.text then
                    handlers.text(cdata)
                end
                pos = end_pos + 3
            else
                break
            end
        elseif text:sub(start_pos + 1, start_pos + 1) == "/" then
            local end_pos = find_tag_end(text, start_pos)
            if end_pos then
                local tag = trim(text:sub(start_pos + 2, end_pos - 1))
                if handlers.end_element then
                    handlers.end_element(tag)
                end
                pos = end_pos + 1
            else
                break
            end
        else
            local end_pos = find_tag_end(text, start_pos)
            if end_pos then
                local tag_content = text:sub(start_pos + 1, end_pos - 1)
                local self_closing = tag_content:sub(-1) == "/"
                if self_closing then
                    tag_content = tag_content:sub(1, -2)
                end

                local tag, attr_str = tag_content:match("^([%w_:-]+)%s*(.*)")
                if tag then
                    local attrs = parse_attributes(attr_str)
                    if handlers.start_element then
                        handlers.start_element(tag, attrs)
                    end
                    if self_closing and handlers.end_element then
                        handlers.end_element(tag)
                    end
                end
                pos = end_pos + 1
            else
                break
            end
        end
    end
end

function xml.parse_file(path, handlers)
    local f = io.open(path, "r")
    if not f then return nil, "Could not open file: " .. path end
    local content = f:read("*a")
    f:close()
    xml.parse(content, handlers)
    return true
end

return xml
