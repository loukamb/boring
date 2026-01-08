<h1>boring</h1>
<p>
    <img src="/website/public/favicon.png" height="64" align="left"></img>
</p>

This is the monorepository for the boring Wayland compositor. As the name implies, it is boring by default. However, the hacker in you will probably love it.

## Overview

`boring` is a minimalist, non-monolithic Wayland compositor built on [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots/) that is designed to be hackable and extensible, reminiscent of [dwm](https://git.suckless.org/dwm/) and [dwl](https://codeberg.org/dwl/dwl). Functionality is provided through plugins; we give you the tools and leave you to play.

A set of default plugins are included that provides basic window management and Wayland functionality for those that don't want to spend too much time writing their own:

- [`borders`](/plugins/borders.lua): Draw borders around windows
- [`layout-stacking`](/plugins/layout-stacking.lua): Traditional stacking layout
- [`layout-tiling`](/plugins/layout-tiling.lua): Sway-inspired n-ary tiling layout
- [`layout-kiosk`](/plugins/layout-kiosk.lua): Runs a single, maximized window
- [`screenshot`](/plugins/screenshot.lua): Screenshot plugin
- [`wallpaper`](/plugins/wallpaper.lua): Wallpaper plugin
- [`xwayland`](/plugins/xwayland.lua): XWayland integration

The [default configuration](/default.lua) automatically mounts `borders`, `layout-stacking`, `screenshot`, `wallpaper`, and `xwayland`. The documentation for each plugin can be found in their respective files.

## Usage

The compositor is entirely written in [LuaJIT](https://luajit.org/luajit.html). For this reason, _using_ and _developing_ the compositor is the same process, as you'll be running the compositor from source.

To get started with `boring`, you need the following dependencies installed:

- LuaJIT
- The most recent version of `wlroots`, which at the time of writing is 0.19
- `wlr-protocols` and `wayland-protocols` installed
- `gcc` and `pkg-config`

Some additional dependencies may be needed depending on the plugins you choose to use. The default plugins depend on `xwayland`, which requires `xorg-server` and `libxcb`, as well as `libvips` for the wallpaper and screenshot plugins.

To download the compositor, clone the repository, then use `switch.lua` to launch the compositor program:

```bash
git clone https://github.com/loukamb/boring.git
cd boring
./switch.lua compositor
```

> [!NOTE]
> The first run will take a second or two as it compiles the FFI cache. Subsequent runs will be much faster.

## Development

The dependencies for development are the same as for usage. If you can run the compositor, you're good to go.

### Project tree

- [**`/compositor`**](/compositor/): Source code for the compositor
- [**`/clients`**](/clients/): Tiny programs providing basic desktop functionality
- [**`/shared`**](/shared/): Common utilities shared across the programs in this repo
- [**`/plugins`**](/plugins/): Default plugins
- [**`/website`**](/website/): Website for the project

### Plugins

To write a plugin, put a Lua file in the `~/.config/boring/plugins` directory that returns a table with a `name` field alongside `mount` and `unmount` functions. You can also create a folder and move your plugin's entrypoint to `$DIR/init.lua` if you have to ship multiple files. To enable your plugin, add it to your configuration file:

```lua
-- This will load and mount the plugin.
-- :mount() returns the plugin object.
local my_plugin = plugin("my-plugin"):mount()
```

The second argument of `plugin.mount` will be passed to the plugin's `mount` function, which allows you to pass configuration to the plugin:

```lua
-- config.lua
local my_plugin = plugin("my-plugin"):mount({ value = "hello" })

-- plugins/my-plugin.lua
function plugin:mount(config)
    print(config.value)

    -- This value will be returned to the :mount() invoker.
    return { a = 1 }
end

return plugin
```

Plugins and configuration possess the same environment, so anything that's possible in configuration is possible in plugins. Technically speaking, your configuration file _is_ a plugin with simply special considerations.

For examples on how to write plugins, see the [default plugins](/plugins/).

## License

```
BSD Zero Clause License

Copyright (c) 2026 Louka Ménard Blondin <hello@louka.sh>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.
```
