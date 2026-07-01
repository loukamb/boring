-- shared/watch.lua - File watching using inotify
-- Provides chokidar-like file watching with event emitter

local ffi = require("ffi")
local bit = require("bit")
local log = require("shared.log")
local emitter = require("shared.emitter")

ffi.cdef[[
// inotify
int inotify_init(void);
int inotify_init1(int flags);
int inotify_add_watch(int fd, const char *pathname, uint32_t mask);
int inotify_rm_watch(int fd, int wd);

// File operations
int read(int fd, void *buf, size_t count);
int close(int fd);
int fcntl(int fd, int cmd, ...);

// Poll
struct pollfd {
    int fd;
    short events;
    short revents;
};
int poll(struct pollfd *fds, unsigned long nfds, int timeout);

// Stat for directory detection
struct stat {
    unsigned long st_dev;
    unsigned long st_ino;
    unsigned long st_nlink;
    unsigned int st_mode;
    unsigned int st_uid;
    unsigned int st_gid;
    unsigned int __pad0;
    unsigned long st_rdev;
    long st_size;
    long st_blksize;
    long st_blocks;
    long st_atime;
    long st_atime_nsec;
    long st_mtime;
    long st_mtime_nsec;
    long st_ctime;
    long st_ctime_nsec;
    long __unused[3];
};
int stat(const char *pathname, struct stat *statbuf);

// Directory reading
typedef struct DIR DIR;
struct dirent {
    unsigned long d_ino;
    long d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[256];
};
DIR *opendir(const char *name);
struct dirent *readdir(DIR *dirp);
int closedir(DIR *dirp);
]]

-- inotify event masks
local IN_ACCESS        = 0x00000001
local IN_MODIFY        = 0x00000002
local IN_ATTRIB        = 0x00000004
local IN_CLOSE_WRITE   = 0x00000008
local IN_CLOSE_NOWRITE = 0x00000010
local IN_OPEN          = 0x00000020
local IN_MOVED_FROM    = 0x00000040
local IN_MOVED_TO      = 0x00000080
local IN_CREATE        = 0x00000100
local IN_DELETE        = 0x00000200
local IN_DELETE_SELF   = 0x00000400
local IN_MOVE_SELF     = 0x00000800
local IN_UNMOUNT       = 0x00002000
local IN_Q_OVERFLOW    = 0x00004000
local IN_IGNORED       = 0x00008000
local IN_ISDIR         = 0x40000000

-- fcntl commands
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 2048

-- poll events
local POLLIN = 0x0001

-- inotify_init1 flags
local IN_NONBLOCK = 2048
local IN_CLOEXEC = 524288

-- inotify event structure size
local INOTIFY_EVENT_SIZE = 16  -- sizeof(struct inotify_event) without name

-- S_IFDIR for directory detection
local S_IFDIR = 0x4000
local S_IFMT = 0xF000

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
local function is_directory(path)
    local stat_buf = ffi.new("struct stat")
    if ffi.C.stat(path, stat_buf) == 0 then
        return bit.band(stat_buf.st_mode, S_IFMT) == S_IFDIR
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
