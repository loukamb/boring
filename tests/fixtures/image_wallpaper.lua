-- Image wallpaper through the layer-shell wallpaper client, for smoke tests.
plugin("@boring/layout-stacking"):mount()
plugin("@boring/wallpaper"):mount({ ["*"] = { image = "/tmp/boring-test-wallpaper.ppm", scale = "fill" } })
