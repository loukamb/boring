-- shared/watch.lua - File watching using inotify
-- Provides chokidar-like file watching with event emitter

local ffi = require("ffi")
local bit = require("bit")
local log = require("shared.log")
local emitter = require("shared.emitter")

require("shared.ffi.libc")
local C = ffi.C

local IN_ACCESS        = C.IN_ACCESS
local IN_MODIFY        = C.IN_MODIFY
local IN_ATTRIB        = C.IN_ATTRIB
local IN_CLOSE_WRITE   = C.IN_CLOSE_WRITE
local IN_CLOSE_NOWRITE = C.IN_CLOSE_NOWRITE
local IN_OPEN          = C.IN_OPEN
local IN_MOVED_FROM    = C.IN_MOVED_FROM
local IN_MOVED_TO      = C.IN_MOVED_TO
local IN_CREATE        = C.IN_CREATE
local IN_DELETE        = C.IN_DELETE
local IN_DELETE_SELF   = C.IN_DELETE_SELF
local IN_MOVE_SELF     = C.IN_MOVE_SELF
local IN_UNMOUNT       = C.IN_UNMOUNT
local IN_Q_OVERFLOW    = C.IN_Q_OVERFLOW
local IN_IGNORED       = C.IN_IGNORED
local IN_ISDIR         = C.IN_ISDIR
local IN_NONBLOCK      = C.IN_NONBLOCK
local IN_CLOEXEC       = C.IN_CLOEXEC
local F_GETFL          = C.F_GETFL
local F_SETFL          = C.F_SETFL
local O_NONBLOCK       = C.O_NONBLOCK
local POLLIN           = C.POLLIN
local S_IFMT           = C.S_IFMT
local S_IFDIR          = C.S_IFDIR
local AT_FDCWD         = C.AT_FDCWD
local STATX_TYPE       = C.STATX_TYPE

-- Fixed part of struct inotify_event; the name follows it.
local INOTIFY_EVENT_SIZE = ffi.sizeof("struct inotify_event")

local watch = {}

-- Watcher class
local Watcher = {}
Watcher.__index = Watcher

-- Create a new file watcher
-- opts:
--   persistent: keep running even if all watches are removed (default: true)
--   recursive: watch directories recursively (default: false)
--   ignored: patterns to ignore (array of strings or functions)
--   poll_interval: poll interval in ms for manual polling (default: 100)
function watch.new(opts)
    opts = opts or {}
    
    local fd = ffi.C.inotify_init1(IN_NONBLOCK + IN_CLOEXEC)
    if fd < 0 then
        log.error("Failed to initialize inotify")
        return nil
    end
    
    local self = setmetatable({
        _fd = fd,
        _watches = {},           -- wd -> { path, recursive }
        _path_to_wd = {},        -- path -> wd
        _emitter = emitter.new(),
        _persistent = opts.persistent ~= false,
        _recursive = opts.recursive or false,
        _ignored = opts.ignored or {},
        _poll_interval = opts.poll_interval or 100,
        _running = false,
        _closed = false,
    }, Watcher)
    
    return self
end

-- Check if a path is a directory
-- statx rather than stat: struct statx has the same layout on every architecture.
local statx_buf = ffi.new("struct statx")
local function is_directory(path)
    if C.statx(AT_FDCWD, path, 0, STATX_TYPE, statx_buf) == 0 then
        return bit.band(statx_buf.stx_mode, S_IFMT) == S_IFDIR
    end
    return false
end

-- List directory contents
local function list_dir(path)
    local entries = {}
    local dir = ffi.C.opendir(path)
    if dir == nil then
        return entries
    end
    
    while true do
        local entry = ffi.C.readdir(dir)
        if entry == nil then
            break
        end
        local name = ffi.string(entry.d_name)
        if name ~= "." and name ~= ".." then
            table.insert(entries, name)
        end
    end
    
    ffi.C.closedir(dir)
    return entries
end

-- Check if path should be ignored
function Watcher:_should_ignore(path)
    for _, pattern in ipairs(self._ignored) do
        if type(pattern) == "string" then
            if path:match(pattern) then
                return true
            end
        elseif type(pattern) == "function" then
            if pattern(path) then
                return true
            end
        end
    end
    return false
end

-- Add a watch for a path
function Watcher:add(path, opts)
    opts = opts or {}
    
    if self._closed then
        log.warn("Watcher is closed")
        return false
    end
    
    if self:_should_ignore(path) then
        return false
    end
    
    -- Check if already watching
    if self._path_to_wd[path] then
        return true
    end
    
    local mask = IN_MODIFY + IN_CREATE + IN_DELETE + IN_MOVE_SELF +
                 IN_MOVED_FROM + IN_MOVED_TO + IN_ATTRIB + IN_DELETE_SELF
    
    local wd = ffi.C.inotify_add_watch(self._fd, path, mask)
    if wd < 0 then
        log.warn("Failed to add watch for: %s", path)
        return false
    end
    
    local recursive = opts.recursive
    if recursive == nil then
        recursive = self._recursive
    end
    
    self._watches[wd] = {
        path = path,
        recursive = recursive,
    }
    self._path_to_wd[path] = wd
    
    self._emitter:emit("add", path)
    
    -- If recursive and directory, add watches for subdirectories
    if recursive and is_directory(path) then
        local entries = list_dir(path)
        for _, name in ipairs(entries) do
            local subpath = path .. "/" .. name
            if is_directory(subpath) then
                self:add(subpath, { recursive = true })
            end
        end
    end
    
    return true
