-- Window management through ipc, for tests/integration/windows.lua.
plugin("@boring/ipc"):mount()
plugin("@boring/layout-tiling"):mount({ gaps = { inner = 0, outer = 0, smart = false } })
plugin("@boring/workspaces"):mount({ count = 3 })
plugin("@boring/rules"):mount({
    function(w)
        if w:app_id() == "float-me" then return { floating = true, size = { 300, 200 } } end
        if w:app_id() == "third" then return { workspace = 3 } end
    end,
})
