-- plugins/library/desktop.lua
-- Desktop entries and icons, the freedesktop.org way.
--
--   local desktop = require("@boring/library/desktop")
--   for _, app in ipairs(desktop.applications()) do print(app.name, app.exec) end
--   desktop.command(app, { terminal = "foot" })   -- shell command that runs it
--   desktop.icon("firefox", 32)                   -- a file path, or nil
--
-- Applications come from $XDG_DATA_HOME/applications and
-- $XDG_DATA_DIRS/*/applications (earlier directories win for the same
-- desktop file ID). Hidden, NoDisplay, non-Application entries, entries
-- not meant for this desktop (OnlyShowIn/NotShowIn against
-- $XDG_CURRENT_DESKTOP) and ones whose TryExec isn't installed are left
-- out. Names are localised from $LC_ALL/$LC_MESSAGES/$LANG.

local fs = require("shared.fs")

local desktop = {}

local function home()
    return os.getenv("HOME") or "."
end

--- $XDG_DATA_HOME followed by $XDG_DATA_DIRS.
function desktop.data_dirs()
    local dirs = { os.getenv("XDG_DATA_HOME") or (home() .. "/.local/share") }
    for dir in (os.getenv("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"):gmatch("[^:]+") do
        dirs[#dirs + 1] = dir
    end
    return dirs
end

-- Locale keys to try, most specific first: ll_CC@mod, ll_CC, ll@mod, ll.
local function locales()
    local lang = os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or os.getenv("LANG") or ""
    lang = lang:gsub("%..*", "") -- drop the encoding
    local ll, cc, mod = lang:match("^(%a+)_?(%a*)@?(.*)$")
    local list = {}
    if not ll or ll == "C" or ll == "POSIX" then return list end
    if cc ~= "" and mod ~= "" then list[#list + 1] = ll .. "_" .. cc .. "@" .. mod end
    if cc ~= "" then list[#list + 1] = ll .. "_" .. cc end
    if mod ~= "" then list[#list + 1] = ll .. "@" .. mod end
    list[#list + 1] = ll
    return list
end

-- The [Desktop Entry] group of a file, as key -> value (localised keys as
-- they appear, e.g. "Name[fr]").
local function read_entry(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local entry, in_group = {}, false
    for line in f:lines() do
        local group = line:match("^%[(.+)%]%s*$")
        if group then
            if in_group then break end
            in_group = group == "Desktop Entry"
        elseif in_group then
            local k, v = line:match("^([%w%-%[%]@_.]+)%s*=%s*(.*)$")
            if k then entry[k] = v end
        end
    end
    f:close()
    return entry
end

local function unescape(s)
    return (s:gsub("\\(.)", { s = " ", n = "\n", t = "\t", r = "\r", ["\\"] = "\\", [";"] = ";" }))
end

local function list_value(s)
    local out = {}
    if not s then return out end
    for item in s:gmatch("([^;]+)") do out[#out + 1] = unescape(item) end
    return out
end

local function localised(entry, key, langs)
    for _, l in ipairs(langs) do
        local v = entry[key .. "[" .. l .. "]"]
        if v then return unescape(v) end
    end
    return entry[key] and unescape(entry[key]) or nil
end

local function shown_here(entry)
    local current = {}
    for d in (os.getenv("XDG_CURRENT_DESKTOP") or "boring"):gmatch("[^:]+") do current[d] = true end
    if entry.OnlyShowIn then
        local ok = false
        for _, d in ipairs(list_value(entry.OnlyShowIn)) do if current[d] then ok = true end end
        if not ok then return false end
    end
    for _, d in ipairs(list_value(entry.NotShowIn)) do
        if current[d] then return false end
    end
    return true
end

--- Parse one desktop file into an application record, or nil if it
--- shouldn't be shown.
function desktop.parse(path, id)
    local e = read_entry(path)
    if not e or e.Type ~= "Application" or not e.Exec then return nil end
    if e.Hidden == "true" or e.NoDisplay == "true" or not shown_here(e) then return nil end
    if e.TryExec and not fs.in_path(unescape(e.TryExec)) then return nil end
    local langs = locales()
    return {
        id = id,
        path = path,
        name = localised(e, "Name", langs) or id,
        generic = localised(e, "GenericName", langs),
        comment = localised(e, "Comment", langs),
        keywords = list_value(localised(e, "Keywords", langs)),
        exec = unescape(e.Exec),
        icon = e.Icon,
        terminal = e.Terminal == "true",
        workdir = e.Path,
        categories = list_value(e.Categories),
    }
end

local function scan(dir, prefix, seen, out)
    for _, entry in ipairs(fs.list(dir)) do
        local path = dir .. "/" .. entry.name
        if entry.dir then
            scan(path, prefix .. entry.name .. "-", seen, out)
        elseif entry.name:match("%.desktop$") then
            local id = prefix .. entry.name
            if not seen[id] then
                seen[id] = true
                local app = desktop.parse(path, id)
                if app then out[#out + 1] = app end
            end
        end
    end
end

--- Every application that should be shown, sorted by name.
function desktop.applications()
    local seen, out = {}, {}
    for _, dir in ipairs(desktop.data_dirs()) do scan(dir .. "/applications", "", seen, out) end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

local function quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- The shell command that starts an application: field codes (%f, %u,
--- ...) removed, %i/%c/%k filled in, in a terminal if Terminal=true,
--- from its Path if it has one. opts.terminal is the terminal to use
--- (default "foot"), run as `<terminal> -e <command>`.
function desktop.command(app, opts)
    opts = opts or {}
    local exec = app.exec:gsub("%%(.)", function(code)
        if code == "%" then return "%" end
        if code == "c" then return quote(app.name) end
        if code == "k" then return quote(app.path or "") end
        if code == "i" then return app.icon and ("--icon " .. quote(app.icon)) or "" end
        return ""
    end)
    exec = exec:gsub("%s+$", "")
    if app.terminal then exec = (opts.terminal or "foot") .. " -e " .. exec end
    if app.workdir and app.workdir ~= "" then exec = "cd " .. quote(app.workdir) .. " && " .. exec end
    return exec
end

--------------------------------------------------------------------------------
-- Icons
--------------------------------------------------------------------------------

local icon_cache = {}

-- Directories inside a theme to look in: sizes nearest to `size` first,
-- then scalable (SVG needs libvips built with librsvg).
local function size_dirs(size)
    local sizes = { 16, 22, 24, 32, 48, 64, 96, 128, 256, 512 }
    table.sort(sizes, function(a, b)
        local da, db = math.abs(a - size), math.abs(b - size)
        if da ~= db then return da < db end
        return a > b -- larger scales down better
    end)
    local dirs = {}
    for _, s in ipairs(sizes) do dirs[#dirs + 1] = s .. "x" .. s end
    dirs[#dirs + 1] = "scalable"
    return dirs
end

local CONTEXTS = { "apps", "status", "devices", "places", "mimetypes", "actions", "categories" }
local EXTENSIONS = { ".png", ".svg" }

--- The file for an icon name (or path) at about `size` pixels, from
--- `theme` (default: $BORING_ICON_THEME, then hicolor and Adwaita), or nil.
function desktop.icon(name, size, theme)
    if not name or name == "" then return nil end
    if name:sub(1, 1) == "/" then return fs.is_file(name) and name or nil end
    size = size or 32
    local key = name .. "\0" .. size .. "\0" .. (theme or "")
    local cached = icon_cache[key]
    if cached ~= nil then return cached or nil end

    local themes = {}
    local function add_theme(t)
        if t and t ~= "" then themes[#themes + 1] = t end
    end
    add_theme(theme)
    add_theme(os.getenv("BORING_ICON_THEME"))
    add_theme("hicolor")
    add_theme("Adwaita")
    local roots = { home() .. "/.icons" }
    for _, dir in ipairs(desktop.data_dirs()) do roots[#roots + 1] = dir .. "/icons" end

    local found = false
    for _, t in ipairs(themes) do
        for _, root in ipairs(roots) do
            local base = root .. "/" .. t
            if fs.is_dir(base) then
                for _, sdir in ipairs(size_dirs(size)) do
                    for _, ctx in ipairs(CONTEXTS) do
                        for _, ext in ipairs(EXTENSIONS) do
                            local path = base .. "/" .. sdir .. "/" .. ctx .. "/" .. name .. ext
                            if fs.is_file(path) then found = path break end
                        end
                        if found then break end
                    end
                    if found then break end
                end
            end
            if found then break end
        end
        if found then break end
    end
    if not found then
        for _, ext in ipairs({ ".svg", ".png" }) do
            local path = "/usr/share/pixmaps/" .. name .. ext
            if fs.is_file(path) then found = path break end
        end
    end
    icon_cache[key] = found
    return found or nil
end

return desktop
