# Windows Port Log

This log records each upstream synchronization into `windows` and the
evidence for port fixes made on `windows`. Only `windows` edits this file;
`gooztty` takes it unchanged through merges (see Section 1.2 of the
[rebranding plan](windows-rebranding-plan.md)). Newest entries come first.

## 2026-10-14: Configuration-action extraction (#12)

- Move configuration reload and update, `config_change`, startup/reload
  diagnostics, configuration editor launch, and scrollbar configuration from
  `App.zig` to `ConfigActions.zig`. App retains configuration ownership and
  dispatches to the module. Window creation, layout, and background-blur
  helpers stay in App and are exposed until their planned extraction.
- Move all four existing diagnostics and editor-command tests unchanged and
  register the module in the Win32 test imports and App's comptime block.
  Comparing the extracted bodies with the pre-extraction working-tree snapshot
  confirmed only module qualification, public entry declarations, and
  indentation changed. The preceding `TabTitles.zig` extraction is retained.
- The restructuring remains in progress; `Recovery.zig` is next.

### Verification

- Debug build: 128/128 steps succeeded
  (`zig-out/logs/config-actions-build.log`). Win32 tests with hooks: 91/91
  steps succeeded, 174 passed and one skipped
  (`zig-out/logs/config-actions-win32-tests.log`).
- Unmodified `scripts/test-windows-window-state.ps1`, using
  `-Executable zig-out/bin/ghostty.exe`: passed, exit code 0, no forced
  termination. Summary: `zig-out/logs/config-actions-window-state.json`.
- The first extended run with `-TestCommandPalette -TestOverlayScrollbar`
  could not measure the bottom scrollbar position. Its saved screenshot
  showed another app covering the test window. A temporary copy,
  `zig-out/test-fixtures/config-actions-split/window-state-topmost.ps1`,
  adjusts the repository-root lookup and makes the dedicated test window
  and measured scrollbars topmost. The checks themselves are unchanged.
  This run passed, including palette reload, scrollbar removal/recreation
  across `never`/`system`, position synchronization, split independence,
  and drag races. Exit code 0, no forced termination. Summary:
  `zig-out/logs/config-actions-window-state-topmost.json`. Palette and
  single/split scrollbar PNGs under
  `zig-out/logs/window-state-20261014-135936-521-82269d57` were inspected.
- Dedicated fixture `zig-out/test-fixtures/config-actions-split/check.ps1`:
  startup and reload diagnostics were displayed and dismissed; a valid
  reload showed no diagnostic. `open_config:new_window` used `VISUAL`
  ahead of an invalid `EDITOR` fallback and passed the exact Japanese,
  space-containing configuration path to a mock editor. The child process
  used an isolated `XDG_CONFIG_HOME` inside the fixture. Summary:
  `zig-out/logs/config-actions-20261014-135906.json`; the startup/reload
  diagnostic and valid-config captures with that prefix were inspected.
  Exit code 0, no forced termination. The OS-associated editor route was
  not exercised. These are controlled checks, not physical input acceptance;
  the planned grouped manual checks remain due.
- Tested executable: `zig-out/bin/ghostty.exe`, Debug working tree based on
  `c4671a659` with both extractions, SHA-256
  `BE26546A1B935C096A424359CFFFED429F8BFAE0EDCA2220B338FFCFBCDF7617`.

## 2026-10-14: Tab-title extraction (#12)

- Move title actions, the tab-title dialog and its constants, focused-window
  title synchronization, and title-change notification from `App.zig` into
  `TabTitles.zig`. App retains forwarding entry points for the surface API;
  action dispatch and tab-bar double-click handling call the module directly.
- Preserve allocation, error handling, dialog results, ownership lookups,
  title precedence, and the order of repaint and accessibility notifications.
  The shared tab-bar helpers remain in App and are exposed for this module
  until their planned extraction. Register the new module in App's comptime
  block and the Win32 test imports. Existing title-model tests remain with
  `Tab.zig`.
- The restructuring is still in progress. `ConfigActions.zig` is the next
  group; the final cross-module and grouped manual checks remain due.

### Verification

- Debug `zig build --summary all`: 128/128 steps succeeded.
- `zig build test -Dtest-filter=Win32 -Dwin32-test-hooks=true --summary all`:
  91/91 steps succeeded; 174 tests passed and one skipped. Log:
  `zig-out/logs/tab-titles-win32-tests.log`.
