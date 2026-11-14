# Protocols

The live list comes from the compositor itself, checked against the protocol
XML installed on the machine:

```bash
./boring.lua --protocols            # everything
./boring.lua --protocols=missing    # or =implemented
```

## Implemented

Each protocol lives in one place; `compositor/protocols.lua` holds the ones
wlroots implements for us, as self-contained entries.

| Area | Protocols | Where |
| --- | --- | --- |
| Core | `wl_compositor`, `wl_subcompositor`, `wl_shm`, `wl_output`, `wl_seat`, `wl_data_device_manager` | `server.lua`, `input.lua`, `protocols.lua` |
| Windows | `xdg_wm_base`, `zxdg_decoration_manager_v1`, `xdg_activation_v1`, `xdg_wm_dialog_v1`, `xdg_toplevel_icon_manager_v1`, `xdg_system_bell_v1`, `zxdg_exporter/importer_v1/v2` | `xdg_shell.lua`, `protocols.lua` |
| Shell | `zwlr_layer_shell_v1`, `ext_session_lock_manager_v1` | `layer_shell.lua`, `session_lock.lua` |
| Taskbars | `zwlr_foreign_toplevel_manager_v1`, `ext_foreign_toplevel_list_v1` | `protocols.lua` |
| Input | `zwp_pointer_constraints_v1`, `zwp_relative_pointer_manager_v1`, `zwp_pointer_gestures_v1`, `wp_cursor_shape_manager_v1`, `zwp_keyboard_shortcuts_inhibit_manager_v1` | `pointer.lua`, `protocols.lua` |
| Virtual input | `zwp_virtual_keyboard_manager_v1`, `zwlr_virtual_pointer_manager_v1` | `input.lua` |
| Text input | `zwp_text_input_manager_v3`, `zwp_input_method_manager_v2` | `text_input.lua` |
| Clipboard | `zwp_primary_selection_device_manager_v1`, `zwlr_data_control_manager_v1`, `ext_data_control_manager_v1` | `input.lua`, `protocols.lua` |
| Outputs | `zxdg_output_manager_v1`, `zwlr_output_manager_v1`, `zwlr_output_power_manager_v1`, `zwlr_gamma_control_manager_v1` | `output_management.lua`, `protocols.lua` |
| Capture | `zwlr_screencopy_manager_v1`, `ext_image_copy_capture_manager_v1`, `ext_output_image_capture_source_manager_v1` | `protocols.lua` |
| Surfaces | `wp_viewporter`, `wp_fractional_scale_manager_v1`, `wp_single_pixel_buffer_manager_v1`, `wp_alpha_modifier_v1`, `wp_content_type_manager_v1`, `wp_tearing_control_manager_v1`, `wp_presentation`, `zwp_linux_dmabuf_v1` (GPU renderers) | `protocols.lua` |
| Idle | `ext_idle_notifier_v1`, `zwp_idle_inhibit_manager_v1` | `protocols.lua` |
| X11 | `xwayland_shell_v1` | `plugins/xwayland.lua` |

`tests/integration/clients.lua` drives several of these with real clients
(wtype, wlrctl, wl-clipboard, wlr-randr, swaylock, grim).

## Worth adding next

| Protocol | Why |
| --- | --- |
| `wp_linux_drm_syncobj_manager_v1` | Explicit sync for GPU clients (needs a DRM renderer) |
| `wp_security_context_manager_v1` | Restrict privileged protocols for sandboxed (Flatpak) clients |
| `ext_workspace_manager_v1` | Workspace indicators in panels, once boring has workspaces |
| `xdg_toplevel_tag_manager_v1` | Stable window identities for window rules |
| `ext_foreign_toplevel_image_capture_source_manager_v1` | Window capture for screen sharing |
| `wp_color_manager_v1` | HDR and color management |
| `wp_fifo_manager_v1`, `wp_commit_timing_manager_v1` | Frame pacing for games and video |
| `xdg_toplevel_drag_manager_v1` | Dragging tabs out of windows |

## Out of scope

`wl_shell` (superseded by xdg-shell), `zwp_fullscreen_shell_v1` (kiosk
systems use the kiosk layout instead), `zwp_input_method_v1` /
`zwp_input_panel_v1` (superseded by input-method-v2), `zwlr_input_inhibit_manager_v1`
(superseded by ext-session-lock), `zwlr_export_dmabuf_manager_v1` (superseded
by ext-image-copy-capture).
