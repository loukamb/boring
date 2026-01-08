-- compositor/config/paths.lua
-- Path discovery utilities for config and plugins

local ffi = require("ffi")

ffi.cdef[[
    char *getenv(const char *name);
]]

local paths = {}

---Get home directory
---@return string
function paths.home()
    local home = ffi.C.getenv("HOME")
    if home ~= nil then
        return ffi.string(home)
    end
    return "."
end

---Get XDG config home
---@return string
function paths.xdg_config_home()
    local xdg = ffi.C.getenv("XDG_CONFIG_HOME")
    if xdg ~= nil then
        return ffi.string(xdg)
    end
    return paths.home() .. "/.config"
end

---Get boring config directory
---@return string
function paths.config_dir()
    return paths.xdg_config_home() .. "/boring"
end

---Get user plugins directory
---@return string
function paths.user_plugins_dir()
    return paths.config_dir() .. "/plugins"
end

---Get default plugins directory (in repo)
---@return string
function paths.default_plugins_dir()
    -- Relative to CWD which should be the repo root
    return "./plugins"
end

---Check if file exists
---@param path string
---@return boolean
function paths.exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

---Find config file (priority order)
---@return string|nil path, string source
function paths.find_config()
    -- 1. User config
    local user_config = paths.config_dir() .. "/config.lua"
    if paths.exists(user_config) then
        return user_config, "user"
    end
    
    -- 2. Default config in repo
    if paths.exists("./default.lua") then
        return "./default.lua", "default"
    end
    
    return nil, "none"
end

---Resolve plugin path
---@param name string Plugin name (e.g., "@boring/screenshot" or "my-plugin")
---@return string|nil path
function paths.resolve_plugin(name)
    -- @boring/ prefix -> default plugins directory
    if name:sub(1, 8) == "@boring/" then
        local plugin_name = name:sub(9)
        local path = paths.default_plugins_dir() .. "/" .. plugin_name .. ".lua"
        if paths.exists(path) then
            return path
        end
        -- Try as directory with init.lua
        path = paths.default_plugins_dir() .. "/" .. plugin_name .. "/init.lua"
        if paths.exists(path) then
            return path
        end
        return nil
    end
    
    -- Otherwise -> user plugins directory
    local path = paths.user_plugins_dir() .. "/" .. name .. ".lua"
    if paths.exists(path) then
        return path
    end
    -- Try as directory with init.lua
    path = paths.user_plugins_dir() .. "/" .. name .. "/init.lua"
    if paths.exists(path) then
        return path
    end
    
    return nil
end

return paths
