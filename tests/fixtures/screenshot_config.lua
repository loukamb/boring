-- Screenshots through ipc, for tests/integration/screenshot.lua.
plugin("@boring/ipc"):mount()
plugin("@boring/wallpaper"):mount({ ["*"] = "#ff0000" })
plugin("@boring/layout-stacking"):mount()
screenshot = plugin("@boring/screenshot"):mount({ directory = os.getenv("XDG_RUNTIME_DIR") .. "/shots" })
