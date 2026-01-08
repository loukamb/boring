local ffi = require("ffi")
local log = require("shared.log")

ffi.cdef [[
typedef int pid_t;
pid_t fork(void);
int execl(const char *path, const char *arg, ...);
int kill(pid_t pid, int sig);
pid_t waitpid(pid_t pid, int *status, int options);
int chdir(const char *path);
char *getcwd(char *buf, size_t size);
]]

local SIGTERM = 15
local SIGKILL = 9
local WNOHANG = 1

local process = {}
local Process = {}
Process.__index = Process

local all_processes = {}

function process.new(opts)
    opts = opts or {}
    local p = setmetatable({
        _cmd = opts.cmd,
        _program = opts.program,
        _args = opts.args or {},
        _pid = nil,
        _running = false,
        _start_method = nil,
    }, Process)
    table.insert(all_processes, p)
    return p
end

local function build_command(cmd, args)
    local parts = { cmd }
    for _, arg in ipairs(args) do
        if arg:find("[%s\"'\\]") then
            table.insert(parts, '"' .. arg:gsub('"', '\\"') .. '"')
        else
            table.insert(parts, arg)
        end
    end
    return table.concat(parts, " ")
end

local function get_script_dir()
    local buf = ffi.new("char[4096]")
    local result = ffi.C.getcwd(buf, 4096)
    if result ~= nil then
        return ffi.string(buf)
    end
    return "."
end

function Process:start()
    if self._running then
        log.warn("Process already running (pid %d)", self._pid)
        return false
    end

    if not self._cmd then
        log.error("No command specified for process:start()")
        return false
    end

    local cmd = build_command(self._cmd, self._args)


    local pid = ffi.C.fork()
    if pid == 0 then
        ffi.C.execl("/bin/sh", "/bin/sh", "-c", cmd, ffi.NULL)
        os.exit(1)
    elseif pid > 0 then
        self._pid = pid
        self._running = true
        self._start_method = "start"

        return true
    else
        log.error("Fork failed")
        return false
    end
end

function Process:start_local()
    if self._running then
        log.warn("Process already running (pid %d)", self._pid)
        return false
    end

    if not self._program then
        log.error("No program specified for process:start_local()")
        return false
    end

    local script_dir = get_script_dir()
    local args_str = ""
    for _, arg in ipairs(self._args) do
        if arg:find("[%s\"'\\]") then
            args_str = args_str .. ' "' .. arg:gsub('"', '\\"') .. '"'
        else
            args_str = args_str .. " " .. arg
        end
    end

    -- Get the Wayland display socket from core_service and pass it explicitly
    -- Also set GDK_BACKEND=wayland to force GTK to use Wayland instead of X11
    -- LD_PRELOAD gtk4-layer-shell so it loads before libwayland-client (required for layer shell to work)
    -- Use export so the variables persist across the && chain
    local core_service = require("compositor.services.core")
    local socket_name = core_service:get_socket_name()
    local env_setup = ""
    if socket_name then
        env_setup = string.format(
            "export WAYLAND_DISPLAY=%s GDK_BACKEND=wayland LD_PRELOAD=/usr/lib/libgtk4-layer-shell.so; ",
            socket_name
        )
    end

    local cmd = string.format("%scd %s && luajit switch.lua %s%s", env_setup, script_dir, self._program, args_str)


    local pid = ffi.C.fork()
    if pid == 0 then
        ffi.C.execl("/bin/sh", "/bin/sh", "-c", cmd, ffi.NULL)
        os.exit(1)
    elseif pid > 0 then
        self._pid = pid
        self._running = true
        self._start_method = "start_local"

        return true
    else
        log.error("Fork failed")
        return false
    end
end

function Process:stop()
    if not self._running or not self._pid then
        return true
    end


    local result = ffi.C.kill(self._pid, SIGTERM)
    if result == 0 then
        local status = ffi.new("int[1]")
        ffi.C.waitpid(self._pid, status, 0)
        self._running = false
        self._pid = nil
        return true
    end
    return false
end

function Process:kill()
    if not self._running or not self._pid then
        return true
    end


    local result = ffi.C.kill(self._pid, SIGKILL)
    if result == 0 then
        local status = ffi.new("int[1]")
        ffi.C.waitpid(self._pid, status, 0)
        self._running = false
        self._pid = nil
        return true
    end
    return false
end

function Process:restart()
    self:stop()
    if self._start_method == "start_local" then
        return self:start_local()
    else
        return self:start()
    end
end

function Process:is_running()
    if not self._running or not self._pid then
        return false
    end

    local status = ffi.new("int[1]")
    local result = ffi.C.waitpid(self._pid, status, WNOHANG)
    if result == self._pid then
        self._running = false
        self._pid = nil
        return false
    elseif result == 0 then
        return true
    else
        self._running = false
        self._pid = nil
        return false
    end
end

function Process:pid()
    return self._pid
end

function Process:set_args(args)
    self._args = args or {}
end

function Process:set_cmd(cmd)
    self._cmd = cmd
end

function Process:set_program(program)
    self._program = program
end

function process.stop_all()
    for _, p in ipairs(all_processes) do
        if p:is_running() then
            p:stop()
        end
    end
end

function process.kill_all()
    for _, p in ipairs(all_processes) do
        if p:is_running() then
            p:kill()
        end
    end
end

return process
