# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

This fork develops the native Windows build of Ghostty on the `windows`
branch. The macOS and Linux apps are not built or tested here; upstream owns
them. Work in this repository targets Win32, D3D11, and the PowerShell
tooling around them.

## Commands

All commands run from the repository root in PowerShell.

- **Build (Debug):** `zig build` → `zig-out\bin\ghostty.exe`
- **Build (Release):** `.\scripts\build-release.ps1` → `zig-out\release`
  - The version comes from `dist\windows\version.txt` in the working tree,
    regardless of commits or tags. The script takes no version and rejects
    `-Dversion-string`.
  - Add `-TestHooks -OutputDirectory zig-out\release-hooks` for a build the
    GPU recovery and power resume checks can drive. Never distribute it.
- **Installer:** `.\scripts\build-installer.ps1 -Sign` → `zig-out\installer`
  - Requires an existing release tree and Inno Setup 6.3 or newer. The
    certificate comes from the `CODESIGN_CERT` environment variable.
  - Fails unless the release executable reports the version in
    `dist\windows\version.txt`.
- **Test (Zig):** `zig build test`
  - Prefer targeted runs with `-Dtest-filter` because the full suite is slow.
  - Win32 tests that exercise the regression hooks need
    `zig build test -Dtest-filter=Win32 -Dwin32-test-hooks=true`.
- **Formatting (Zig):** `zig fmt .`
- **Formatting (other):** `prettier -w .`

When passing a version straight to `zig build` from PowerShell, quote the
argument (`zig build '-Dversion-string=1.3.2-windows.3'`). Without quotes
PowerShell splits the value and the build fails with `error: InvalidVersion`.

## Verification

Building is not enough for a Windows change. `docs/windows-roadmap.md`
section 9 lists the minimum for each kind of change; the scripts below are
the ones it refers to.

- **Window and GUI behavior:** `.\scripts\test-windows-window-state.ps1`
  covers terminal input, IME process keys, the startup grid, config reload,
  splits, click-to-focus between panes, multi-monitor moves, multiple
  windows, maximize/minimize/restore, and a clean exit.
- **GPU recovery and power resume:** add `-TestGpuRecovery` and
  `-TestPowerResume`, and point `-Executable` at a `-TestHooks` build.
- **Endurance:** `.\scripts\test-windows-soak.ps1 -Iterations 20`.
- **Windows shell integration:** `.\scripts\test-windows-shell.ps1` records
  manual Alt+Tab, taskbar, and snap results.
- **Startup diagnostics:** `.\scripts\run-windows-diagnostics.ps1` captures
  stdout, stderr, and the exit code from the GUI subsystem executable.

GUI changes are not complete on a successful build alone; confirm the actual
display or a captured image. Input changes need real key, mouse, and IME
operation. Window lifecycle changes need a check for leftover processes and
the exit code.

## libghostty-vt

- Build: `zig build -Demit-lib-vt`
- Build WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`
- Test: `zig build test-lib-vt -Dtest-filter=<filter>`
  - Prefer this when the change is in a libghostty-vt file
- All C enums in `include/ghostty/vt/` must have a `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE`
  sentinel as the last entry to force int enum sizing (pre-C23 portability).

## Directory Structure

- Shared Zig core: `src/`
- Win32 app runtime: `src/apprt/win32`
- D3D11 renderer: `src/renderer/D3D11.zig` and `src/renderer/d3d11`
- Windows packaging: `dist/windows` (icon, manifest, resource script, and the
  Inno Setup script)
- Windows tooling: `scripts/*.ps1`
- Windows documentation: `docs/windows.md` (user guide),
  `docs/windows-roadmap.md` (implementation status and verification matrix),
  `docs/windows-release-notes.md`, `docs/windows-changelog.md`, and
  `docs/version-update-checklist.md`

Keep changes to shared core files minimal and guarded by
`builtin.os.tag == .windows` or `build_config`, so that upstream merges stay
manageable and other platforms keep their behavior.

## Releases

- The default branch is `windows`. Push to `origin` only; `upstream` and
  `mattn` are configured with pushing disabled.
- Preview versions are `X.Y.Z-windows.N`, where `X.Y.Z` matches the numeric
  part of `build.zig.zon` and `N` is the preview sequence. Tags are
  `vX.Y.Z-windows.N`. The numbering rules and the full checklist are in
  `docs/version-update-checklist.md`.
- Record every release in `docs/windows-release-notes.md` and every change
  between releases in `docs/windows-changelog.md`, then update the state,
  remaining work, and verification matrix in `docs/windows-roadmap.md`.
- Commit, tag, push, and package only when the request says so.

## Issue and PR Guidelines

These rules are about the upstream repository, `ghostty-org/ghostty`:

- Never create an issue upstream.
- Never create a PR upstream.

Issues and pull requests on this fork, `fukuyori/ghostty`, are fine when the
repository owner asks for them.
