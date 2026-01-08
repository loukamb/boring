--- Plugin loader and registry
--- Provides functions for loading, mounting, and managing plugins
---@class compositor.plugin
local log = require("shared.log")
local paths = require("compositor.config.paths")

local plugin_module = {}

-- Plugin registry
local registry = {
    plugins = {},    -- name -> { module, mounted_data, config, listeners }
    load_order = {}, -- ordered list of plugin names
}

---Load a plugin module from path
---@param path string
---@return table|nil module
---@return string|nil error
local function load_plugin_module(path)
    local fn, err = loadfile(path)
    if not fn then
        return nil, "Failed to load plugin: " .. err
    end

    local ok, result = pcall(fn)
    if not ok then
        return nil, "Failed to execute plugin: " .. result
    end

    if type(result) ~= "table" then
        return nil, "Plugin must return a table"
    end

    if not result.name then
        return nil, "Plugin must have a 'name' field"
    end

    return result, nil
end

---Create a plugin handle for mounting/unmounting
---@param name string Plugin name
---@return table handle
function plugin_module.create_handle(name)
    local path = paths.resolve_plugin(name)

    local handle = {
        _name = name,
        _path = path,
        _module = nil,
        _mounted = false,
        _mounted_data = nil,
    }

    ---Mount the plugin
    ---@param config table|nil Configuration to pass to plugin
    ---@return table|nil Plugin API returned from mount
    function handle:mount(config)
        if self._mounted then
            log.warn("Plugin '%s' already mounted", self._name)
            return self._mounted_data
        end

        if not self._path then
            log.error("Plugin '%s' not found", self._name)
            return nil
        end

        -- Load the module if not already loaded
        if not self._module then
            local mod, err = load_plugin_module(self._path)
            if not mod then
                log.error("%s", err)
                return nil
            end
            self._module = mod
        end

        -- Call mount function
        local mounted_data = nil
        if self._module.mount then
            local ok, result = pcall(self._module.mount, self._module, config or {})
            if not ok then
                log.error("Plugin '%s' mount failed: %s", self._name, result)
                return nil
            end
            mounted_data = result
        end

        self._mounted = true
        self._mounted_data = mounted_data

        -- Register in global registry
        registry.plugins[self._name] = {
            module = self._module,
            mounted_data = mounted_data,
            config = config,
            handle = self,
        }
        table.insert(registry.load_order, self._name)


        return mounted_data
    end

    ---Unmount the plugin
    function handle:unmount()
        if not self._mounted then
            return
        end

        -- Call unmount function
        if self._module and self._module.unmount then
            local ok, err = pcall(self._module.unmount, self._module)
            if not ok then
                log.error("Plugin '%s' unmount failed: %s", self._name, err)
            end
        end

        self._mounted = false
        self._mounted_data = nil

        -- Remove from registry
        registry.plugins[self._name] = nil
        for i, name in ipairs(registry.load_order) do
            if name == self._name then
                table.remove(registry.load_order, i)
                break
            end
        end
    end

    return handle
end

---Get the plugin function to add to config environment
---@return function
function plugin_module.get_plugin_function()
    return function(name)
        return plugin_module.create_handle(name)
    end
end

---Create custom require function that handles @boring/ paths
---@param original_require function Original require function
---@return function
function plugin_module.create_custom_require(original_require)
    return function(module_name)
        -- Handle @boring/ prefix
        if module_name:sub(1, 8) == "@boring/" then
            local plugin_name = module_name:sub(9)
            local path = paths.default_plugins_dir() .. "/" .. plugin_name .. ".lua"
            if not paths.exists(path) then
                path = paths.default_plugins_dir() .. "/" .. plugin_name .. "/init.lua"
            end
            assert(paths.exists(path), "Module not found: " .. module_name)
            local fn, err = loadfile(path)
            assert(fn, "Failed to load @boring/" .. plugin_name .. ": " .. (err or "unknown error"))
            return fn()
        end

        -- Fall back to original require
        return original_require(module_name)
    end
end

---Unmount all plugins (in reverse order)
function plugin_module.unmount_all()
    for i = #registry.load_order, 1, -1 do
        local name = registry.load_order[i]
        local entry = registry.plugins[name]
        if entry and entry.handle then
            entry.handle:unmount()
        end
    end
end

---Get list of mounted plugins
---@return table
function plugin_module.list_mounted()
    local list = {}
    for _, name in ipairs(registry.load_order) do
        table.insert(list, name)
    end
    return list
end

return plugin_module
