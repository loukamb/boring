# Architecture and principles

boring is a Wayland compositor written in LuaJIT on top of wlroots. The goal is
that as much as possible is plain Lua that the JIT can optimize, and that C is
only ever *called*, never generated or patched at runtime.

## Principles

1. **Modules are tables of functions.** A module returns a table of functions and
   constants, and keeps its private state in `local`s. No class hierarchies, no
   `Foo.new()` + `setmetatable` objects for things that are really records.
2. **State is plain tables.** Per-object Lua state (a window's layout data, a
   plugin's bookkeeping) is a plain table, stored in a table keyed by the C
   pointer it belongs to. Pass the state you need as an argument. Avoid module-level
   singletons that other modules reach into.
3. **C objects get methods through `ffi.metatype`.** wlroots objects are used
   directly as cdata: `toplevel:close()`, `node:set_position(x, y)`. Metatypes cost
   nothing per call, allocate nothing, and the JIT sees straight through them.
   This is the *only* routine use of metatables. `setmetatable` is otherwise kept
   for weak-keyed caches and the plugin/config sandbox environment.
4. **No `pcall` for control flow.** Missing symbols, bad cdefs and wrong types are
   bugs; they fail loudly at load time. `pcall`/`xpcall` belong at real isolation
   boundaries: plugin callbacks, config evaluation, and the C→Lua listener
   trampoline (an error must never unwind through wlroots).
5. **One way to do each thing.** One event emitter, one listener mechanism, one
   lifetime helper (`scope`), one place where a given protocol is set up. If two
   modules need the same helper, it moves down a layer instead of being copied.
6. **Lifetimes are explicit.** Everything that registers something (a listener, a
   timer, a scene node, an emitter subscription) does it through a `scope`, and
   closing the scope undoes it. Every wlroots object's `destroy` signal closes the
   scope that belongs to it.
7. **Portability.** No assumptions about architecture, libc or install prefix:
   no hard-coded `/usr/share` paths (use `pkg-config --variable` at generation
   time or `XDG_DATA_DIRS` at runtime), no x86-only type lists.
8. **NULL is `nil`, but cdata is truthy.** A NULL pointer compares equal to
   `nil`, so test pointers with `ptr ~= nil` / `ptr == nil`; never `if ptr then`
   (true for NULL) or `ptr ~= ffi.NULL` (redundant).
9. **Hot paths stay JIT-friendly.** Per-frame and per-input-event code avoids
   closures created per call, `pcall`, vararg-heavy helpers, table churn and
   C→Lua callbacks. Cache `ffi.new` scratch buffers at module level.
10. **Core doesn't manage windows.** Core maps windows, gives them focus and
    input, and tells plugins what clients ask for (`window:request_move`,
    `window:request_fullscreen`, …). Where a window goes, how big it is,
    which ones are visible and what fullscreen means are decided by plugins.
    With no plugin mounted, windows open at the origin of their output and
    stay there.
11. **Plugins are independent.** A plugin requires only `boring` and plugin
    libraries (`plugins/library/`), never another plugin. Plugins that need
    to cooperate do it through shared window properties (`w.props`) and
    events, without knowing each other. Plugins don't touch wlroots or the
    compositor's internals either (`boring.wl`, `boring.server`, scene
    cdata): they draw through `library/scene` and the `boring` API.
    Libraries may go as deep as they need, and so may `xwayland`, which
    integrates an X server.
12. **Use what's installed.** Where the system provides an implementation
    (D-Bus, fonts, image codecs), bind it through the FFI instead of
    reimplementing it, and support the common implementations first-class.
    When none is available, the feature warns and turns itself off; it never
    takes the compositor down.

## Layers

Each layer may only `require` layers below it.

```
plugins/           Layouts, borders, wallpaper, screenshots, XWayland, …
                   (only the `boring` API and plugin libraries)
plugins/library/   Code shared by plugins but not part of core: the scene
                   graph as Lua objects, window management (spaces),
                   workspaces, fullscreen, text, animation, UI widgets
compositor/        The compositor: modules sharing one `server` record
shared/wl/         Lua helpers over the bindings: listener trampoline, scope,
                   wl_list iteration, metatypes for wlroots structs, buffers
shared/wayland/    Protocol XML: parser, registry, runtime wl_interface builder,
                   client-side helpers
shared/ffi/        Bindings only: generated cdefs + library loading. No logic.
```

