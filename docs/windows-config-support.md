# Configuration Support on Windows

This table lists every option in upstream Ghostty's configuration
(`src/config/Config.zig`) with its status in the native Windows build, as of
`1.3.2-windows.16`. Options appear in the same order as in the upstream
reference, and the description summarizes the upstream documentation. See
the [user guide](windows.md) for the configuration file location and
Windows-specific behavior. A Japanese translation is in
[windows-config-support.ja.md](windows-config-support.ja.md).

A ◎ status means a runtime check of the option, or of the feature it
controls, is recorded in the [port log](windows-port-log.md) or the
[roadmap](windows-roadmap.md). A ○ status is based on reading the code: the
code that honors the option runs on Windows, but no runtime check is
recorded. △ and ✕ are also judged from the code.

| Option | Category | Status | Description |
|---|---|---|---|
| `language` | GTK | - | Language of Ghostty's graphical user interface, overriding the system default. |
| `font-family` | Font | ◎ | Font families for regular text; repeat to list fallback fonts for missing characters. |
| `font-family-bold` | Font | ○ | Font families for bold text; falls back to `font-family` when not set or not found. |
| `font-family-italic` | Font | ○ | Font families for italic text; falls back to `font-family` when not set or not found. |
| `font-family-bold-italic` | Font | ○ | Font families for bold italic text; falls back to `font-family` when not set or not found. |
| `font-style` | Font | ○ | Named font style, such as `Heavy`, used for regular text from the chosen font family. |
| `font-style-bold` | Font | ○ | Named font style used for bold text, or `false` to disable bold. |
| `font-style-italic` | Font | ○ | Named font style used for italic text, or `false` to disable italic. |
| `font-style-bold-italic` | Font | ○ | Named font style used for bold italic text, or `false` to disable bold italic. |
| `font-synthetic-style` | Font | ○ | Whether to synthesize bold, italic, and bold italic styles when the font lacks them. |
| `font-feature` | Font | ○ | OpenType font features to enable or disable, such as `-calt` to turn off ligatures. |
| `font-size` | Font | ◎ | Font size in points; fractional values are allowed. |
| `font-variation` | Font | ○ | Variable font axis values, such as `wght=500`, for regular text. |
| `font-variation-bold` | Font | ○ | Variable font axis values for bold text. |
| `font-variation-italic` | Font | ○ | Variable font axis values for italic text. |
| `font-variation-bold-italic` | Font | ○ | Variable font axis values for bold italic text. |
| `font-codepoint-map` | Font | ◎ | Forces specific Unicode codepoints or ranges to render with a named font. |
| `clipboard-codepoint-map` | Clipboard | ○ | Replaces specific Unicode codepoints with other characters or text when copying to the clipboard. |
| `font-thicken` | Font | - | Draws fonts with a thicker stroke where supported. |
| `font-thicken-strength` | Font | - | Strength of thickening, from `0` to `255`, when `font-thicken` is enabled. |
| `font-shaping-break` | Font | ○ | Where to split text into separate shaping runs, such as under the `cursor` to break ligatures. |
| `alpha-blending` | Rendering | ○ | Color space used for alpha blending of text and transparent images. |
| `adjust-cell-width` | Font | ○ | Adjusts the cell width by pixels or a percentage. |
| `adjust-cell-height` | Font | ○ | Adjusts the cell height by pixels or a percentage, keeping the text vertically centered. |
| `adjust-font-baseline` | Font | ○ | Adjusts the distance from the cell bottom to the text baseline. |
| `adjust-underline-position` | Font | ○ | Adjusts the distance from the cell top to the underline. |
| `adjust-underline-thickness` | Font | ○ | Adjusts the thickness of the underline. |
| `adjust-strikethrough-position` | Font | ○ | Adjusts the distance from the cell top to the strikethrough. |
| `adjust-strikethrough-thickness` | Font | ○ | Adjusts the thickness of the strikethrough. |
| `adjust-overline-position` | Font | ○ | Adjusts the distance from the cell top to the overline. |
| `adjust-overline-thickness` | Font | ○ | Adjusts the thickness of the overline. |
| `adjust-cursor-thickness` | Cursor | ○ | Adjusts the thickness of the bar cursor and outlined block cursor. |
| `adjust-cursor-height` | Cursor | ○ | Adjusts the height of the cursor for all cursor styles. |
| `adjust-box-thickness` | Font | ○ | Adjusts the line thickness of box drawing characters. |
| `adjust-icon-height` | Font | ○ | Adjusts the maximum height of Nerd Font icons. |
| `grapheme-width-method` | Terminal | ○ | Method for calculating the cell width of grapheme clusters: `unicode` or `legacy`. |
| `freetype-load-flags` | Font | ○ | FreeType glyph loading flags, such as hinting, autohint, and monochrome rendering. |
| `theme` | Colors | △ | Color theme to load by name or path, optionally with separate themes for light and dark mode. |
| `background` | Colors | ◎ | Background color of the window. |
| `foreground` | Colors | ○ | Foreground (text) color of the window. |
| `background-image` | Background | ○ | Path to a PNG or JPEG image shown as the terminal background. |
| `background-image-opacity` | Background | ○ | Opacity of the background image, relative to `background-opacity`. |
| `background-image-position` | Background | ○ | Where the background image is placed within the terminal, such as `center` or `top-left`. |
| `background-image-fit` | Background | ○ | How the background image is scaled: `contain`, `cover`, `stretch`, or `none`. |
| `background-image-repeat` | Background | ○ | Whether to tile the background image to fill blank space around it. |
| `selection-foreground` | Colors | ○ | Text color of selected text. |
| `selection-background` | Colors | ○ | Background color of selected text. |
| `selection-clear-on-typing` | Selection | ○ | Whether typing or starting IME composition clears the current selection. |
| `selection-clear-on-copy` | Selection | ○ | Whether the selection is cleared after copying with the `copy_to_clipboard` binding. |
| `selection-word-chars` | Selection | ○ | Characters treated as word boundaries when selecting words, such as by double-clicking. |
| `minimum-contrast` | Colors | ○ | Minimum WCAG contrast ratio between text and background colors, from 1 to 21. |
| `palette` | Colors | ○ | Colors of the 256-color terminal palette, set as `N=COLOR` entries. |
| `palette-generate` | Colors | ○ | Whether to generate palette colors 16–255 automatically from the base 16 ANSI colors. |
| `palette-harmonious` | Colors | ○ | Whether to reverse the order of colors generated by `palette-generate` for light/dark compatibility. |
| `cursor-color` | Cursor | ○ | Color of the cursor, or `cell-foreground`/`cell-background` to match the cell. |
| `cursor-opacity` | Cursor | ○ | Opacity of the cursor, from 0 (transparent) to 1 (opaque). |
| `cursor-style` | Cursor | ○ | Default cursor shape: `block`, `bar`, `underline`, or `block_hollow`. |
| `cursor-style-blink` | Cursor | ○ | Default blinking state of the cursor; when unset, DEC mode 12 is also respected. |
| `cursor-text` | Cursor | ○ | Color of the text under the cursor. |
| `cursor-click-to-move` | Cursor | ○ | Whether clicking in prompt text moves the cursor there, using `OSC 133` prompt marking. |
| `mouse-hide-while-typing` | Mouse | ○ | Whether to hide the mouse pointer while typing until the mouse is used again. |
| `scroll-to-bottom` | Terminal | ○ | When to scroll to the bottom: on `keystroke`, on new `output`, or both. |
| `mouse-shift-capture` | Mouse | ○ | Whether Shift with a mouse click is sent to programs or used to extend the selection. |
| `mouse-reporting` | Mouse | ○ | Whether terminal applications may receive mouse events when they request mouse reporting. |
| `mouse-scroll-multiplier` | Mouse | △ | Multiplier for mouse wheel scroll distance, optionally separate for `precision:` and `discrete:` devices. |
| `background-opacity` | Background | ◎ | Opacity of the window background, from 0 (transparent) to 1 (opaque). |
| `background-opacity-cells` | Background | ○ | Whether `background-opacity` also applies to cells with an explicit background color. |
| `background-blur` | Background | △ | Whether and how strongly to blur the background behind a translucent window. |
| `unfocused-split-opacity` | Tabs/Splits | ✕ | Opacity of unfocused splits, used to fade them so the focused split stands out. |
| `unfocused-split-fill` | Tabs/Splits | ✕ | Color of the overlay used to dim unfocused splits. |
| `split-divider-color` | Tabs/Splits | ✕ | Color of the divider between splits. |
| `split-preserve-zoom` | Tabs/Splits | ○ | Which operations keep a zoomed split zoomed, such as `navigation` between splits. |
| `search-foreground` | Colors | ○ | Text color of non-focused search matches. |
| `search-background` | Colors | ○ | Background color of non-focused search matches. |
| `search-selected-foreground` | Colors | ○ | Text color of the currently selected search match. |
| `search-selected-background` | Colors | ○ | Background color of the currently selected search match. |
| `command` | Shell | ◎ | The command, usually a shell, to run in every new terminal surface. |
| `initial-command` | Shell | ○ | Like `command`, but only for the first terminal surface created when Ghostty starts. |
| `notify-on-command-finish` | Notifications | ◎ | When to send a notification after a command finishes: `never`, `unfocused`, or `always`. |
| `notify-on-command-finish-action` | Notifications | ◎ | How command finished notifications are delivered, such as `bell` or `notify`. |
| `notify-on-command-finish-after` | Notifications | ◎ | How long a command must run before its completion triggers a notification. |
| `env` | Shell | ○ | Extra environment variables, as `KEY=VALUE`, passed to commands launched in a terminal surface. |
| `input` | Shell | ○ | Data, given as `raw:` text or a `path:` file, written to the command's input at startup. |
| `wait-after-command` | Shell | ○ | Whether to keep the terminal open after the command exits until a key is pressed. |
| `abnormal-command-exit-runtime` | Shell | ○ | Runtime in milliseconds below which a process exit is treated as abnormal and reported as an error. |
| `scrollback-limit-bytes` | Scrollback | ○ | Maximum size in bytes of the scrollback buffer for each terminal surface. |
| `scrollback-limit-lines` | Scrollback | ◎ | Maximum number of scrollback lines to retain, excluding the active screen. |
| `scrollback-compression` | Scrollback | ○ | Whether to compress scrollback pages in memory while the terminal is idle. |
| `scrollbar` | Scrollback | ◎ | When to show the scrollbar for the scrollback buffer: `system` or `never`. |
| `link` | Links | ✕ | Regular expressions matched against terminal text that make matches clickable with an action; not yet settable. |
| `link-url` | Links | ◎ | Whether URLs are detected and opened with the default application when clicked with a modifier. |
| `link-osc8` | Links | ◎ | Whether hyperlinks created with the OSC 8 escape sequence are enabled. |
| `link-previews` | Links | ✕ | Whether to show link previews for matched URLs: `true`, `false`, or `osc8` only. |
| `maximize` | Window | ◎ | Whether new windows start maximized. |
| `fullscreen` | Window | ◎ | Whether new windows start in fullscreen, including macOS non-native fullscreen modes. |
| `title` | Window | ◎ | A fixed window title that overrides titles set by programs through escape sequences. |
| `class` | GTK | - | The application class: X11 `WM_CLASS` class, Wayland application ID, and DBus name on GTK. |
| `x11-instance-name` | GTK | - | The instance name field of the X11 `WM_CLASS` property on GTK builds. |
| `working-directory` | Shell | ◎ | The directory to change to after starting the command: a path, `home`, or `inherit`. |
| `keybind` | Keybindings | ◎ | Key bindings that map a `trigger` of keys and modifiers to an `action`. |
| `key-remap` | Keybindings | ○ | Remaps modifier keys within Ghostty only, using the format `from=to`. |
| `window-padding-x` | Window | ○ | Horizontal padding between the terminal cells and the left and right window borders. |
| `window-padding-y` | Window | ○ | Vertical padding between the terminal cells and the top and bottom window borders. |
| `window-padding-balance` | Window | ○ | Whether leftover space from uneven cell division is balanced across all four window edges. |
| `window-padding-color` | Window | ○ | Color of the padding area: the `background` color or an extension of the nearest cell's background. |
| `window-vsync` | Rendering | ○ | Whether rendering is synchronized with the screen refresh rate, trading tearing against input latency. |
| `window-inherit-working-directory` | Working directory | ◎ | Whether new windows inherit the working directory of the previously focused window. |
| `tab-inherit-working-directory` | Working directory | ◎ | Whether new tabs inherit the working directory of the previously focused tab. |
| `split-inherit-working-directory` | Working directory | ◎ | Whether new split panes inherit the working directory of the previously focused split. |
| `window-inherit-font-size` | Window | ✕ | Whether new windows and tabs inherit the font size of the previously focused window. |
| `window-decoration` | Window | ○ | Preferred window decorations such as the titlebar and borders, which the OS may override. |
| `window-title-font-family` | Titlebar | ✕ | Font used for the application's window and tab titles. |
| `window-subtitle` | GTK | - | Text shown in the window subtitle, such as the surface's `working-directory`. |
| `window-theme` | Titlebar | ◎ | Theme used for windows: `auto`, `system`, `light`, `dark`, or `ghostty` colors. |
| `window-colorspace` | Rendering | ✕ | Color space used to interpret terminal colors: `srgb` or `display-p3`. |
| `window-height` | Window | ◎ | Initial window height in terminal grid cells; requires `window-width` to also be set. |
| `window-width` | Window | ◎ | Initial window width in terminal grid cells; requires `window-height` to also be set. |
| `window-position-x` | Window | ✕ | Initial horizontal window position in pixels from the primary monitor's top-left; requires `window-position-y`. |
| `window-position-y` | Window | ✕ | Initial vertical window position in pixels from the primary monitor's top-left; requires `window-position-x`. |
| `window-save-state` | Session | ◎ | Whether window state such as position, size, tabs, and splits is saved and restored. |
| `window-step-resize` | Window | ✕ | Whether the window resizes in increments of the focused surface's cell size instead of pixels. |
| `window-new-tab-position` | Tabs/Splits | ○ | Where new tabs are inserted: after the `current` tab or at the `end`. |
| `window-show-tab-bar` | Tabs/Splits | ◎ | When the tab bar is shown, for example `always` or only with two or more tabs. |
| `window-titlebar-background` | Titlebar | ○ | Background color of the window titlebar when `window-theme` is `ghostty`. |
| `window-titlebar-foreground` | Titlebar | ○ | Foreground color of the window titlebar when `window-theme` is `ghostty`. |
| `drag-handle` | Tabs/Splits | ✕ | When drag handles are shown over splits so they can be rearranged with the mouse. |
| `resize-overlay` | Window | ✕ | When the transient overlay showing the terminal size during resizing is displayed. |
| `resize-overlay-position` | Window | ✕ | Position of the resize overlay on the surface, such as `center` or `top-left`. |
| `resize-overlay-duration` | Window | ✕ | How long the resize overlay stays visible before it is hidden. |
| `focus-follows-mouse` | Mouse | ✕ | Whether hovering the mouse over a split pane in the focused window focuses that pane. |
| `clipboard-read` | Clipboard | ○ | Whether programs in the terminal may read the system clipboard via OSC 52: `ask`, `allow`, or `deny`. |
| `clipboard-write` | Clipboard | ◎ | Whether programs in the terminal may write the system clipboard via OSC 52: `ask`, `allow`, or `deny`. |
| `clipboard-write-limit-bytes` | Clipboard | ○ | Maximum size in bytes of a single clipboard write via the Kitty clipboard protocol (OSC 5522). |
| `clipboard-trim-trailing-spaces` | Clipboard | ○ | Whether trailing whitespace is trimmed from text copied to the clipboard. |
| `clipboard-paste-protection` | Clipboard | ○ | Whether confirmation is required before pasting text that appears unsafe, such as text with newlines. |
| `clipboard-paste-bracketed-safe` | Clipboard | ○ | Whether pastes made while the program has bracketed paste mode enabled are considered safe. |
| `title-report` | Terminal | ○ | Whether programs may query the terminal title with title reporting (CSI 21 t). |
| `image-storage-limit` | Terminal | ○ | Maximum bytes of image data, such as Kitty image protocol images, per terminal screen. |
| `copy-on-select` | Selection | △ | Whether selected text is copied automatically, and to which clipboard: `none`, `primary`, `clipboard`, or `both`. |
| `right-click-action` | Mouse | ◎ | Action taken on right-click, such as `context-menu`, `paste`, `copy`, `copy-or-paste`, or `ignore`. |
| `middle-click-action` | Mouse | △ | Action taken on middle-click: `primary-paste`, `clipboard-paste`, or `ignore`. |
| `click-repeat-interval` | Mouse | ○ | Maximum time in milliseconds between clicks for them to count as a double or triple click. |
| `config-file` | Config | ○ | Additional configuration files to load; can be repeated, and a leading `?` ignores missing files. |
| `config-default-files` | Config | ◎ | Whether the default configuration file paths are loaded; settable only on the command line. |
| `confirm-close-surface` | Lifecycle | ◎ | Whether to confirm before closing a surface: `true`, `false`, or `always`. |
| `quit-after-last-window-closed` | Lifecycle | ◎ | Whether the application quits after the last surface is closed. |
| `quit-after-last-window-closed-delay` | Lifecycle | ✕ | How long Ghostty keeps running after the last surface closes, when `quit-after-last-window-closed` is `true`. |
| `initial-window` | Lifecycle | ✕ | Whether an initial window is created when Ghostty starts. |
| `undo-timeout` | Lifecycle | ✕ | How long each undoable operation remains available on the undo stack. |
| `quick-terminal-position` | Quick terminal | ◎ | Screen position of the quick terminal: `top`, `bottom`, `left`, `right`, or `center`. |
| `quick-terminal-size` | Quick terminal | ◎ | Size of the quick terminal as a percentage of the screen or in pixels. |
| `gtk-quick-terminal-layer` | GTK | - | Layer of the quick terminal window, determining which windows it can appear in front of. |
| `gtk-quick-terminal-namespace` | GTK | - | Namespace identifier of the quick terminal window used by the Wayland compositor and scripts. |
| `quick-terminal-screen` | Quick terminal | ◎ | Screen on which the quick terminal appears, such as `main`, `mouse`, or `macos-menu-bar`. |
| `quick-terminal-animation-duration` | Quick terminal | ✕ | Duration in seconds of the quick terminal's show and hide animation; `0` disables it. |
| `quick-terminal-autohide` | Quick terminal | ◎ | Whether the quick terminal hides automatically when focus moves to another window. |
| `quick-terminal-space-behavior` | macOS | - | Whether the quick terminal follows when switching between macOS spaces: `move` or `remain`. |
| `quick-terminal-keyboard-interactivity` | Quick terminal | ◎ | When the quick terminal receives keyboard input, following the Wayland layer-shell keyboard interactivity modes. |
| `shell-integration` | Shell integration | △ | Whether to auto-inject shell integration, and which shell's scheme to use. |
| `shell-integration-features` | Shell integration | △ | Which shell integration features to enable, such as `cursor`, `sudo`, `title`, and SSH helpers. |
| `command-palette-entry` | Command palette | ◎ | Custom entries added to the command palette, each with a title, action, and optional description. |
| `osc-color-report-format` | Terminal | ○ | Format used to reply to OSC 4/10/11 color queries: `16-bit`, `8-bit`, or `none`. |
| `vt-kam-allowed` | Terminal | ○ | Whether programs may use KAM (ANSI mode 2) to disable keyboard input. |
| `vt-window-resize-allowed` | Terminal | ◎ | Whether programs may resize the window with the xterm `CSI 8 ; rows ; columns t` sequence. |
| `vt-xt-checksum-report` | Terminal | ○ | Whether programs may request checksums of screen areas with DECRQCRA. |
| `vt-xt-checksum-extension` | Terminal | ○ | How the DECRQCRA checksum is calculated after a reset, like xterm's `checksumExtension`. |
| `custom-shader` | Rendering | ✕ | Paths to Shadertoy-compatible GLSL shaders run after the default shaders. |
| `custom-shader-animation` | Rendering | ✕ | Whether custom shaders run an animation loop: when focused, `always`, or not at all. |
| `bell-features` | Bell | △ | Which bell effects to use, such as `system`, `audio`, `attention`, `title`, and `border`. |
| `bell-audio-path` | Bell | ✕ | Audio file played for the bell when the `audio` bell feature is enabled. |
| `bell-audio-volume` | Bell | ✕ | Volume, from 0.0 to 1.0, of the bell audio file relative to the system volume. |
| `app-notifications` | GTK | - | Which in-app notifications (toasts) to show, such as `clipboard-copy` and `config-reload`. |
| `macos-non-native-fullscreen` | macOS | - | Whether macOS fullscreen uses a faster non-native mode instead of native fullscreen. |
| `macos-window-buttons` | macOS | - | Whether the macOS titlebar window buttons (traffic lights) are visible. |
| `macos-titlebar-style` | macOS | - | Style of the macOS titlebar: `native`, `transparent`, `tabs`, or `hidden`. |
| `macos-titlebar-proxy-icon` | macOS | - | Whether the macOS titlebar shows the proxy icon for the current working directory. |
| `macos-dock-drop-behavior` | macOS | - | Whether dropping a file on the macOS dock icon opens a new tab or a new window. |
| `macos-option-as-alt` | macOS | - | Whether the macOS Option key is treated as Alt, optionally only the left or right key. |
| `macos-window-shadow` | macOS | - | Whether macOS windows have a shadow. |
| `macos-hidden` | macOS | - | Whether the macOS app is hidden from the dock and app switcher. |
| `macos-auto-secure-input` | macOS | - | Whether macOS Secure Input is enabled automatically when a password prompt is detected. |
| `macos-secure-input-indication` | macOS | - | Whether a graphical indicator is shown while macOS Secure Input is enabled. |
| `macos-applescript` | macOS | - | Whether Ghostty exposes and handles its AppleScript dictionary on macOS. |
| `macos-icon` | macOS | - | Which macOS app icon to show in the dock and app switcher, including custom icons. |
| `macos-custom-icon` | macOS | - | Absolute path to the icon file used when `macos-icon` is `custom`. |
| `macos-icon-frame` | macOS | - | Frame material of the macOS app icon for the `custom-style` icon. |
| `macos-icon-ghost-color` | macOS | - | Color of the ghost in the macOS app icon for the `custom-style` icon. |
| `macos-icon-screen-color` | macOS | - | Gradient colors of the screen in the macOS app icon for the `custom-style` icon. |
| `macos-shortcuts` | macOS | - | Whether macOS Shortcuts may control Ghostty: `ask`, `allow`, or `deny`. |
| `linux-cgroup` | Linux | - | Whether each surface is placed in its own transient `systemd` scope for resource management on Linux. |
| `linux-cgroup-memory-limit` | Linux | - | Soft memory limit, in bytes, for each terminal's cgroup (`MemoryHigh`). |
| `linux-cgroup-processes-limit` | Linux | - | Maximum number of processes for each terminal's cgroup (`TasksMax`). |
| `linux-cgroup-hard-fail` | Linux | - | Whether a failure to create the `systemd` scope makes surface creation fail. |
| `gtk-opengl-debug` | GTK | - | Whether GTK's OpenGL debugging logs are enabled. |
| `gtk-single-instance` | GTK | - | Whether the GTK app runs as a single instance that opens new windows for new launches. |
| `gtk-titlebar` | GTK | - | Whether the full GTK titlebar is shown instead of the window manager's titlebar. |
| `gtk-tabs-location` | GTK | - | Where the GTK tab bar is placed: `top`, `bottom`, or `hidden`. |
| `gtk-titlebar-hide-when-maximized` | GTK | - | Whether the GTK titlebar is hidden while the window is maximized. |
| `gtk-toolbar-style` | GTK | - | Appearance of the GTK top and bottom bars: `flat`, `raised`, or `raised-border`. |
| `gtk-titlebar-style` | GTK | - | Style of the GTK titlebar: `native`, or `tabs` to merge the tab bar into it. |
| `gtk-wide-tabs` | GTK | - | Whether GTK tabs expand to fill the available space. |
| `gtk-horizontal-tab-scroll` | GTK | - | Whether two-finger horizontal touchpad scrolling switches between GTK tabs. |
| `gtk-custom-css` | GTK | - | Custom GTK CSS files to load for styling the application. |
| `desktop-notifications` | Notifications | ◎ | Whether terminal applications can show desktop notifications via sequences such as OSC 9 or OSC 777. |
| `progress-style` | Taskbar | ◎ | Whether terminal applications can show graphical progress bars via the ConEmu OSC 9;4 sequence. |
| `bold-color` | Colors | ○ | Color used for bold text: a specific color, or `bright` to use the bright palette. |
| `faint-opacity` | Colors | ○ | Opacity of faint text, from 0 (transparent) to 1 (opaque). |
| `term` | Terminal | ◎ | Value of the `TERM` environment variable set for the shell. |
| `enquiry-response` | Terminal | ○ | String sent back when the running command sends `ENQ` (`0x05`). |
| `async-backend` | Linux | - | Low-level API used for async IO and eventing on Linux: `auto`, `epoll`, or `io_uring`. |
| `auto-update` | Updates | - | Auto-update behavior on macOS: `off`, `check`, or `download`. |
| `auto-update-channel` | Updates | - | Release channel used for auto-updates: `stable` or `tip`. |

Legend:

- ◎ Supported on Windows; a runtime check is recorded.
- ○ Supported on Windows, judged from the code; no runtime check is recorded.
- △ Partially supported.
- ✕ Not implemented on Windows.
- \- Not applicable; the option only concerns macOS, GTK, Linux, X11 or
  Wayland.