- `scripts/test-windows-window-state.ps1 -Executable zig-out/bin/ghostty.exe`:
  passed, exit code 0, no forced termination. Summary:
  `zig-out/logs/tab-titles-window-state.json`.
- A dedicated fixture, `zig-out/test-fixtures/tab-titles-split/check.ps1`,
  exercised OSC window titles, `set_tab_title`, override retention across OSC
  updates, clearing an override, the tab-bar double-click dialog, accepting a
  Japanese title, opening the dialog through `prompt_tab_title` and cancelling,
  and title restoration across two tabs. It checked the window title and
  tab-bar accessible name, exited 0, and required no forced termination.
  Final summary: `zig-out/logs/tab-titles-20261014-135111.json`. The `.dialog.png`
  and `.renamed.png` captures with the same prefix were inspected and show
  the Japanese text in the dialog, tab bar, and window title. Input was
  synthetic; this is not physical keyboard/IME acceptance evidence.
- Tested executable: `zig-out/bin/ghostty.exe`, Debug working tree based on
  `c4671a659`, SHA-256
  `E4545914F48BF9D914039D860EB5D2506F71E341B2FE98DD0D9EA9A23CF09C49`.

## 2026-10-12: Debug panic on plain-text URLs (#47)

- **Defect:** `Surface.resolvePathForOpening` joins plain-text link text to
  the pwd and calls `accessAbsolute`. A joined URL contains `:` past the
  drive, NT returns `OBJECT_NAME_INVALID`, and Zig's std panics in Debug.
  Reproduced by automated input and by hand on a Debug build; a ReleaseFast
  build of the same commit opened the URL without a panic.
- **Fix:** shared core, Windows only. `src/os/windows_path.zig` (fork-only)
  adds `isCheckable` (forbidden characters including `:`, components over 255
  UTF-16 units, paths over 32000 units, invalid WTF-8);
  `resolvePathForOpening` returns null for a path it rejects or one that
  stays relative after `resolve`. `src/os/main.zig` exports the module and
  references it in its Windows test block.
- **Review:** Codex found that the first version let a 256-unit component
  (`OBJECT_NAME_INVALID`, checked with an attribute query), a path longer
  than std's 32767-unit buffer (from source), and a drive-relative path on
  another drive through; all three are now rejected. Alternate data streams
  are no longer resolved against the pwd.

### Verification

By hand on the Debug build: the plain-text `http://127.0.0.1:65530/` opened
the browser and the log has no panic; `./notes.txt` printed in a terminal
started in its directory opened in Notepad. Unit tests for valid and invalid
paths pass.

## 2026-10-12: Link opening deadlock (#36)

- **Split commit:** `openUrl`, the OSC 8 link policy and its dialogs, and
  `shellOpen` moved from `App.zig` to `ShellOpen.zig` without behavior
  changes, the second incremental split for #12. Verified with
  `zig build test` and `scripts/test-windows-window-state.ps1`.
- **Reproduction:** a fresh Debug instance showing an OSC 8 link to
  `http://127.0.0.1:9/`; two quick Ctrl+clicks left the window not
  responding, with the process alive at 0.75 s of CPU time. Reproduced by
  automated input and by hand. Two `open_config` calls (OpenWith dialog) did
  not hang in four runs.
- **Root cause:** `cdb -pv` stack of the UI thread: `mouseButtonCallback` →
  `processLinks` (renderer state mutex held) → `openUrl` → `shellOpen` →
  `ShellExecuteW` → USER32 dispatch → `wndProc` → `keyCallback` →
  `modsChanged` → `lockUncancelable` on the same mutex.
- **Fix:** `open_url` queues the request and arms a 50 ms timer on the wakeup
  window; `App.run` drains the queue at the top of its outermost loop, where
  the UI thread holds no core lock, and stops the timer. The policy dialogs
  run there; `ShellExecuteW` runs on a detached worker (COM STA with OLE1DDE
  disabled, no owner window, page allocator, failures logged with a job id
  and `GetLastError`). Queued requests are dropped once `WM_QUIT` is pending.
  Two Codex reviews shaped the design: the first found the same deadlock
  through the `MessageBoxW` dialogs (`WM_KILLFOCUS` → `focusCallback`), the
  second the worker's allocator lifetime at exit, a wakeup consumed by a
  modal loop entered from `GetMessageW`, and opens running after a quit
  request.

### Verification

