## 🍎 Low Hanging Fruit (wlroots handles for us)

| Done | Protocol                            | wlroots API                                 | Notes                                |
| :--: | ----------------------------------- | ------------------------------------------- | ------------------------------------ |
| [x]  | `wl_buffer`                         | Internal to wl_shm                          | Already working, just not registered |
| [x]  | `wl_callback`                       | Internal to wl_surface                      | Frame callbacks work                 |
| [x]  | `wl_region`                         | Internal to wl_surface                      | Damage regions work                  |
| [x]  | `wl_shm_pool`                       | Part of wl_shm                              | Already working                      |
| [x]  | `wp_viewporter`                     | `wlr_viewporter_create`                     | Simple one-liner                     |
| [x]  | `wp_viewport`                       | Created by viewporter                       | Auto-created per surface             |
| [x]  | `wp_single_pixel_buffer_manager_v1` | `wlr_single_pixel_buffer_manager_v1_create` | Created in surface service           |
| [x]  | `wp_cursor_shape_manager_v1`        | `wlr_cursor_shape_manager_v1_create`        | One-liner in input                   |
| [x]  | `wp_cursor_shape_device_v1`         | Created by manager                          | Auto-created                         |
| [x]  | `zxdg_output_manager_v1`            | `wlr_xdg_output_manager_v1_create`          | One-liner, useful for multi-monitor  |
| [x]  | `zxdg_output_v1`                    | Created by manager                          | Auto-created                         |

## ✅ Easy (No new services needed)

| Done | Protocol                                    | wlroots API                              | Location          | Notes                                       |
| :--: | ------------------------------------------- | ---------------------------------------- | ----------------- | ------------------------------------------- |
| [x]  | `xdg_activation_v1`                         | `wlr_xdg_activation_v1_create`           | surface.lua       | Window focus stealing prevention            |
| [x]  | `xdg_activation_token_v1`                   | Created by manager                       | surface.lua       |                                             |
| [x]  | `zwlr_screencopy_manager_v1`                | `wlr_screencopy_manager_v1_create`       | output.lua        | Screenshot support for external tools       |
| [x]  | `zwlr_screencopy_frame_v1`                  | Created by manager                       |                   |                                             |
| [x]  | `zwlr_gamma_control_manager_v1`             | `wlr_gamma_control_manager_v1_create`    | output.lua        | Night light support                         |
| [x]  | `zwlr_gamma_control_v1`                     | Created by manager                       |                   |                                             |
| [x]  | `zwp_idle_inhibit_manager_v1`               | `wlr_idle_inhibit_v1_create`             | surface.lua       | Prevent sleep during video                  |
| [x]  | `zwp_idle_inhibitor_v1`                     | Created by manager                       |                   |                                             |
| [x]  | `zwp_pointer_constraints_v1`                | `wlr_pointer_constraints_v1_create`      | input.lua         | Game mouse lock                             |
| [x]  | `zwp_confined_pointer_v1`                   | Created by manager                       |                   |                                             |
| [x]  | `zwp_locked_pointer_v1`                     | Created by manager                       |                   |                                             |
| [x]  | `zwp_relative_pointer_manager_v1`           | `wlr_relative_pointer_manager_v1_create` | input.lua         | FPS games need this                         |
| [x]  | `zwp_relative_pointer_v1`                   | Created by manager                       |                   |                                             |
| [x]  | `zxdg_decoration_manager_v1`                | `wlr_xdg_decoration_manager_v1_create`   | surface.lua       | CSD/SSD negotiation                         |
| [x]  | `zxdg_toplevel_decoration_v1`               | Created by manager                       |                   |                                             |
| [x]  | `xwayland_shell_v1` / `xwayland_surface_v1` | Registered by xwayland plugin            | xwayland.lua      | Enabled when the plugin mounts              |

## ⚙️ Medium (Minor service additions)

| Done | Protocol                                    | Complexity | Notes                                                             |
| :--: | ------------------------------------------- | ---------- | ----------------------------------------------------------------- |
| [ ]  | `zwlr_output_manager_v1`                    | Medium     | Output configuration (resolution, position). Needs state tracking |
| [ ]  | `zwlr_output_head_v1`                       | Medium     | Per-output info                                                   |
| [ ]  | `zwlr_output_mode_v1`                       | Medium     | Mode enumeration                                                  |
| [ ]  | `zwlr_output_configuration_v1`              | Medium     | Apply configuration                                               |
| [ ]  | `zwlr_output_configuration_head_v1`         | Medium     | Per-head config                                                   |
| [ ]  | `zwlr_output_power_manager_v1`              | Medium     | DPMS power control                                                |
| [ ]  | `zwlr_output_power_v1`                      | Medium     | Per-output power                                                  |
| [ ]  | `zwlr_data_control_manager_v1`              | Medium     | Clipboard manager access (wlr-data-control)                       |
| [ ]  | `zwlr_data_control_device_v1`               | Medium     |                                                                   |
| [ ]  | `zwlr_data_control_offer_v1`                | Medium     |                                                                   |
| [ ]  | `zwlr_data_control_source_v1`               | Medium     |                                                                   |
| [ ]  | `zwp_primary_selection_device_manager_v1`   | Medium     | Middle-click paste                                                |
| [ ]  | `zwp_primary_selection_device_v1`           | Medium     |                                                                   |
| [ ]  | `zwp_primary_selection_offer_v1`            | Medium     |                                                                   |
| [ ]  | `zwp_primary_selection_source_v1`           | Medium     |                                                                   |
| [ ]  | `zwp_keyboard_shortcuts_inhibit_manager_v1` | Medium     | Let apps grab shortcuts                                           |
| [ ]  | `zwp_keyboard_shortcuts_inhibitor_v1`       | Medium     |                                                                   |
| [ ]  | `zwp_pointer_gestures_v1`                   | Medium     | Touchpad gestures                                                 |

