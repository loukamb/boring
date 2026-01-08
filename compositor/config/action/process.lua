-- compositor/config/action/process.lua
-- Process-related actions: execute, start, restart

local M = {}

---@param helpers table Runtime helpers
---@return table Process actions
function M.get_actions(helpers)
    return {
        ---Execute a shell command
        ---@param cmd string Shell command
        ---@param args table|nil Additional arguments
        ---@return function
        execute = function(cmd, args)
            return function()
                local process = require("compositor.process")
                local p = process.new({ cmd = cmd, args = args or {} })
                p:start()
            end
        end,

        ---Start a local lwc client program
        ---@param program string Program name
        ---@param args table|nil Additional arguments
        ---@return function
        start = function(program, args)
            return function()
                local process = require("compositor.process")
                local p = process.new({ program = program, args = args or {} })
                p:start_local()
            end
        end,

        ---Restart the compositor
        restart = function()
            local process_mod = require("compositor.process")
            local ffi = require("ffi")
            local buf = ffi.new("char[4096]")
            local result = ffi.C.getcwd(buf, 4096)
            local cwd = result ~= nil and ffi.string(buf) or "."
            local cmd = string.format("cd %s && luajit switch.lua compositor", cwd)
            process_mod.new({ cmd = cmd }):start()
            local core_service = require("compositor.services.core")
            core_service:terminate()
        end,
    }
end

return M