`clients/` (the wallpaper client) sits beside `compositor/` and uses
`shared/` the same way.

### Compositor modules

`compositor/server.lua` creates the server record (display, backend,
renderer, scene, layers). Every other module exposes `setup(server)`, which
creates its globals and registers its listeners on `server.scope`; there are
no module-level singletons to reach into.

| Module | Responsibility |
| --- | --- |
| `output.lua` | Configure monitors, render frames, output records |
| `input.lua` | Seat, device hotplug, capabilities, cursor images, clipboard |
| `keyboard.lua` | Keymaps, repeat, keyboard shortcuts |
| `pointer.lua` | Cursor, buttons, scrolling, mouse shortcuts, pointer grabs (free move/resize) |
| `shortcuts.lua` | Parsing and matching shortcut strings (pure) |
| `window.lua` | The window object: generic core + role implementation |
| `windows.lua` | Map/unmap, default placement, focus, hit testing |
| `xdg_shell.lua` | xdg toplevels → windows, popups, decorations |
| `layer_shell.lua` | Layer surfaces, exclusive zones, usable area |
| `session_lock.lua` | ext-session-lock: lock screens, fail-closed |
| `text_input.lua` | text-input-v3 ↔ input-method-v2 relay |
| `output_management.lua` | wlr-output-management, output power (DPMS) |
| `protocols.lua` | Protocols wlroots implements, one self-contained entry each |
| `api.lua` | The `boring` API for config and plugins |
| `process.lua` | Child processes, reaped via SIGCHLD on the event loop |
| `watch.lua` | inotify on the event loop (config reload on save) |
| `idle.lua` | Idle timers over input activity, honouring idle inhibitors |
| `clipboard.lua` | A clipboard data source in Lua (`boring.set_clipboard`) |
| `loop.lua` | Timers and fd watches on the event loop, one C callback each |
| `plugin.lua` | Loading and mounting plugins |
| `state.lua` | Loading and reloading the config file |
| `config/` | Config sandbox, rules (`monitor`, `input`), `actions` |

Startup order (`compositor/init.lua`): server → modules → config (which
mounts plugins, so they can use everything) → backend start (outputs and
devices appear, configured from the loaded config) → event loop.

## FFI

Declarations are generated ahead of time and committed; the runtime only
loads shared libraries.

- [`tools/ffi_gen.lua`](tools/ffi_gen.lua) runs at **development time**
  (`scripts/vm ffi-gen`). It preprocesses the headers listed per binding,
  parses the declarations with [`tools/cdecl.lua`](tools/cdecl.lua), and keeps
  every declaration from the root headers (wlroots, wayland, xkbcommon,
  libinput, generated protocol headers) plus a few named libc functions,
  together with the types and constants they transitively need. System headers
  contribute only what's referenced, so arch-specific glibc internals never
  reach the output.
- The result is written to [`shared/ffi/`](shared/ffi/): `server.lua`,
  `client.lua`, and `common.lua` for declarations both need (so they can be
  loaded into one process; LuaJIT refuses to redefine a struct or enum). The
  files are **committed and reviewed.** A wlroots bump means rerunning the
  generator and reading the diff.
- [`tools/ffi_check.lua`](tools/ffi_check.lua) compiles a C program against the
  real headers and compares `sizeof`/`offsetof` for the structs we touch with
  LuaJIT's. CI runs it on x86_64, so bindings generated on aarch64 are checked
  on another architecture on every push.
- At runtime, [`shared/ffi/lib.lua`](shared/ffi/lib.lua) loads the libraries
  by soname (`libwlroots-0.20.so`, `libwayland-server.so.0`, …). No gcc,
  headers, pkg-config or wayland-scanner needed to run boring.

- Protocol headers are produced from the XML by
  [`tools/wlscanner.lua`](tools/wlscanner.lua) (reusing the runtime protocol
  parser), so generation doesn't need wayland-scanner either.