## 🔨 Hard (Significant new functionality)

| Done | Protocol                                | Complexity | Notes                                 |
| :--: | --------------------------------------- | ---------- | ------------------------------------- |
| [ ]  | `zwp_text_input_manager_v3`             | Hard       | Virtual keyboard / IME support        |
| [ ]  | `zwp_text_input_v3`                     | Hard       | Requires text editing state machine   |
| [ ]  | `zwp_input_method_v1`                   | Hard       | Input method protocol                 |
| [ ]  | `zwp_input_method_context_v1`           | Hard       |                                       |
| [ ]  | `zwp_input_panel_v1`                    | Hard       | On-screen keyboard                    |
| [ ]  | `zwp_input_panel_surface_v1`            | Hard       |                                       |
| [ ]  | `zwp_linux_dmabuf_v1`                   | Hard       | DMA-BUF buffer sharing (GPU textures) |
| [ ]  | `zwp_linux_dmabuf_feedback_v1`          | Hard       | Requires GPU device handling          |
| [ ]  | `zwp_linux_buffer_params_v1`            | Hard       |                                       |
| [ ]  | `zwp_linux_buffer_release_v1`           | Hard       |                                       |
| [ ]  | `zwp_linux_explicit_synchronization_v1` | Hard       | GPU fence synchronization             |
| [ ]  | `zwp_linux_surface_synchronization_v1`  | Hard       |                                       |
| [ ]  | `wp_linux_drm_syncobj_manager_v1`       | Hard       | Newer sync protocol                   |
| [ ]  | `wp_presentation`                       | Hard       | Frame timing feedback                 |
| [ ]  | `wp_presentation_feedback`              | Hard       |                                       |
| [ ]  | `ext_session_lock_manager_v1`           | Hard       | Lock screen protocol                  |
| [ ]  | `ext_session_lock_v1`                   | Hard       |                                       |
| [ ]  | `ext_session_lock_surface_v1`           | Hard       |                                       |
| [ ]  | `zwlr_virtual_pointer_manager_v1`       | Hard       | Virtual input devices                 |
| [ ]  | `zwlr_virtual_pointer_v1`               | Hard       |                                       |
| [ ]  | `zwlr_export_dmabuf_manager_v1`         | Hard       | Screen recording (DMA-BUF)            |
| [ ]  | `zwlr_export_dmabuf_frame_v1`           | Hard       |                                       |

## 🚫 Out of Scope

### Deprecated / Superseded Protocols

| Done | Protocol                                                                        | Reason                                   |
| :--: | ------------------------------------------------------------------------------- | ---------------------------------------- |
| [x]  | `wl_shell` / `wl_shell_surface`                                                 | Deprecated, superseded by xdg_shell      |
| [x]  | `zxdg_shell_v6`                                                                 | Deprecated, superseded by xdg_wm_base v7 |
| [x]  | `zxdg_surface_v6` / `zxdg_toplevel_v6` / `zxdg_popup_v6` / `zxdg_positioner_v6` | Deprecated v6 versions                   |
| [x]  | `xdg_shell` (v1)                                                                | Old unstable version                     |
| [x]  | `zwp_input_timestamps_*`                                                        | Rarely used                              |
| [x]  | `zwp_fullscreen_shell_*`                                                        | For embedded/kiosk systems               |

### Rarely Needed / Niche

| Done | Protocol                             | Reason                               |
| :--: | ------------------------------------ | ------------------------------------ |
| [ ]  | `zwp_tablet_*` (all 20+ interfaces)  | Graphics tablet support - niche      |
| [ ]  | `wp_drm_lease_*`                     | VR headset leasing - very niche      |
| [ ]  | `wp_color_management_*`              | HDR/color profiles - advanced        |
| [ ]  | `wp_color_representation_*`          | Color space handling - advanced      |
| [ ]  | `wp_image_description_*`             | HDR metadata - advanced              |
| [ ]  | `wp_commit_timing_*`                 | Frame timing optimization            |
| [ ]  | `wp_fifo_*`                          | Buffer queue management              |
| [ ]  | `wp_alpha_modifier_*`                | Per-surface alpha                    |
| [ ]  | `wp_security_context_*`              | Sandboxing/Flatpak                   |
| [ ]  | `ext_foreign_toplevel_*`             | Alternative to zwlr version          |
| [ ]  | `ext_idle_notification_*`            | Alternative to zwp version           |
| [ ]  | `ext_transient_seat_*`               | Multi-seat - niche                   |
| [ ]  | `ext_workspace_*`                    | Workspace protocol - we have our own |
| [ ]  | `zxdg_exporter/importer_*`           | Cross-client window embedding        |
| [ ]  | `xdg_toplevel_drag_*`                | Drag windows between apps            |
| [ ]  | `xdg_toplevel_icon_*`                | Per-window icons                     |
| [ ]  | `xdg_toplevel_tag_*`                 | Window tagging                       |
| [ ]  | `xdg_dialog_v1` / `xdg_wm_dialog_v1` | Modal dialog hints                   |
| [ ]  | `xdg_system_bell_v1`                 | System beep                          |
| [ ]  | `wl_fixes`                           | Protocol bug workarounds             |
| [ ]  | `wl_display`                         | Internal - can't be "missing"        |
| [ ]  | `zwp_xwayland_keyboard_grab_*`       | XWayland keyboard grabs              |
