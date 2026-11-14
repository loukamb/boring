# Architecture and principles

> **Status: draft for discussion.** This describes where the code is going, not
> where it is. Refactors land layer by layer (see [Roadmap](#roadmap)); until a
> layer is done, its old code doesn't follow these rules yet.

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
8. **Hot paths stay JIT-friendly.** Per-frame and per-input-event code avoids
   closures created per call, `pcall`, vararg-heavy helpers, table churn and
   C→Lua callbacks. Cache `ffi.new` scratch buffers at module level.

## Layers

Each layer may only `require` layers below it.

```
plugins/           Window management, borders, wallpaper, … (public API only)
compositor/        Server: core loop, outputs, seat/input, xdg/layer shell,
                   each protocol a self-contained module with setup/teardown
shared/wl/         Lua helpers over the bindings: listener dispatch, scope,
                   wl_list iteration, metatypes for wlroots structs
shared/ffi/        Bindings only: generated cdefs + library loading. No logic.
```

`clients/` (the wallpaper client and future helpers) sit beside `compositor/` and
use `shared/` the same way.

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

**Next:** protocol declarations still come from wayland-scanner headers at
generation time, and protocol enums are typed by hand in places. Since we
already parse protocol XML in Lua (`shared/wayland/protocol.lua`), the
generator should emit interface externs, listener structs and enums from the
XML directly. Some modules (`shared/watch.lua`, `compositor/process.lua`) still
carry hand-written libc cdefs, including arch-dependent structs like
`struct stat`; those move into the generator too.

### Listeners

**Today:** every `wl_listener` gets its own `ffi.cast` callback. LuaJIT has a
fixed number of callback slots, each C→Lua transition stops the JIT, and
destroying a listener scans a global GC-pin array linearly.

**Target:** one C callback for all listeners. Each listener is a small cdata struct
`{ struct wl_listener l; uint32_t id; }`; the shared trampoline reads `id` with
`container_of` and dispatches to a Lua function in an array. Creating or
destroying a listener is O(1), and the number of listeners is unbounded.

## Roadmap

Each step is its own commit (or a small series), with `scripts/vm test` green and
a smoke test in the VM display.

1. ~~**FFI generator + committed bindings.**~~ Done: `shared/clib.lua` is gone
   and the runtime no longer shells out to gcc. Remaining: protocols from XML,
   hand-written libc cdefs.
2. **`shared/wl`:** listener trampoline, `scope`, wl_list iteration, metatypes.
   Delete `shared/emitter.lua`/`events.lua` duplication and generalize `hook`.
3. **Core services** (`compositor/`): split by protocol and responsibility, kill
   cross-service singletons, adopt metatypes. Big files (`input.lua`,
   `surface.lua`) get broken up here.
4. **Plugins:** port to the public API only; `layout-tiling` gets the most work.
5. **New protocols** (see [PROTOCOLS.md](PROTOCOLS.md)): primary selection,
   text-input/input-method, xdg-toplevel-icon, ext-image-copy-capture,
   session-lock and so on, each added as one self-contained module.