- By hand on the queue revision: double Ctrl+click on an OSC 8 web link, a
  custom-scheme link with its confirmation dialog, and a `file:` link with
  the blocked dialog; the window stayed responsive and the log showed three
  shell opens without failures.
- By hand on the final revision (drain timer, quit check, worker
  allocator), with the same three links: the web link opened the browser
  twice (shell opens id 1 and 2 in the log), and both dialogs returned to a
  responsive window.
- `zig build test -Dtest-filter=Win32` and
  `scripts/test-windows-window-state.ps1` pass on the final revision.
- Separate finding: Ctrl+clicking a plain-text URL panics a Debug build in
  `Surface.resolvePathForOpening` (`OBJECT_NAME_INVALID` treated as a
  programmer bug by Zig's std).

## 2026-10-12: ConPTY size after `CSI 8 t` (#46)

- **Defect:** the bundled OpenConsole resizes its console for
  `CSI 8 ; rows ; cols t` and passes the sequence on. When Ghostty does not
  resize, the shell keeps the requested size.
- **Investigation:** nudging the window by 1px (grid unchanged) made termio
  resend the same grid with `ResizePseudoConsole`, and the console returned
  to Ghostty's size.
- **Fix:** shared core, Windows only. `Surface.resizeWindow` queues a
  `conpty_resync` IO message on every return; `termio/Thread.zig` coalesces
  it with resizes and, when no resize is pending, resizes only the backend
  to the current grid.

### Verification

Debug build, PowerShell child writing the sequence and reading
`[Console]::WindowWidth`/`WindowHeight` and the buffer size 2.5 s later, no
window nudge:

| Case | Bundled OpenConsole: shell / Ghostty | Inbox conhost: shell |
|---|---|---|
| Disabled, `CSI 8;30;100 t` | 80×24 / 80×24 | 100×30 |
| Allowed, `CSI 8;30;100 t` | 100×30 / 100×30 | 100×30 |
| Allowed, maximized | 250×67 / 250×67 | 100×30 |
| Allowed, `CSI 8;20 t` | 80×20 / 80×20 | 80×24 |
| Allowed, `CSI 8;200;400 t` | 249×66 / 249×66 (work area) | 400×200 |

With the inbox conhost the sequence did not reach Ghostty (no
`resize_window` in the log, three of three disabled runs), so nothing
triggers a resync. In the earlier #45 measurement a `resize_window` was
logged for the inbox host only after the window nudge; where it came from
was not determined. Releases ship OpenConsole, so the inbox host is used only
when `conpty.dll` and `OpenConsole.exe` are missing.

`zig build test` and `scripts/test-windows-window-state.ps1` pass. Real TUIs
and Vim were not checked.

## 2026-10-12: `resize_window` on Win32 (#45)

- **Split commit:** window state handling (maximize, fullscreen, decorations,
  always-on-top, sizing) moved from `App.zig` to `WindowState.zig` without
  behavior changes, the first incremental split for
  [#12](https://github.com/fukuyori/ghostty/issues/12). Verified with
  `zig build test` (exit 0) and `scripts/test-windows-window-state.ps1`.
- **Change:** `WindowState.resizeWindow` handles `.resize_window`. It resizes
  the window by the difference between the requested size and the surface's
  current size in device pixels and keeps the position. Only the requested
  dimensions are limited to the monitor's work area; an omitted or zero
  dimension keeps its size even when it exceeds the work area. It ignores the
  request while the window is maximized, minimized, fullscreen, or snapped,
  and when the window has more than one surface.
- **Snap detection:** `IsWindowArranged` is looked up in `user32.dll` at run
  time, because not every supported Windows 10 release exports it. Without
  it, a window whose size differs from the restore size in
  `GetWindowPlacement` is treated as snapped; that fallback misses a window
  snapped into a zone of exactly its restore size.
- **Review:** a Codex review found that the first version compared sizes
  only, missing a window snapped into a zone of its restore size, and limited
  both dimensions to the work area, shrinking an omitted dimension. Both were
  fixed before push.

### Verification

Debug build, cells 10×21 px, padding 2 px, starting at 80×24 (804×508 px):

| Case | Surface after the request |
|---|---|
| `vt-window-resize-allowed = true`, `CSI 8;30;100 t` | 1004×634 px = 100×30 |
| Default config, `CSI 8;30;100 t` | Unchanged; core logs that the request is disabled |
| Allowed, `CSI 8;20 t` | 804×424 px = 80×20, width kept |
| Allowed, started maximized | Unchanged, still maximized |
| Allowed, window widened to 3000 px (work area 2512 px), `CSI 8;20 t` | 2984×424 px: width kept, 20 rows |

`zig build test -Dtest-filter=Win32` and
`scripts/test-windows-window-state.ps1` pass. `IsWindowArranged` resolves
on the Windows 11 test machine.

Checked by hand on 2026-10-12 at `4985657fb` (Debug build, with the #46 resync
in place), alternating `CSI 8;30;100 t` and `CSI 8;24;80 t`: a single window
resized; a window snapped with Win+Left kept its snapped size; with two tabs
and with a split (made from the context menu) the window kept its size; after
closing the extra tab or pane the window resized again. Every request queued
one ConPTY resync.

ConPTY applies `CSI 8 t` to its own buffer as well: `[Console]::WindowWidth`
and `WindowHeight` inside the shell reported 100×30 in every case, including
the ones where Ghostty kept its size. When the request is ignored, the
console size the shell sees can therefore differ from Ghostty's grid until
the next resize. Tracked as
[#46](https://github.com/fukuyori/ghostty/issues/46).

## 2026-10-12: Upstream synchronization (rebranding plan Phase 0)

- **Branch:** `sync/upstream-20261012`, merged into `windows`.
- **Upstream range:** `bd1c82bc5` (2026-09-22) to `6d53bafb1` (2026-10-11),
  238 commits. `main` was fast-forwarded to `6d53bafb1`.
- **Toolchain:** Zig 0.16.0.

### Conflicts and resolutions

Upstream moved the renderer to an app-scoped `renderer.Device`, initialized
once in the core `App`, and removed the WebGL renderer.

- `src/renderer.zig`: dropped the WebGL import, kept `D3D11`, and selects
  `GraphicsAPI` from `opengl`, `metal`, and `d3d11`. `renderer.Device` is
  `GraphicsAPI.Device`.
- `src/renderer/backend.zig`: the backend enum is `opengl`, `metal`, and
  `d3d11`; Windows still defaults to `d3d11`.
- `src/renderer/D3D11.zig` and new `src/renderer/d3d11/Device.zig`: D3D11
  gets a stateless `Device` that only satisfies the interface. Each surface
  still creates its own D3D11 device and DirectComposition presenter, so
  device-loss recovery is unchanged. Sharing one D3D11 device across
  surfaces is left for a separate change.
- `src/renderer/opengl/Device.zig`: on Windows `init` leaves the device
  undefined, because Win32 uses one WGL context per surface and no EGL
  display.
- `src/renderer/OpenGL.zig`: takes the device pointer; the Windows branches
  of `init`, `deinit`, `threadEnter`, and `threadExit` never read the EGL
  fields. `present` takes upstream's new presentation-health argument and
  keeps the Windows blit path.
- `src/renderer/opengl/Frame.zig`: the Windows present call passes the
  renderer's presentation health.
- `.github/VOUCHED.td` and the flatpak, release-tag, release-tip, snap, and
  `test.yml` workflows remain deleted, as on `windows` before the merge.

The fork's ConPTY shutdown and resize handling, DEC private mode 9001,
`PageList` trailing-blank handling, and render health notifications are
preserved.

### Verification

| Check | Result |
|---|---|
| `zig build` (Debug, D3D11) | Pass; `+version` runs |
| `zig build -Drenderer=opengl` | Pass |
| `zig fmt --check`, `git diff --check` | Pass |
| `zig build test` | Pass: 4023 passed, 62 skipped, 0 failed. The runner prints "failed command" because the upstream `TerminalFormatter` benchmark test writes to stderr; the test itself passes |
| `scripts/test-windows-window-state.ps1` | Pass: input, IME process keys, initial grid, splits and click focus, config reload, four monitors, multiple windows, maximize/minimize/restore; exit code 0, no forced termination, no leftover process |
| Codex CLI review of the merge | No regression found; one upstream feature gap (below) |

### Upstream features not yet handled on Win32

- `resize_window` (`CSI 8 ; rows ; cols t`, upstream `714fe9b90`,
  `219cca932`, `3175f6733`, `211149dbc`): the Win32 `performAction` does not
  handle it, so the request is ignored. It is gated by
  `vt-window-resize-allowed`, which defaults to `false`, so default behavior
  is unchanged. To be implemented on `windows`
  ([#45](https://github.com/fukuyori/ghostty/issues/45)).
