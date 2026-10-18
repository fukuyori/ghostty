# Configuration Support on Windows

This table lists every option in upstream Ghostty's configuration
(`src/config/Config.zig`) with its status in the native Windows build, as of
`1.3.2-windows.16`. Options appear in the same order as in the upstream
reference. See the [user guide](windows.md) for the configuration file
location and Windows-specific behavior. A Japanese translation is in
[windows-config-support.ja.md](windows-config-support.ja.md).

A ◎ status means a runtime check of the option, or of the feature it
controls, is recorded in the [port log](windows-port-log.md) or the
[roadmap](windows-roadmap.md); the note names the record. A ○ status is
based on reading the code: the code that honors the option runs on Windows,
but no runtime check is recorded. △ and ✕ are also judged from the code
unless the note cites a check.

| Option | Category | Status | Notes |
|---|---|---|---|
| `language` | GTK | - | GTK only; the Windows UI is not localized through this setting. |
| `font-family` | Font | ◎ | Matches family names (not full/style names); check with +list-fonts. Verified: roadmap #1/#2 (2026-09-28). |
| `font-family-bold` | Font | ○ |  |
| `font-family-italic` | Font | ○ |  |
| `font-family-bold-italic` | Font | ○ |  |
| `font-style` | Font | ○ | Explicit style names are matched exactly; a missing style falls back to synthesis. |
| `font-style-bold` | Font | ○ |  |
| `font-style-italic` | Font | ○ |  |
| `font-style-bold-italic` | Font | ○ |  |
| `font-synthetic-style` | Font | ○ |  |
| `font-feature` | Font | ○ |  |
| `font-size` | Font | ◎ | Verified: roadmap #3 (2026-09-28) at 12/16/24 pt and 100-200% DPI. |
| `font-variation` | Font | ○ | Not applied to DirectWrite system-fallback faces. |
| `font-variation-bold` | Font | ○ |  |
| `font-variation-italic` | Font | ○ |  |
| `font-variation-bold-italic` | Font | ○ |  |
| `font-codepoint-map` | Font | ◎ | Verified: roadmap #3 (2026-09-28) with Noto Sans JP; mapped faces still get fallback size adjustment. |
| `clipboard-codepoint-map` | Clipboard | ○ |  |
| `font-thicken` | Font | - | macOS (CoreText) only; the FreeType renderer used on Windows ignores it. |
| `font-thicken-strength` | Font | - | macOS (CoreText) only; ignored on Windows. |
| `font-shaping-break` | Font | ○ |  |
| `alpha-blending` | Rendering | ○ |  |
| `adjust-cell-width` | Font | ○ |  |
| `adjust-cell-height` | Font | ○ |  |
| `adjust-font-baseline` | Font | ○ |  |
| `adjust-underline-position` | Font | ○ |  |
| `adjust-underline-thickness` | Font | ○ |  |
| `adjust-strikethrough-position` | Font | ○ |  |
| `adjust-strikethrough-thickness` | Font | ○ |  |
| `adjust-overline-position` | Font | ○ |  |
| `adjust-overline-thickness` | Font | ○ |  |
| `adjust-cursor-thickness` | Cursor | ○ |  |
| `adjust-cursor-height` | Cursor | ○ |  |
| `adjust-box-thickness` | Font | ○ |  |
| `adjust-icon-height` | Font | ○ |  |
| `grapheme-width-method` | Terminal | ○ |  |
| `freetype-load-flags` | Font | ○ | Applies on Windows because this build renders fonts with FreeType. |
| `theme` | Colors | △ | Single themes work. light:/dark: pairs always use the light theme because Windows does not report the system color scheme. |
| `background` | Colors | ◎ | Verified: port log 2026-10-14 window-appearance check sampled the configured background color. |
| `foreground` | Colors | ○ |  |
| `background-image` | Background | ○ |  |
| `background-image-opacity` | Background | ○ |  |
| `background-image-position` | Background | ○ |  |
| `background-image-fit` | Background | ○ |  |
| `background-image-repeat` | Background | ○ |  |
| `selection-foreground` | Colors | ○ |  |
| `selection-background` | Colors | ○ |  |
| `selection-clear-on-typing` | Selection | ○ |  |
| `selection-clear-on-copy` | Selection | ○ |  |
| `selection-word-chars` | Selection | ○ |  |
| `minimum-contrast` | Colors | ○ |  |
| `palette` | Colors | ○ |  |
| `palette-generate` | Colors | ○ |  |
| `palette-harmonious` | Colors | ○ |  |
| `cursor-color` | Cursor | ○ |  |
| `cursor-opacity` | Cursor | ○ |  |
| `cursor-style` | Cursor | ○ |  |
| `cursor-style-blink` | Cursor | ○ |  |
| `cursor-text` | Cursor | ○ |  |
| `cursor-click-to-move` | Cursor | ○ | Requires OSC 133 prompt marking; the automatic PowerShell integration does not emit it. |
| `mouse-hide-while-typing` | Mouse | ○ |  |
| `scroll-to-bottom` | Terminal | ○ |  |
| `mouse-shift-capture` | Mouse | ○ |  |
| `mouse-reporting` | Mouse | ○ |  |
| `mouse-scroll-multiplier` | Mouse | △ | Only the discrete value applies; Windows sends all wheel and touchpad scrolling as non-precision events, so precision is ignored. |
| `background-opacity` | Background | ◎ | Verified: port log 2026-10-14 pixel check and 2026-10-15 owner manual check. |
| `background-opacity-cells` | Background | ○ |  |
| `background-blur` | Background | △ | Blur applies only when background-opacity < 1; quality varies by system (#11). macos-glass-* values act as true. |
| `unfocused-split-opacity` | Tabs/Splits | ✕ | Unfocused panes are not dimmed on Windows. |
| `unfocused-split-fill` | Tabs/Splits | ✕ | Ignored; unfocused panes are not dimmed on Windows. |
| `split-divider-color` | Tabs/Splits | ✕ | Ignored; the divider color is blended from background and foreground (system colors in high contrast). |
| `split-preserve-zoom` | Tabs/Splits | ○ |  |
| `search-foreground` | Colors | ○ | Terminal search verified in 1.3.2-windows.11; custom colors not specifically checked. |
| `search-background` | Colors | ○ | Terminal search verified in 1.3.2-windows.11; custom colors not specifically checked. |
| `search-selected-foreground` | Colors | ○ |  |
| `search-selected-background` | Colors | ○ |  |
| `command` | Shell | ◎ | Runs through ConPTY. Verified: CLI --command (port log 2026-10-17, F6), IPC +new-tab -e (port log 2026-10-15); used by the native regression scripts. |
| `initial-command` | Shell | ○ | Set by -e; applies to the first surface only. |
| `notify-on-command-finish` | Notifications | ◎ | Needs OSC 133 (bundled Bash integration or a prompt emitting it); automatic PowerShell integration does not. No GTK per-command menu. Verified: port log 2026-10-18 (F8). |
| `notify-on-command-finish-action` | Notifications | ◎ | bell uses bell-features; notify shows a Windows toast. Verified: port log 2026-10-18 (F8, bell,notify). |
| `notify-on-command-finish-after` | Notifications | ◎ | Verified: port log 2026-10-18 (F8, 10s threshold; 5 s command not notified). |
| `env` | Shell | ○ | Passed to the ConPTY child through the Windows environment block. |
| `input` | Shell | ○ |  |
| `wait-after-command` | Shell | ○ | Shows the terminal-text 'Process exited. Press any key' message; no native dialog on Windows. |
| `abnormal-command-exit-runtime` | Shell | ○ | As on Linux, only a non-zero exit within the threshold counts; the error is shown as terminal text. |
| `scrollback-limit-bytes` | Scrollback | ○ |  |
| `scrollback-limit-lines` | Scrollback | ◎ | Verified: F2 scrollbar history checks used scrollback-limit-lines = 64 (roadmap, F2 acceptance). |
| `scrollback-compression` | Scrollback | ○ | Uses DiscardVirtualMemory on Windows. |
| `scrollbar` | Scrollback | ◎ | system shows a per-pane overlay scrollbar while scrolling or hovering the right edge; never disables it. Verified: F2 acceptance. |
| `link` | Links | ✕ | Not implemented upstream either: the parser rejects it in every build. Only the built-in URL matcher exists. |
| `link-url` | Links | ◎ | Ctrl+click opens plain-text URLs via ShellExecuteW. Verified: roadmap #47 (2026-10-12). |
| `link-osc8` | Links | ◎ | http/https/mailto open; other schemes ask for confirmation; file: links are blocked. Verified: roadmap #36 (2026-10-12). |
| `link-previews` | Links | ✕ | Win32 does not show the hovered link URL; the preview setting has no visible effect. |
| `maximize` | Window | ◎ | Not applied to the quick terminal. Verified: port log 2026-10-15 (#12 final verification). |
| `fullscreen` | Window | ◎ | macOS non-native modes behave like true. Not applied to the quick terminal. Verified: port log 2026-10-15 (#12). |
| `title` | Window | ◎ | Verified via IPC +new-tab --title, which sets this option for the new tab (port log 2026-10-15). |
| `class` | GTK | - | GTK only (WM_CLASS, Wayland app ID, DBus). +new-tab --class is rejected on Windows. |
| `x11-instance-name` | GTK | - | X11 only. |
| `working-directory` | Shell | ◎ | An explicit value skips session restore. Verified: port log 2026-10-17 (F6) and IPC --working-directory (2026-10-15). |
| `keybind` | Keybindings | ◎ | global: uses RegisterHotKey; sequences, multi-action, Shift/AltGr-character and taken combos are rejected with a diagnostic. Verified: port log 2026-10-17 (F7). |
| `key-remap` | Keybindings | ○ | Applied to keybind matching and encoding; text produced by the Windows keyboard layout is not changed. |
| `window-padding-x` | Window | ○ | Applied by the shared core surface sizing; Win32 uses core padding for IME placement and split minimum sizes. |
| `window-padding-y` | Window | ○ | Applied by the shared core surface sizing. |
| `window-padding-balance` | Window | ○ |  |
| `window-padding-color` | Window | ○ |  |
| `window-vsync` | Rendering | ○ | Upstream documents macOS only; the D3D11 renderer presents with sync interval 1 when true and 0 when false. |
| `window-inherit-working-directory` | Working directory | ◎ | Requires OSC 7 from the shell (PowerShell integration is automatic). Verified: roadmap matrix, 1.3.2-windows.11. |
| `tab-inherit-working-directory` | Working directory | ◎ | Requires OSC 7 from the shell. Verified: roadmap matrix, 1.3.2-windows.11. |
| `split-inherit-working-directory` | Working directory | ◎ | Requires OSC 7 from the shell. Verified: roadmap matrix, 1.3.2-windows.11. |
| `window-inherit-font-size` | Window | ✕ | New windows, tabs and splits always start at the configured font-size. |
| `window-decoration` | Window | ○ | none removes the native frame; auto, client and server all use the native Windows frame. |
| `window-title-font-family` | Titlebar | ✕ | The native title bar uses the system font and the tab bar uses Segoe UI. |
| `window-subtitle` | GTK | - | GTK-only subtitle; the Windows title bar has no subtitle. |
| `window-theme` | Titlebar | ◎ | Applies to the native title bar. Verified: port log 2026-10-15 grouped manual check (ghostty, dark, light); system not checked. |
| `window-colorspace` | Rendering | ✕ | display-p3 is ignored on Windows; colors are always interpreted as sRGB. |
| `window-height` | Window | ◎ | Verified: window-state regression checks the startup ConPTY row count (fix 2026-09-15). |
| `window-width` | Window | ◎ | Verified: window-state regression checks the startup size (fix 2026-09-15). |
| `window-position-x` | Window | ✕ | Windows chooses the initial position (CW_USEDEFAULT); session restore can place windows. |
| `window-position-y` | Window | ✕ | Windows chooses the initial position (CW_USEDEFAULT). |
| `window-save-state` | Session | ◎ | Only always enables save/restore; default and never do not persist. Verified: port log 2026-10-17 (F6). |
| `window-step-resize` | Window | ✕ | Windows resizes in pixel increments. |
| `window-new-tab-position` | Tabs/Splits | ○ |  |
| `window-show-tab-bar` | Tabs/Splits | ◎ | auto also shows the bar while a split is zoomed. Verified: automated reload regression (roadmap matrix). |
| `window-titlebar-background` | Titlebar | ○ | Only with window-theme = ghostty, on Windows 11; cleared under high contrast. |
| `window-titlebar-foreground` | Titlebar | ○ | Only with window-theme = ghostty, on Windows 11; also colors tab bar text and split dividers. |
| `drag-handle` | Tabs/Splits | ✕ | Windows has no split drag handles; splits cannot be rearranged by mouse (dividers still resize). |
| `resize-overlay` | Window | ✕ | No resize size overlay on Windows. |
| `resize-overlay-position` | Window | ✕ | No resize size overlay on Windows. |
| `resize-overlay-duration` | Window | ✕ | No resize size overlay on Windows. |
| `focus-follows-mouse` | Mouse | ✕ | Pane focus changes on click only. |
| `clipboard-read` | Clipboard | ○ | ask shows a Windows confirmation dialog. |
| `clipboard-write` | Clipboard | ◎ | ask shows a Windows confirmation dialog. Verified: OSC 52 write with the default (port log 2026-10-17, F5); ask/deny not recorded. |
| `clipboard-write-limit-bytes` | Clipboard | ○ | Applies to Kitty clipboard protocol (OSC 5522) writes. |
| `clipboard-trim-trailing-spaces` | Clipboard | ○ |  |
| `clipboard-paste-protection` | Clipboard | ○ | Unsafe pastes show a Windows confirmation dialog; file drops use the same protection. |
| `clipboard-paste-bracketed-safe` | Clipboard | ○ |  |
| `title-report` | Terminal | ○ |  |
| `image-storage-limit` | Terminal | ○ | Kitty graphics needs the bundled OpenConsole ConPTY host. |
| `copy-on-select` | Selection | △ | primary copies nothing (no selection clipboard on Windows); both copies to the system clipboard only. Default is none. |
| `right-click-action` | Mouse | ◎ | Verified: context-menu (default) on 1.3.2-windows.11 and the 2026-10-15 grouped manual check; other values not recorded. |
| `middle-click-action` | Mouse | △ | The default primary-paste does nothing on Windows (no selection clipboard); use clipboard-paste. |
| `click-repeat-interval` | Mouse | ○ | 0 uses 500 ms, not the Windows double-click time setting. |
| `config-file` | Config | ○ |  |
| `config-default-files` | Config | ◎ | Verified: regression and shell acceptance scripts run isolated processes with --config-default-files=false. |
| `confirm-close-surface` | Lifecycle | ◎ | Windows shows a native close confirmation dialog. Verified: modal-action and native close-confirmation checks (port log 2026-10-14). |
| `quit-after-last-window-closed` | Lifecycle | ◎ | false keeps Ghostty running only while a global keybinding is registered; otherwise it exits. Verified: port log 2026-10-17 (F7). |
| `quit-after-last-window-closed-delay` | Lifecycle | ✕ | Ghostty exits immediately after the last window closes. |
| `initial-window` | Lifecycle | ✕ | Ghostty always opens a window (or restores the session) at startup. |
| `undo-timeout` | Lifecycle | ✕ | Undo/redo of closed panes, tabs or windows is not available on Windows. |
| `quick-terminal-position` | Quick terminal | ◎ | Edge or center of the monitor work area. Verified: port log 2026-10-17 (F7). |
| `quick-terminal-size` | Quick terminal | ◎ | px values are device pixels. Verified: port log 2026-10-17 (F7). |
| `gtk-quick-terminal-layer` | GTK | - | Wayland layer-shell only; ignored on Windows. |
| `gtk-quick-terminal-namespace` | GTK | - | Wayland layer-shell only; ignored on Windows. |
| `quick-terminal-screen` | Quick terminal | ◎ | main is the primary monitor; macos-menu-bar behaves like main. Verified: port log 2026-10-17 (F7, mouse). |
| `quick-terminal-animation-duration` | Quick terminal | ✕ | The quick terminal appears and hides without animation. |
| `quick-terminal-autohide` | Quick terminal | ◎ | Default false on Windows. Verified: port log 2026-10-17 (F7). |
| `quick-terminal-space-behavior` | macOS | - | macOS Spaces only. Switching virtual desktops leaves the quick terminal where it was shown. |
| `quick-terminal-keyboard-interactivity` | Quick terminal | ◎ | exclusive behaves like on-demand. Verified: port log 2026-10-17 (F7, none and on-demand). |
| `shell-integration` | Shell integration | △ | Automatic PowerShell integration reports only the working directory (OSC 7), no prompt marks or OSC 133; Bash integration is bundled. Verified for PowerShell cwd: port log 2026-10-17 (F6). |
| `shell-integration-features` | Shell integration | △ | Exported as GHOSTTY_SHELL_FEATURES and honored by the bundled Bash integration (e.g. ssh-terminfo, ssh-env); the PowerShell integration ignores these features. |
| `command-palette-entry` | Command palette | ◎ | Verified: roadmap F1 (#17) owner real-machine acceptance. |
| `osc-color-report-format` | Terminal | ○ | Handled by the shared core; whether ConPTY passes the related sequences through is not verified. |
| `vt-kam-allowed` | Terminal | ○ | Handled by the shared core; whether ConPTY passes the related sequences through is not verified. |
| `vt-window-resize-allowed` | Terminal | ◎ | Verified: port log resize_window (#45) Debug-build CSI 8 t checks; resize honors work area and maximized state. |
| `vt-xt-checksum-report` | Terminal | ○ | Handled by the shared core; whether ConPTY passes the related sequences through is not verified. |
| `vt-xt-checksum-extension` | Terminal | ○ | Handled by the shared core; whether ConPTY passes the related sequences through is not verified. |
| `custom-shader` | Rendering | ✕ | The D3D11 renderer does not support custom shaders; they are ignored with a log warning (#14). |
| `custom-shader-animation` | Rendering | ✕ | No effect because the D3D11 renderer does not support custom shaders (#14). |
| `bell-features` | Bell | △ | system, attention and title work (verified: port log 2026-10-18, F8); audio and border are not supported. |
| `bell-audio-path` | Bell | ✕ | The audio bell feature is not supported on Windows. |
| `bell-audio-volume` | Bell | ✕ | The audio bell feature is not supported on Windows. |
| `app-notifications` | GTK | - | GTK-only in-app toasts (clipboard-copy, config-reload). |
| `macos-non-native-fullscreen` | macOS | - |  |
| `macos-window-buttons` | macOS | - |  |
| `macos-titlebar-style` | macOS | - |  |
| `macos-titlebar-proxy-icon` | macOS | - |  |
| `macos-dock-drop-behavior` | macOS | - |  |
| `macos-option-as-alt` | macOS | - |  |
| `macos-window-shadow` | macOS | - |  |
| `macos-hidden` | macOS | - |  |
| `macos-auto-secure-input` | macOS | - |  |
| `macos-secure-input-indication` | macOS | - |  |
| `macos-applescript` | macOS | - |  |
| `macos-icon` | macOS | - |  |
| `macos-custom-icon` | macOS | - |  |
| `macos-icon-frame` | macOS | - |  |
| `macos-icon-ghost-color` | macOS | - |  |
| `macos-icon-screen-color` | macOS | - |  |
| `macos-shortcuts` | macOS | - |  |
| `linux-cgroup` | Linux | - |  |
| `linux-cgroup-memory-limit` | Linux | - |  |
| `linux-cgroup-processes-limit` | Linux | - |  |
| `linux-cgroup-hard-fail` | Linux | - |  |
| `gtk-opengl-debug` | GTK | - |  |
| `gtk-single-instance` | GTK | - |  |
| `gtk-titlebar` | GTK | - |  |
| `gtk-tabs-location` | GTK | - |  |
| `gtk-titlebar-hide-when-maximized` | GTK | - |  |
| `gtk-toolbar-style` | GTK | - |  |
| `gtk-titlebar-style` | GTK | - |  |
| `gtk-wide-tabs` | GTK | - |  |
| `gtk-horizontal-tab-scroll` | GTK | - |  |
| `gtk-custom-css` | GTK | - |  |
| `desktop-notifications` | Notifications | ◎ | Windows toast notifications for OSC 9/777; needs the bundled ConPTY. Verified: port log 2026-10-18 (F8). |
| `progress-style` | Taskbar | ◎ | Taskbar progress from OSC 9;4. Verified: roadmap F4 (#33), owner real-taskbar acceptance (port log 2026-10-17). |
| `bold-color` | Colors | ○ |  |
| `faint-opacity` | Colors | ○ |  |
| `term` | Terminal | ◎ | Default TERM=xterm-ghostty with TERMINFO at the install tree. Verified: roadmap 2026-09-15 terminfo fix (tput checks). |
| `enquiry-response` | Terminal | ○ | Handled by the shared core; whether ConPTY passes the related sequences through is not verified. |
| `async-backend` | Linux | - | Linux only (epoll/io_uring). |
| `auto-update` | Updates | - | macOS (Sparkle) only. |
| `auto-update-channel` | Updates | - | macOS (Sparkle) only. |

Legend:

- ◎ Supported on Windows; a runtime check is recorded.
- ○ Supported on Windows, judged from the code; no runtime check is recorded.
- △ Partially supported; the note says what does not work.
- ✕ Not implemented on Windows; the option has no effect.
- \- Not applicable; the option only concerns macOS, GTK, Linux, X11 or
  Wayland.
