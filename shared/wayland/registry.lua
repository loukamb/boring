local protocol_parser = require("shared.wayland.protocol")
local log = require("shared.log")

local registry = {}

local protocol_paths = {
    "/usr/share/wayland/wayland.xml",
    "/usr/share/wayland-protocols/stable",
    "/usr/share/wayland-protocols/staging",
    "/usr/share/wayland-protocols/unstable",
    "/usr/share/wlr-protocols/unstable",
}

local discovered_protocols = {}
local parsed_protocols = {}
local interface_to_protocol = {}
local implemented_interfaces = {}

local function scan_directory(path)
    local handle = io.popen('find "' .. path .. '" -name "*.xml" -type f 2>/dev/null')
    if not handle then return end
    for line in handle:lines() do
        local name = line:match("([^/]+)%.xml$")
        if name and not discovered_protocols[name] then
            discovered_protocols[name] = line
        end
    end
    handle:close()
end

function registry.discover()
    discovered_protocols = {}
    for _, path in ipairs(protocol_paths) do
        local f = io.open(path, "r")
        if f then
            f:close()
            if path:match("%.xml$") then
                local name = path:match("([^/]+)%.xml$")
                if name then
                    discovered_protocols[name] = path
                end
            else
                scan_directory(path)
            end
        end
    end
    return discovered_protocols
end

function registry.get(protocol_name)
    if parsed_protocols[protocol_name] then
        return parsed_protocols[protocol_name]
    end

    if not discovered_protocols[protocol_name] then
        registry.discover()
    end

    local path = discovered_protocols[protocol_name]
    if not path then
        return nil, "Protocol not found: " .. protocol_name
    end

    local proto, err = protocol_parser.parse_file(path)
    if not proto then
        return nil, err
    end

    parsed_protocols[protocol_name] = proto

    for iface_name, _ in pairs(proto.interfaces) do
        interface_to_protocol[iface_name] = protocol_name
    end

    return proto
end

function registry.get_interface(interface_name)
    local protocol_name = interface_to_protocol[interface_name]
    if not protocol_name then
        registry.discover()
        for proto_name, path in pairs(discovered_protocols) do
            local proto = registry.get(proto_name)
            if proto and proto.interfaces[interface_name] then
                return proto.interfaces[interface_name], proto
            end
        end
        return nil, "Interface not found: " .. interface_name
    end

    local proto = registry.get(protocol_name)
    if proto and proto.interfaces[interface_name] then
        return proto.interfaces[interface_name], proto
    end
    return nil, "Interface not found: " .. interface_name
end

function registry.implement(interface_name)
    implemented_interfaces[interface_name] = true
end

local function create_accessor_table(data)
    return setmetatable({}, {
        __index = function(_, key)
            return data[key]
        end
    })
end

function registry.request(interface_name)
    local iface, err = registry.get_interface(interface_name)
    if not iface then
        error(err)
    end
    return create_accessor_table(iface.requests)
end

function registry.event(interface_name)
    local iface, err = registry.get_interface(interface_name)
    if not iface then
        error(err)
    end
    return create_accessor_table(iface.events)
end

function registry.enum(interface_name)
    local iface, err = registry.get_interface(interface_name)
    if not iface then
        error(err)
    end
    return setmetatable({}, {
        __index = function(_, enum_name)
            local enum_data = iface.enums[enum_name]
            if enum_data then
                return create_accessor_table(enum_data)
            end
            return nil
        end
    })
end

function registry.interface(interface_name)
    local iface, proto = registry.get_interface(interface_name)
    if not iface then
        return nil
    end
    return {
        name = interface_name,
        version = iface.version,
        protocol = proto.name,
    }
end

function registry.status()
    registry.discover()

    local available = {}
    local implemented = {}

    for proto_name, _ in pairs(discovered_protocols) do
        local proto = registry.get(proto_name)
        if proto then
            for iface_name, iface in pairs(proto.interfaces) do
                local entry = {
                    interface = iface_name,
                    version = iface.version,
                    protocol = proto_name,
                }
                table.insert(available, entry)
                if implemented_interfaces[iface_name] then
                    table.insert(implemented, entry)
                end
            end
        end
    end

    table.sort(available, function(a, b) return a.interface < b.interface end)
    table.sort(implemented, function(a, b) return a.interface < b.interface end)

    return {
        available = available,
        implemented = implemented,
        available_count = #available,
        implemented_count = #implemented,
    }
end

function registry.report(filter)
    local status = registry.status()
    local lines = {}

    for _, entry in ipairs(status.available) do
        local is_implemented = implemented_interfaces[entry.interface]

        if filter == "implemented" and not is_implemented then
            goto continue
        elseif filter == "missing" and is_implemented then
            goto continue
        end

        local mark, label
        if is_implemented then
            mark = log.color.green("✓")
            label = log.color.green("implemented")
        else
            mark = log.color.yellow("·")
            label = log.color.yellow("missing")
        end
        table.insert(lines, string.format("%s %-35s v%-3d %s",
            mark, entry.interface, entry.version, label))

        ::continue::
    end

    local missing_count = status.available_count - status.implemented_count
    table.insert(lines, string.format("%d implemented, %d missing",
        status.implemented_count, missing_count))

    return table.concat(lines, "\n")
end

return registry