- [`shared/ffi/libc.lua`](shared/ffi/libc.lua) holds every libc function boring
  calls, restricted to arch-independent types (`statx`, not `stat`), plus C
  macro constants (`IN_*`, `O_*`, `SIG*`, …) evaluated by the compiler at
  generation time and exposed as `ffi.C.NAME`. libvips (`shared/image.lua`) is
  still declared by hand: it's a handful of functions on opaque pointers.

### Listeners

**Before:** every `wl_listener` got its own `ffi.cast` callback. LuaJIT has a
fixed number of callback slots, and destroying a listener scanned a global
GC-pin array linearly.

**Now:** one C callback for all listeners ([`shared/wl/listener.lua`](shared/wl/listener.lua)). Each listener is a small cdata struct
`{ struct wl_listener l; uint32_t id; }`; the shared trampoline reads `id` with
`container_of` and dispatches to a Lua function in an array. Creating or
destroying a listener is O(1), and the number of listeners is unbounded.

## Roadmap

Each step is its own commit (or a small series), with `scripts/vm test` green and
a smoke test in the VM display.

1. ~~**FFI generator + committed bindings.**~~ Done: `shared/clib.lua` is gone,
   the runtime no longer shells out to gcc, protocols come from XML, and libc
   declarations are generated.
2. ~~**`shared/wl`:**~~ Done: listener trampoline, `scope`, wl_list iteration,
   metatypes, one emitter (`events.lua` alias and the unused `hook.lua` are
   gone).
3. ~~**Core services**~~ Done: the six singleton services became modules over
   one `server` record (table above); windows are one object type with role
   implementations; config rules are plain tables.
4. ~~**Plugins**~~ Done: every plugin uses only the `boring` API and runs in
   the config environment.
5. ~~**New protocols**~~ Done: session lock, input methods, virtual
   keyboard/pointer, primary selection, data control, output management and
   power, idle notify, gestures, ext-image-copy-capture, ext-foreign-toplevel-list
   and more ([PROTOCOLS.md](PROTOCOLS.md)), with integration tests driving them
   through real clients.

### Plugins

6. ~~**Plugin contract and loader.**~~ Done. A plugin is `{ name, mount(config, ctx),
   unmount? }`. `ctx.scope` is created by the loader and closed on unmount,
   so most plugins need no `unmount`; `ctx.state` is a table that survives
   config reloads. A reload only remounts plugins whose file or config
   changed. Plugin libraries (`require("@boring/library/<name>")`) load once
   per compositor and keep their state across reloads. The plugin registry
   lives on `server`, with one path resolver. `switch.lua` becomes
   `boring.lua`: `./boring.lua` starts the compositor, `./boring.lua run
   <module>` runs one of boring's programs.
7. ~~**Window management out of core.**~~ Done. `compositor/layout.lua` moves to
   `library/spaces`: a space is an area, its windows and its arrangement;
   layout plugins register arrangements with it. Core keeps interactive
   move/resize as a tool (`boring.begin_move`), and turns client requests
   (move, resize, fullscreen, maximize, minimize) into events instead of
   calling layouts. Window placement comes out of the monitor rules: which
   layout a space uses is the layout plugins' configuration.
   `library/workspaces` builds on spaces: several per output, one shown,
   `ext-workspace` for panels.
8. ~~**Shared libraries and clean-up.**~~ Done. `library/text` (text into scene
   buffers: font, colour, max width, ellipsis; taken out of stacking),
   `library/fullscreen` (save geometry, fill the output, restore; used by
   every layout instead of three copies), `color.float4` for the
   premultiplied colours written three times today. Tiling loses its
   `surface` naming and wrappers and gains keyboard commands (directional
   focus and move, split direction, resize). Stacking gets maximize and
   minimize. Urgency (`xdg_activation`, the X11 urgency hint) becomes a
   `window:urgent` event, so borders' `urgent` colour does something.
9. ~~**`library/animate`.**~~ Done. Plugins take plain values or animations
   (`animate.pulse`, `animate.ease`, …, plain tables) without telling them
   apart: `animate.bind(scope, value, apply)` calls `apply(v)` once for a
   plain value and every frame while an animation runs;
   `animate.to(binding, target)` starts a transition. Frames are scheduled
   only while something moves. Borders, stacking and wallpaper take
   animated values; an `animations` plugin animates windows opening and
   closing.
