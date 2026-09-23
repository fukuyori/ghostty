# Ghostty Native Windows Port (fukuyori/ghostty): Technical Specification and Comparison

### 1. Project Purpose and Overview

[Ghostty](https://ghostty.org/) is a GPU-accelerated terminal emulator written in Zig. At the time of this analysis, native Windows support in the official upstream (`ghostty-org/ghostty`) was still under development.

Upstream has strict policies concerning AI misuse, including issue and pull-request activity. This repository's policy is not to open issues or pull requests upstream.

This project ([`fukuyori/ghostty`](https://github.com/fukuyori/ghostty), `windows` branch) is developed with AI-assisted coding. It builds a native Windows port directly on Win32, Direct3D 11 (D3D11), and DirectComposition, without a third-party GUI framework.

The implementation covers roadmap Phases 1 (basic runtime and IME tracking) through 6 (release scripts). It includes Kitty Graphics Protocol image display through a bundled dedicated ConPTY host, inline Japanese IME candidate positioning, a native Win32 tab bar, mouse-draggable split dividers, dynamic DPI handling across monitors, high contrast, and an Inno Setup installer script (`build-installer.ps1`).

This document compares the repository's structure and code with related ports (`noctty`, `liamsmith86/ghostty-windows`, `zcg/ghostty-win`, and `mattn/ghostty`) and established Windows terminals (Windows Terminal, Alacritty, and WezTerm).

---

### 2. Ghostty's Internal Design and This Fork's Architecture

Ghostty separates shared logic, including VT escape parsing, the terminal grid, and glyph atlases (`src/terminal/` and `src/font/`), from the application-runtime abstraction (`apprt`) that creates windows, renders, and runs OS event loops.

- `src/apprt/embedded.zig`: macOS (AppKit and Metal)
- `src/apprt/gtk.zig`: Linux (GTK4 and Wayland/X11)
- `src/apprt/win32/`: native Windows (Win32 API and Direct3D 11)

This fork organizes the Win32 runtime into modules under `src/apprt/win32/` to follow upstream's architecture and maintain a boundary with the shared core.

#### Windows Text Input and Kitty Keyboard Protocol

In `1.3.2-windows.8`, `handleTextInput()` in `src/apprt/win32/App.zig` records Shift as consumed in producing a `WM_CHAR` character through `consumedTextModifiers()`. Existing AltGr handling marks Ctrl and Alt as consumed; combinations of Shift and AltGr retain both facts.

This lets `src/input/key_encode.zig` send text with no unconsumed modifiers as ordinary UTF-8 in Kitty Keyboard Protocol disambiguation mode. Previously, the missing consumed-Shift flag prevented `:` and `?` input in antigravity.

Reported checks include Shift and AltGr consumption, text output for `:`, `?`, and `A` with consumed Shift, Win32 tests, and a Debug build. On 2026-09-17, the repository owner also confirmed actual `:`, `?`, and `!` input in antigravity.

In `1.3.2-windows.9`, numpad digits and operators (`VK_NUMPAD0` through `VK_DIVIDE`) were added to `isTextVirtualKey()`. Previously, `WM_KEYDOWN` sent a key event producing a digit and the following `WM_CHAR` sent another, so `0` appeared as `00`. The code now defers the key as it does for main-row text keys and sends one key event with its `WM_CHAR`. With NumLock off, the numpad produces navigation virtual keys and is unaffected. Each preview's checks are in the [release notes](windows-release-notes.md).

#### Main Modules

In changes after the 2026-09-22 upstream integration, `SearchBar.zig` manages a modeless search field per pane. The shared core performs search and highlighting; Win32 EDIT/BUTTON controls and `IsDialogMessageW` handle input and focus. Because the D3D11 parent window uses `WS_EX_NOREDIRECTIONBITMAP`, an opaque layered child window provides a GDI drawing target for the field. Layout changes repaint its controls, the field height is subtracted from the pane's terminal area, and tab switching also changes field visibility.

The same changes use `Mouse.zig` to reflect terminal pointer shape and visibility in the system cursor without changing the global `ShowCursor` counter. The ConPTY execution backend sets `resize_pull_scrollback = false`. OSC 7 validates the local host and native drive paths before updating working-directory inheritance; it does not translate WSL/MSYS paths. These changes are separate from distributed `1.3.2-windows.10`. Automated regressions and image checks are recorded in the roadmap; real-machine search-field IME and mixed-DPI checks remained open in this account.

- `App.zig`: Application lifecycle; asynchronous dispatch during modal loops via the message-only `GhosttyWakeup` / `HWND_MESSAGE` window; backoff-based GPU recovery and power-resume handling.
- `Window.zig` / `Surface.zig` / `Tab.zig`: The `Window -> Tab -> Surface/SplitTree` ownership hierarchy.
- `TabBar.zig` and `TabBarAccessibility.zig`: Native Win32 tab bar, drag reordering, wheel switching, double-click inline rename, overflow scrolling, and MSAA accessibility.
- `SplitTree.zig`: Hover and mouse resize for split dividers through a layered `GhosttySplitDivider` window, minimum cell-size constraints, and Split Zoom.
- `DirectComposition.zig`, `Backdrop.zig`, and `GaussianBlur.zig`: Swap-chain composition through a DirectComposition visual tree, background-opacity control, and DWM effects.

The design uses Win32 C-ABI calls and Zig's standard library instead of an additional UI framework such as Electron, WinUI, SDL, or GLFW. This keeps its structure close to upstream for future integrations.

---

### 3. Code-Level Comparison with Other Windows Ports

The following table compares this fork with related community implementations.

#### Port Implementation Matrix

| Area | This fork (`fukuyori/ghostty`) | `noctty` (formerly `winghostty`) | `liamsmith86/ghostty-windows` | `zcg/ghostty-win` | `mattn/ghostty` (reference) |
|---|---|---|---|---|---|
| Rendering API | Direct3D 11 + DirectComposition; some OpenGL compatibility | OpenGL (WGL 4.3+) | OpenGL (WGL) | Direct3D 11 / Direct2D | OpenGL (WGL) |
| Code layout | Functional modules under `src/apprt/win32/` | Separate custom runtime | Extended single `src/apprt/win32.zig` | Custom entry-point integration | Early Win32 prototype |
| ConPTY | Bundled OpenConsole / `conpty.dll` for Kitty images | Bundled OpenConsole plus in-box fallback | In-box `kernel32.dll` ConPTY with asynchronous pipes | In-box `kernel32.dll` ConPTY | In-box `kernel32.dll` ConPTY |
| Tabs and splits | Native Win32 tab bar and draggable dividers | Native tabs/splits and session persistence | Early owner-drawn tab experiment | Basic one-to-many surfaces | Basic single surface |
| IME | Cursor-following `ImmSetCompositionWindow` | `ImmSetCompositionWindow` integration | `ImmAssociateContextEx` integration | DirectWrite integration | Basic text input |
| DPI and accessibility | Dynamic DPI, high contrast, MSAA | Per-monitor DPI, partial UI Automation | Basic DPI | DWM-scale dependent | Basic DPI |
| Packaging | Installer | Installer, portable ZIP, Scoop, WinGet | Manual build, no release | Standalone `ghostty.exe` | Portable ZIP |
| Additional features | D3D11 transparency/backdrop/blur, GPU recovery, tab rename | Palette, config GUI, shell picker, updates | Minimal additions | DirectWrite font experiment | Minimal prototype |

#### Detailed Code Differences

#### 1. Window Creation, Message Loop, and GPU Recovery

- This fork registers `GhosttyWindow`, `GhosttyTabBar`, `GhosttySplitDivider`, and the message-only `GhosttyWakeup` class with `RegisterClassExW`. Alongside normal `WndProc` dispatch to the Ghostty core, `App.zig` runs bounded, backoff-based recovery (`gpu_recovery_max_cycles`) after D3D11 device loss, such as driver failure or resume.
- `noctty` uses an additional queue and dispatcher ahead of `WndProc` for background session management, UI Automation, hotkeys, and external messages.
- The `liamsmith86`, `zcg`, and `mattn` implementations use basic `WndProc` dispatch without the same GPU-loss recovery or modal-loop message buffering described here.

#### 2. ConPTY and Kitty Graphics

- This fork and `noctty` bundle and bind an external OpenConsole host (`conpty.dll` / `OpenConsole.exe`). The analysis found that the in-box `kernel32.dll` ConPTY can strip APC escape sequences used by Kitty Graphics; the external host permits image data to pass through.
- The other compared ports connect directly to the in-box `kernel32.dll` ConPTY. Text I/O works, but those Kitty Graphics sequences can be lost at that layer.

#### 3. Graphics Stack and Shader Pipeline

The 2026-09-22 integration of upstream `bd1c82bc5` followed its move of GPU shader initialization to the render thread. Windows OpenGL still uses WGL: a context created on the main thread is released and acquired on the render thread to draw and swap the window backbuffer. OS conditions separate this from GTK's EGL/DMA-BUF path. D3D11 safely frees uninitialized shaders while retaining render-thread cleanup and GPU recovery.

- This fork uses the native Direct3D 11 renderer (`src/renderer/D3D11.zig`) and DirectComposition. It fixed a vertex-shader z-clipping bug in Kitty image rendering (`ortho2d` yielded z = -1 and hid output). It also has `background-opacity` composition and experimental Backdrop/Gaussian Blur through DirectComposition visuals.
- `noctty` retains upstream's OpenGL/WGL 4.3+ pipeline. Its `background-opacity` works, while `background-blur` was inert in the implementation reviewed.
- `zcg/ghostty-win` experiments with D3D11/D2D and DirectWrite. Its font rendering differs substantially from upstream FreeType/HarfBuzz glyph-cache design, raising integration costs in this analysis.

#### 4. Tabs, Splits, and UI

- This fork integrates a native Win32 tab bar (reordering, wheel switching, double-click rename, overflow controls) and layered, draggable split dividers with core `SplitTree`.
- `noctty` adds session persistence (`session-state.json`), a command palette, shell picker for PowerShell/cmd/Git Bash/WSL, and a config GUI to its native tabs and splits.

#### 5. IME, DPI, and Accessibility

- This fork handles `WM_IME_*`, converts terminal grid-cell positions to pixels, and calls `ImmSetCompositionWindow` with `CFS_POINT` / `CFS_RECT` to position Japanese IME candidates near the cursor. It also handles `WM_DPICHANGED` across monitors, high contrast, and MSAA tab elements through `TabBarAccessibility.zig`.
- `noctty` supports IME and per-monitor DPI and has work on exposing controls through UI Automation.

---

### 4. Comparison with Established Windows Terminals

This table compares the implementations' technical approaches, not measured performance.

#### Product Technology Matrix

| Area | This fork (`fukuyori/ghostty`) | Windows Terminal | Alacritty | WezTerm |
|---|---|---|---|---|
| Language | Zig | C++ / C# (WinRT) | Rust | Rust |
| GUI stack | Win32 API + DirectComposition | WinUI 2 / XAML Islands | winit (Win32 abstraction) | Custom `window` crate |
| Rendering API | Direct3D 11 | Direct3D 11 (DirectWrite/D2D) | OpenGL | WebGPU / OpenGL |
| Font engine | FreeType + HarfBuzz | DirectWrite | Crossfont (DirectWrite) | HarfBuzz + FreeType / DirectWrite |
| Tabs and splits | Native Win32 UI + core SplitTree | XAML tab and split controls | External tools such as tmux | Custom GUI-rendered tabs and splits |
| Configuration | Plain-text `config.ghostty` | JSON and GUI | TOML | Lua |
| Image protocols | Kitty Graphics Protocol | Experimental Sixel | None in this comparison | Sixel, iTerm2, Kitty |
| Runtime footprint | No XAML or embedded scripting layer | XAML/WinRT initialization | Lightweight design | Embedded Lua and other dependencies |

#### Product Details

#### 1. Windows Terminal

- GUI and startup: Windows Terminal uses WinUI/XAML Islands with platform tab and accessibility integration but also XAML initialization and DLL loading. This fork builds D3D11/DirectComposition directly on a Win32 window without XAML. This document does not provide startup benchmarks.
- Images: Windows Terminal uses DirectWrite for text and had limited image-protocol support in the comparison. This fork renders Kitty Graphics through Ghostty's core and GPU renderer.

#### 2. Alacritty

- Design and UI: Alacritty uses winit and focuses on a single surface, leaving tabs and splits to external tools such as tmux. This fork has core SplitTree management and native Windows tab and divider controls.

#### 3. WezTerm

- Runtime and size: WezTerm embeds Lua for scripting and links additional dependencies. This fork calls Win32 through Zig/C-ABI without an embedded scripting engine. No measured binary-size or startup comparison is included here.

---

### 5. Technical Characteristics of This Fork

1. **Upstream integration:** Win32/D3D11-specific logic is organized under `src/apprt/win32/` so upstream changes to core parsing, escape-sequence handling, or Zig versions can be integrated with limited Windows-specific overlap.
2. **Native D3D11 and DirectComposition:** D3D11 rendering and DirectComposition swap-chain composition support `background-opacity` and experimental DWM effects.
3. **Bundled OpenConsole for Kitty Graphics:** The build and packaging path acquires and places OpenConsole/`conpty.dll` to avoid the in-box ConPTY limitation described above.
4. **Windows desktop integration:** Cursor-following Japanese IME candidates, dynamic DPI, high contrast, and MSAA tab accessibility are implemented.
5. **Release tooling:** `scripts/build-release.ps1` builds the release tree; `scripts/build-installer.ps1` creates an Inno Setup installer and supports `signtool.exe` signing.

---

### 6. Completion Status

Roadmap Phases 1-6 are recorded as complete in [`docs/windows-roadmap.md`](windows-roadmap.md). The port is usable, but bugs, improvements, and outstanding real-device checks remain. It is still a preview, not a final stability guarantee.
