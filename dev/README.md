# Development VM (macOS)

boring needs Linux, wlroots and a seat. On macOS we develop against a small
[Lima](https://lima-vm.io) VM:

- **Fedora 44**, aarch64 or x86_64, using Apple's Virtualization.framework (`vz`).
  Ships wlroots 0.20, wayland-protocols 1.50; LuaJIT is built from the tip of `v2.1`.
- **Live file sync**: your checkout is mounted over virtiofs at the *same path*
  inside the VM, read-write, with inotify forwarding. Edit on the host, run in the
  VM; nothing to copy or rebuild.
- **A real display**: the VM has a virtio-gpu framebuffer plus keyboard and pointer,
  shown in a macOS window. boring runs on it through the DRM + libinput backends,
  just like on hardware, so input, outputs and seat handling are exercised for real.
- **Small**: the disk image is sparse; after provisioning it uses about 1.6 GiB,
  plus a 1.2 GiB cached Fedora image that `limactl prune` removes.

## Usage

```bash
brew install lima
scripts/vm up        # first run downloads Fedora and provisions (a few minutes)
scripts/vm run       # compositor appears in the "boring" VM window
scripts/vm test      # luajit tests/run.lua --suite all, inside the VM
scripts/vm shell     # shell in the VM, already at the repository
scripts/vm down      # stop; `scripts/vm destroy` deletes it
```

`scripts/vm run` defaults to `configs/nested-wayland.lua` because macOS keeps many
Cmd (Super) shortcuts for itself. Inside it, `Alt+Return` spawns `xeyes`,
`Alt+t` opens a `foot` terminal, `Alt+q` closes a window and `Alt+Shift+q` exits.
Clients can also be started from the host: `scripts/vm exec env WAYLAND_DISPLAY=wayland-0 foot`.

Pass compositor arguments through, e.g. `scripts/vm run --config=default.lua`.

## Notes

- The renderer defaults to `pixman`: the `vz` virtio-gpu is 2D-only. Set
  `WLR_RENDERER=gles2` to try Mesa's software GL (llvmpipe) instead.
- The FFI cdef cache lives in the VM (`~/.config/boring/ffi-cache`), not in the
  repository. Clear it with `scripts/vm ffi-clean` after upgrading system headers.
- Packages and VM sizing are in [`lima.yaml`](lima.yaml). After changing it,
  `scripts/vm destroy && scripts/vm up` rebuilds from scratch.