10. ~~**`rules`, `ipc`, `idle`, `layout-master`.**~~ Done.
    - `rules` mounts one function, called for each window before it maps,
      returning properties (`floating`, `size`, `workspace`, `fullscreen`,
      `border`, …) merged into `w.props`. Plugins read the properties they
      understand. Core emits `window:configure` before `window:map` for it.
    - `ipc`: `./boring.lua -e '<lua>'` runs Lua inside the running
      compositor, in the config environment, and prints what it returns;
      `-e -` reads stdin, `-i` is a REPL. A Unix socket at
      `$XDG_RUNTIME_DIR/boring-$WAYLAND_DISPLAY`, mode 0600 (not a Wayland
      protocol: any Wayland client, sandboxed ones included, could use it).
    - `idle`: lock and/or turn outputs off after a timeout, honouring idle
      inhibitors.
    - `layout-master`: master and stack.
11. ~~**`library/ui`.**~~ Done. Widgets drawn in the scene (box, text, image, list,
    input, button), row/column layout, themes as plain tables overridable from
    config. Core gets `boring.grab_keyboard(fn)` / `boring.grab_pointer(fn)`
    so compositor-drawn UI can take input.
12. ~~**Launcher**~~ Done (in the default config). A centred search field with live
    results, keyboard-first. Desktop entries from
    `$XDG_DATA_DIRS/applications` (field codes, `Terminal=true`), icons from
    the icon theme, fuzzy matching ranked by use (`ctx.state`, saved to
    disk). Sources are functions, so windows, a calculator or commands are a
    few lines each.
13. ~~**Screenshots without external tools.**~~ Done. The compositor renders the
    output's scene into a buffer itself; select a region or click a window;
    an editor built on `library/ui` to blur regions (box blur on the pixels)
    and draw (pen, rectangle, arrow); save as PNG through libvips; copy
    through a clipboard data source implemented in Lua. No grim, slurp or
    wl-copy.
14. ~~**Notifications.**~~ Done. Cards stacked in a corner (icon, title, body,
    actions), sliding in through `library/animate`; expiry, click, do not
    disturb, history over `ipc`. Implements `org.freedesktop.Notifications`
    over the installed D-Bus client library (`shared/dbus`, below). Without
    one, or without a session bus, the plugin warns and does nothing.
15. ~~**Insulate plugins.**~~ Done. `library/scene` wraps the scene graph in
    Lua objects (trees, rects, images from pixel canvases; position, size,
    colour, opacity, snapshots, clicks), one object per node. `text` and
    `ui` hand those out instead of scene cdata. Borders, wallpaper,
    stacking, animations, screenshots and notifications use it, and
    `boring.locked()`, `boring.socket()` and `o:scale()` replace their reads
    of `boring.server` and `o.wlr`. Only libraries and `xwayland` use
    `boring.wl` and `boring.server`.

### D-Bus

boring doesn't implement D-Bus; it binds a client library that's already
installed. Bus daemons (dbus-daemon, dbus-broker) speak the same protocol, so
only the client library matters. `shared/dbus` exposes one small interface
(connect to the session bus, own a name, export methods, emit signals, call)
over two backends, tried in order:

| Backend | Libraries (same API) | Where |
| --- | --- | --- |
| sd-bus | `libsystemd.so.0`, `libelogind.so.0`, `libbasu.so.0` | systemd distros; elogind (Gentoo, Artix, Void); basu (Alpine, FreeBSD) |
| libdbus | `libdbus-1.so.3` | Practically everywhere else |

sd-bus comes first: the connection is one fd plus a timeout
(`sd_bus_get_fd`, `sd_bus_get_events`, `sd_bus_get_timeout`,
`sd_bus_process`), which maps directly onto `wl_event_loop` with no C→Lua
watch callbacks. libdbus needs watch and timeout callbacks
(`dbus_connection_set_watch_functions`), a few `ffi.cast`s at connection
setup. GDBus (gio, pulled in by libvips) is left out: it wants a GLib main
loop.
