-- Config for tests/integration/clients.lua: shortcuts leave marker files in
-- the runtime directory so the test can see they fired.
local function mark(name)
    return function()
        local f = io.open(os.getenv("XDG_RUNTIME_DIR") .. "/" .. name, "w")
        f:write("fired")
        f:close()
    end
end

input.keyboard.new({
    name = "*",
    shortcuts = {
        ["Super+F12"] = mark("key-shortcut"),
        ["Super+LeftMouseDrag"] = mark("mouse-shortcut"),
    },
})

plugin("@boring/layout-stacking"):mount()
plugin("@boring/wallpaper"):mount({ ["*"] = "#ffffff" })
