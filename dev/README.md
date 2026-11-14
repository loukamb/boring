# Development VM (macOS)

boring needs Linux and wlroots. On macOS we develop against a small, headless
[Lima](https://lima-vm.io) VM:

- **Fedora 44**, aarch64 or x86_64, using Apple's Virtualization.framework (`vz`).
  Ships wlroots 0.20, wayland-protocols 1.50; LuaJIT is built from the tip of `v2.1`.
- **Live file sync**: your checkout is mounted over virtiofs at the *same path*
  inside the VM, read-write, with inotify forwarding. Edit on the host, run in the
  VM; nothing to copy or rebuild.
- **Headless**: no window. boring runs on wlroots' headless backend (one 1280×720
  output) and `scripts/vm screenshot` captures what it renders through boring's
  own screencopy, so you see exactly what clients would.
- **Small**: the disk image is sparse; after provisioning it uses about 1.6 GiB,
  plus a 1.2 GiB cached Fedora image that `limactl prune` removes.

## Usage

```bash
brew install lima
scripts/vm up                 # first run downloads Fedora and provisions (a few minutes)
scripts/vm run                # compositor, in the foreground; Ctrl-C or `scripts/vm kill`
scripts/vm client foot        # start a Wayland client against it (another terminal)
scripts/vm screenshot         # -> vm-screenshot.png
scripts/vm test               # luajit tests/run.lua --suite all, inside the VM
scripts/vm ffi-gen            # regenerate shared/ffi and check struct layouts
scripts/vm shell              # shell in the VM, already at the repository
scripts/vm down               # stop; `scripts/vm destroy` deletes it
```

`scripts/vm run` defaults to `configs/nested-wayland.lua` (it starts `xeyes`);
pass another with `scripts/vm run --config=default.lua`. Edit the config on the
host and save: the compositor in the VM reloads it.

`scripts/smoke [out.png] [compositor args]` starts boring headless, opens an X11
and a Wayland client, screenshots, and fails on errors in the log.

## With a display

To interact with boring by hand, create the VM with a window instead:

```bash
scripts/vm destroy
BORING_VM_DISPLAY=vz scripts/vm up
```

The VM then gets a virtio-gpu framebuffer plus keyboard and pointer in a macOS
window, and `scripts/vm run` uses the DRM + libinput backends on it, like real
hardware. In `configs/nested-wayland.lua`, `Alt+Return` spawns `xeyes`, `Alt+t`
opens `foot`, `Alt+q` closes a window and `Alt+Shift+q` exits (macOS keeps most
Cmd shortcuts for itself).

## Notes

- The renderer defaults to `pixman`; there's no GPU in the VM.
- Packages and VM sizing are in [`lima.yaml`](lima.yaml). After changing it,
  `scripts/vm destroy && scripts/vm up` rebuilds from scratch.
