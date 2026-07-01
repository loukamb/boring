local xml = require("shared.xml")

local protocol = {}

local type_to_signature = {
    int = "i",
    uint = "u",
    fixed = "f",
    string = "s",
    object = "o",
    new_id = "n",
    array = "a",
    fd = "h",
}

local function build_signature(args)
    local sig = {}
    for _, arg in ipairs(args) do
        local char = type_to_signature[arg.type] or "?"
        if arg.allow_null then
            table.insert(sig, "?")
        end
        table.insert(sig, char)
    end
    return table.concat(sig)
end

function protocol.parse(text)
    local result = {
        name = nil,
        interfaces = {},
    }

    local stack = {}
    local current_interface = nil
    local current_request_list = nil
    local current_event_list = nil
    local current_enum = nil
    local current_message = nil
    local request_opcode = 0
    local event_opcode = 0

    xml.parse(text, {
        start_element = function(tag, attrs)
            table.insert(stack, tag)

            if tag == "protocol" then
                result.name = attrs.name
            elseif tag == "interface" then
                current_interface = {
                    name = attrs.name,
                    version = tonumber(attrs.version) or 1,
                    requests = {},
                    events = {},
                    enums = {},
                }
                request_opcode = 0
                event_opcode = 0
            elseif tag == "request" then
                current_message = {
                    name = attrs.name,
                    type = attrs.type,
                    since = tonumber(attrs.since),
                    args = {},
                }
                current_request_list = current_interface.requests
            elseif tag == "event" then
                current_message = {
                    name = attrs.name,
                    type = attrs.type,
                    since = tonumber(attrs.since),
                    args = {},
                }
                current_event_list = current_interface.events
            elseif tag == "arg" and current_message then
                table.insert(current_message.args, {
                    name = attrs.name,
                    type = attrs.type,
                    interface = attrs.interface,
                    enum = attrs.enum,
                    summary = attrs.summary,
                    allow_null = attrs["allow-null"] == "true",
                })
            elseif tag == "enum" then
                current_enum = {
                    name = attrs.name,
                    bitfield = attrs.bitfield == "true",
                    entries = {},
                }
            elseif tag == "entry" and current_enum then
                local value = attrs.value
                if value then
                    if value:match("^0x") then
                        value = tonumber(value, 16)
                    else
                        value = tonumber(value)
                    end
                end
                current_enum.entries[attrs.name] = value
            end
        end,

        end_element = function(tag)
            table.remove(stack)

            if tag == "interface" and current_interface then
                result.interfaces[current_interface.name] = current_interface
                current_interface = nil
            elseif tag == "request" and current_message and current_request_list then
                current_message.signature = build_signature(current_message.args)
                current_message.opcode = request_opcode
                current_request_list[request_opcode] = current_message
                current_request_list[current_message.name] = request_opcode
                request_opcode = request_opcode + 1
                current_message = nil
                current_request_list = nil
            elseif tag == "event" and current_message and current_event_list then
                current_message.signature = build_signature(current_message.args)
                current_message.opcode = event_opcode
                current_event_list[event_opcode] = current_message
                current_event_list[current_message.name] = event_opcode
                event_opcode = event_opcode + 1
                current_message = nil
                current_event_list = nil
            elseif tag == "enum" and current_enum and current_interface then
                current_interface.enums[current_enum.name] = current_enum.entries
                current_enum = nil
            end
        end,
    })

    return result
end

function protocol.parse_file(path)
    local f = io.open(path, "r")
    if not f then return nil, "Could not open file: " .. path end
    local content = f:read("*a")
    f:close()
    return protocol.parse(content)
end

protocol._private = {
    build_signature = build_signature,
}

return protocol