end

-- Remove a watch for a path
function Watcher:unwatch(path)
    if self._closed then
        return false
    end
    
    local wd = self._path_to_wd[path]
    if not wd then
        return false
    end
    
    ffi.C.inotify_rm_watch(self._fd, wd)
    self._watches[wd] = nil
    self._path_to_wd[path] = nil
    
    self._emitter:emit("unwatch", path)
    
    return true
end

-- Register event listener
-- Events: "change", "add", "unlink", "addDir", "unlinkDir", "error", "ready"
function Watcher:on(event, callback)
    self._emitter:on(event, callback)
    return self
end

-- Remove event listener
function Watcher:off(event, callback)
    self._emitter:off(event, callback)
    return self
end

-- Map inotify events to watcher events
local function get_event_type(mask, is_dir)
    if bit.band(mask, IN_CREATE) ~= 0 then
        return is_dir and "addDir" or "add"
    elseif bit.band(mask, IN_DELETE) ~= 0 or bit.band(mask, IN_MOVED_FROM) ~= 0 then
        return is_dir and "unlinkDir" or "unlink"
    elseif bit.band(mask, IN_MODIFY) ~= 0 then
        return "change"
    elseif bit.band(mask, IN_MOVED_TO) ~= 0 then
        return is_dir and "addDir" or "add"
    elseif bit.band(mask, IN_ATTRIB) ~= 0 then
        return "change"
    elseif bit.band(mask, IN_DELETE_SELF) ~= 0 or bit.band(mask, IN_MOVE_SELF) ~= 0 then
        return is_dir and "unlinkDir" or "unlink"
    end
    return nil
end

-- Process pending events (non-blocking)
function Watcher:poll()
    if self._closed then
        return
    end
    
    local buf_size = 4096
    local buf = ffi.new("char[?]", buf_size)
    
    while true do
        local len = ffi.C.read(self._fd, buf, buf_size)
        if len <= 0 then
            break
        end
        
        local offset = 0
        while offset < len do
            -- Parse inotify_event structure
            local wd = ffi.cast("int*", buf + offset)[0]
            local mask = ffi.cast("uint32_t*", buf + offset + 4)[0]
            -- cookie at offset + 8 (unused, for rename tracking)
            local name_len = ffi.cast("uint32_t*", buf + offset + 12)[0]
            
            local name = ""
            if name_len > 0 then
                name = ffi.string(buf + offset + INOTIFY_EVENT_SIZE)
            end
            
            local watch_info = self._watches[wd]
            if watch_info then
                local full_path = watch_info.path
                if name ~= "" then
                    full_path = watch_info.path .. "/" .. name
                end
                
                local is_dir = bit.band(mask, IN_ISDIR) ~= 0
                local event_type = get_event_type(mask, is_dir)
                
                if event_type and not self:_should_ignore(full_path) then
                    self._emitter:emit(event_type, full_path)
                    
                    -- Auto-add watches for new directories if recursive
                    if event_type == "addDir" and watch_info.recursive then
                        self:add(full_path, { recursive = true })
                    end
                    
                    -- Clean up watches for deleted directories
                    if event_type == "unlinkDir" then
                        self:unwatch(full_path)
                    end
                end
                
                -- Handle watch removal
                if bit.band(mask, IN_IGNORED) ~= 0 then
                    self._watches[wd] = nil
                    self._path_to_wd[watch_info.path] = nil
                end
            end
            
            offset = offset + INOTIFY_EVENT_SIZE + name_len
        end
    end
end

-- Check if there are pending events (for use in external event loops)
function Watcher:has_events()
    if self._closed then
        return false
    end
    
    local pfd = ffi.new("struct pollfd[1]")
    pfd[0].fd = self._fd
    pfd[0].events = POLLIN
    pfd[0].revents = 0
    
    local ret = ffi.C.poll(pfd, 1, 0)
    return ret > 0 and bit.band(pfd[0].revents, POLLIN) ~= 0
end

-- Get the file descriptor (for integration with external event loops)
function Watcher:get_fd()
    return self._fd
end

-- Close the watcher
function Watcher:close()
    if self._closed then
        return
    end
    
    self._running = false
    self._closed = true
    
    -- Remove all watches
    for wd, _ in pairs(self._watches) do
        ffi.C.inotify_rm_watch(self._fd, wd)
    end
    self._watches = {}
    self._path_to_wd = {}
    
    ffi.C.close(self._fd)
    self._emitter:emit("close")
end

-- Convenience function to watch a single path
-- Returns a watcher configured for that path
function watch.watch(path, opts)
    opts = opts or {}
    local w = watch.new(opts)
    if w then
        w:add(path, opts)
        w._emitter:emit("ready")
    end
    return w
end

-- Convenience function to watch multiple paths
function watch.watch_many(paths, opts)
    opts = opts or {}
    local w = watch.new(opts)
    if w then
        for _, path in ipairs(paths) do
            w:add(path, opts)
        end
        w._emitter:emit("ready")
    end
    return w
end

return watch
