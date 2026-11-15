<h1>boring</h1>
<p>
    <img src="/website/public/favicon.png" height="64" align="left"></img>
</p>

This is the monorepository for the boring Wayland compositor. As the name implies, it is boring by default. However, the hacker in you will probably love it.

## Overview

>[!WARNING]
>This is an experiment in developing a LuaJIT-based Wayland compositor. It isn't ready for serious desktop usage. I'm not currently working on it (as of June 28, 2026) and there's a lot of clean-up that must be done before feature development is continued.

`boring` is a minimalist, non-monolithic Wayland compositor built on [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots/) that is designed to be hackable and extensible, reminiscent of [dwm](https://git.suckless.org/dwm/) and [dwl](https://codeberg.org/dwl/dwl). Functionality is provided through plugins; we give you the tools and leave you to play.

A set of default plugins are included that provides basic window management and Wayland functionality for those that don't want to spend too much time writing their own:

- [`animations`](/plugins/animations.lua): Windows fade in and out as they open and close
- [`borders`](/plugins/borders.lua): Draw borders around windows
- [`idle`](/plugins/idle.lua): Lock and turn the screens off after a while without input
- [`ipc`](/plugins/ipc.lua): Run Lua in the running compositor: `./boring.lua -e 'return #boring.windows()'`, or `./boring.lua -i` for a REPL
- [`launcher`](/plugins/launcher.lua): A search field for applications, windows and arithmetic (Super+Space in the default config)
- [`layout-master`](/plugins/layout-master.lua): Master and stack layout
- [`layout-stacking`](/plugins/layout-stacking.lua): Traditional stacking layout
- [`layout-tiling`](/plugins/layout-tiling.lua): Sway-inspired n-ary tiling layout
- [`layout-kiosk`](/plugins/layout-kiosk.lua): Runs a single, maximized window
- [`notifications`](/plugins/notifications.lua): Notification cards stacked in a corner, from applications over D-Bus (through the installed sd-bus or libdbus), with actions, do not disturb and history
- [`rules`](/plugins/rules.lua): Window rules as Lua functions returning properties (floating, size, workspace, …)
- [`workspaces`](/plugins/workspaces.lua): Several workspaces per output, shown to panels over `ext-workspace`
- [`screenshot`](/plugins/screenshot.lua): Screenshots of an area, a window or an output, with blur, pen, box and arrow tools; saved as PNG and copied, with no external tools
- [`wallpaper`](/plugins/wallpaper.lua): Wallpaper plugin
- [`xwayland`](/plugins/xwayland.lua): XWayland integration

The [default configuration](/default.lua) automatically mounts `animations`, `borders`, `ipc`, `launcher`, `layout-stacking`, `notifications`, `screenshot`, `wallpaper`, and `xwayland`. The documentation for each plugin can be found in their respective files.

## Usage

The compositor is entirely written in [LuaJIT](https://luajit.org/luajit.html). For this reason, _using_ and _developing_ the compositor is the same process, as you'll be running the compositor from source.

To get started with `boring`, you need the following dependencies installed:

- LuaJIT
- The most recent version of `wlroots`, which at the time of writing is 0.20, plus `libinput` and `libxkbcommon`
- `wlr-protocols` and `wayland-protocols` installed

No compiler or `-devel` headers are needed: the FFI declarations are generated ahead of time and committed under [`shared/ffi`](/shared/ffi/).

Some additional dependencies may be needed depending on the plugins you choose to use. The default plugins depend on `xwayland`, which requires `xorg-server` and `libxcb`, as well as `libvips` for text, icons, images and screenshots. Notifications use the D-Bus client library that's installed (`libsystemd`, `libelogind`, `libbasu` or `libdbus`) and turn themselves off without one.

To try the compositor inside your current Wayland session, run it nested with
wlroots' Wayland backend; it opens as a regular window on your host compositor:

```bash
WLR_BACKENDS=wayland ./boring.lua --config=configs/nested-wayland.lua
```

`configs/nested-wayland.lua` avoids host-reserved Super-key shortcuts,
launches `xeyes` once on startup, and binds:

- `Alt+Return` or `Ctrl+Alt+Return`: launch `xeyes`
- `Alt+t`: launch `foot`
- `Alt+q`: close the focused window
- `Alt+Shift+q` or `Ctrl+Alt+q`: exit the compositor

On macOS, use the development VM instead; see [`dev/README.md`](/dev/README.md).

Saving the configuration file reloads it (plugins are remounted, keyboards reconfigured); a config with errors is refused and the running one stays. Pass `--watch=false` to turn that off.

To download the compositor, clone the repository, then run `boring.lua` from it:

```bash
git clone https://github.com/loukamb/boring.git
cd boring
./boring.lua
```

## Development

The dependencies for development are the same as for usage. If you can run the compositor, you're good to go.

### Project tree

- [**`/compositor`**](/compositor/): The compositor: one module per responsibility, sharing a `server` record
- [**`/plugins`**](/plugins/): Default plugins
- [**`/clients`**](/clients/): Tiny programs providing basic desktop functionality
- [**`/shared`**](/shared/): Code shared by the programs: FFI bindings (`ffi`), wlroots helpers (`wl`), utilities
- [**`/tools`**](/tools/): Development tools (FFI binding generator and checks)
- [**`/dev`**](/dev/): Development VM for macOS
- [**`/website`**](/website/): Website for the project

See [ARCHITECTURE.md](/ARCHITECTURE.md) for the design and coding principles.

### FFI bindings

The C declarations LuaJIT needs live in [`shared/ffi`](/shared/ffi/) and are generated by [`tools/ffi_gen.lua`](/tools/ffi_gen.lua) from the installed headers. Regenerate them after bumping wlroots (or adding a header or protocol to the generator), then check the struct layouts against the C compiler and review the diff:

```bash
luajit tools/ffi_gen.lua && luajit tools/ffi_check.lua    # or: scripts/vm ffi-gen
```

Generation needs `gcc`, `pkg-config` and the `-devel` packages; running boring doesn't.

### Testing

Tests are split by how much compositor machinery they need:

- `tests/unit`: pure Lua and parser/config tests.
- `tests/service`: wlroots-adjacent service and plugin tests using fake objects or direct helper APIs.
- `tests/integration`: headless compositor scenarios driven through `tests/harness`.

Run the full suite locally with:

```bash
luajit tests/run.lua --suite all
```

CI uses TAP output:

```bash
luajit tests/run.lua --suite unit --format tap
luajit tests/run.lua --suite service --format tap
luajit tests/run.lua --suite integration --format tap
```

Lifecycle hygiene check:

```bash
rg "listener\.connect|setmetatable" compositor plugins
```

This should only match `compositor/config` and `compositor/plugin.lua` (the sandbox environments for config and plugins). Listeners in compositor modules and plugins go through a scope (`scope:listen`), so they're disconnected when the object they belong to goes away.

### Plugins

To write a plugin, put a Lua file in the `~/.config/boring/plugins` directory that returns a table with a `name` field and a `mount` function. You can also create a folder and move your plugin's entrypoint to `$DIR/init.lua` if you have to ship multiple files, or mount a file by path (`plugin("./my-plugin.lua")`). To enable your plugin, add it to your configuration file:

```lua
-- This will load and mount the plugin.
-- :mount() returns the plugin object.
local my_plugin = plugin("my-plugin"):mount()
```

The table passed to `:mount` is given to the plugin's `mount` function, which allows you to pass configuration to the plugin:

```lua
-- config.lua
local my_plugin = plugin("my-plugin"):mount({ value = "hello" })

-- plugins/my-plugin.lua
local plugin = { name = "my-plugin" }

function plugin:mount(config, ctx)
    print(config.value)

    -- This value will be returned to the :mount() invoker.
    return { a = 1 }
end

return plugin
```

Plugins and configuration share the same globals, so anything that's possible in configuration is possible in plugins. Both talk to the compositor through the `boring` global ([`compositor/api.lua`](/compositor/api.lua)). `mount` also gets a `ctx` ([`compositor/plugin.lua`](/compositor/plugin.lua)):

- `ctx.scope` undoes everything registered through it when the plugin is unmounted, so most plugins need no `unmount` function (it's optional).
- `ctx.state` is a table that survives config reloads, for state that shouldn't be lost when the plugin is remounted.

```lua
function plugin:mount(config, ctx)
    ctx.scope:subscribe(boring.events, "window:map", function(window)
        print("new window", window:title(), window:app_id())
        window:set_position(100, 100)
    end)
    ctx.scope:defer(function() print("unmounted") end)
end
```

When the config is saved, plugins it mounts with the same config (and an unchanged file) stay mounted; the others are remounted, and plugins it no longer mounts are unmounted.

Plugins don't require each other. Code shared between plugins goes in a library, `require("@boring/library/<name>")`, which is loaded once per compositor and kept across reloads. The included ones:

- [`scene`](/plugins/library/scene.lua): the scene graph as Lua objects: trees, solid rects and images, with position, size, colour, opacity, snapshots and clicks
- [`spaces`](/plugins/library/spaces.lua): windows grouped into spaces per output and arranged by layout plugins
- [`workspaces`](/plugins/library/workspaces.lua): several spaces per output, published over `ext-workspace`
- [`fullscreen`](/plugins/library/fullscreen.lua): fill an output and put the window back afterwards
- [`text`](/plugins/library/text.lua): text drawn into the scene, with ellipsis and wrapping
- [`animate`](/plugins/library/animate.lua): animated values; borders, stacking and wallpaper colours take them anywhere they take a colour
- [`desktop`](/plugins/library/desktop.lua): desktop entries (localised, filtered, field codes) and icon theme lookup
- [`capture`](/plugins/library/capture.lua) and [`pixels`](/plugins/library/pixels.lua): the screen read back as pixels, and drawing on them (blur, lines, boxes, arrows)
- [`ui`](/plugins/library/ui.lua): widgets the compositor draws itself (text, images, boxes with rounded corners, rows, columns, buttons, inputs, lists), themed with plain tables; `boring.grab_keyboard` and `boring.grab_pointer` give them input

Events: `window:map`, `window:unmap`, `window:focus`, `window:blur`, `window:commit`, `window:title`, `window:fullscreen`, `window:maximize`, `window:urgent`, `output:add`, `output:change`, `output:usable`, `output:remove`, `ready`, `shutdown`. Windows have `position`, `set_position`, `geometry`, `bounds`, `size`, `set_size`, `raise`, `close`, `title`, `app_id`, `set_enabled`, `visible`, `set_fullscreen`, `set_maximized`, `set_urgent` and a `data` table for plugin state ([`compositor/window.lua`](/compositor/window.lua)).

Core doesn't manage windows: a new window opens at the origin of the output under the cursor, and what clients ask for arrives as events (`window:request_move`, `window:request_resize`, `window:request_fullscreen`, `window:request_maximize`, `window:request_minimize`) for plugins to answer. `boring.begin_move`, `boring.begin_resize` and `boring.grab_pointer` are the tools for it. The layout plugins share [`library/spaces`](/plugins/library/spaces.lua), which documents how to write one. Plugins draw through [`library/scene`](/plugins/library/scene.lua). Libraries that need more have `boring.wl` (wlroots itself) and `boring.server` (the compositor's objects); plugins stay off them.

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
