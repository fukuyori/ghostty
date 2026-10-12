# Windows Port Log

This log records each upstream synchronization into `windows` and the
evidence for port fixes made on `windows`. Only `windows` edits this file;
`gozitty` takes it unchanged through merges (see Section 1.2 of the
[rebranding plan](windows-rebranding-plan.md)). Newest entries come first.

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
on the Windows 11 test machine. The snapped and multi-surface cases were not
checked on screen.

ConPTY applies `CSI 8 t` to its own buffer as well: `[Console]::WindowWidth`
and `WindowHeight` inside the shell reported 100×30 in every case, including
the ones where Ghostty kept its size. When the request is ignored, the
console size the shell sees can therefore differ from Ghostty's grid until
the next resize.

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
