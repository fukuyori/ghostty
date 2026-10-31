# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

This fork develops the native Windows build of Ghostty. This copy of the
guide belongs to the `windows` branch, which keeps the Windows port in step
with upstream. The product rename to Gooztty, its own features and all
releases live on `gooztty`, which is the default branch and has its own copy
of this guide. The macOS and Linux apps are not built or tested here;
upstream owns them. Work in this repository targets Win32, D3D11, and the
PowerShell tooling around them.

## Branch Responsibilities

- `main` mirrors upstream without fork-specific changes.
- `windows` owns upstream synchronization, Windows support for upstream
  Ghostty features (including F4-F8), port fixes, and the infrastructure and
  tests needed for that support. This continues after `gooztty` is created.
- `gooztty` owns the product rename and features or behavior extensions not
  provided by upstream Ghostty. A feature being new to Windows does not make
  it Gooztty-specific. Windows-specific code implementing upstream behavior
  belongs on `windows`.
- Classify changes by purpose, not implementation date or file location.
  Split mixed work into a Windows-support change and a Gooztty-specific
  change. Resolve unclear scope before implementation.
- Changes flow upstream → `main` → `windows` → `gooztty`. Fix port defects
  on `windows` first, including those found while running Gooztty. Fix rename
  and Gooztty-specific defects on `gooztty`; never merge it into `windows`.
- `gooztty` was created from `windows` at `842825597` on 2026-10-25. The
  name indirection (`src/brand.zig`, `brand.json`, the build-time rewrites)
  stays on `windows` with the Ghostty values; only `gooztty` changes them.
- Commit directly to the branch that owns the change. Pull requests are not
  used, and the repository limits their creation to collaborators. Before
  committing, check with `git status -sb` that the current branch matches
  the purpose of the change.
- On `windows`, record synchronization results, Windows-support
  implementations, design decisions and verification evidence only in
  `docs/windows-port-log.md`. The README, the other `docs/windows*.md`
  files, release notes, changelog, roadmap and
  `docs/version-update-checklist.md` are maintained on `gooztty`; do not
  edit them on `windows`. When `windows` is merged into `gooztty`, those
  documents are updated there.

See `docs/windows-rebranding-plan.md` Section 1.2 for the full boundary and
`docs/windows-roadmap.md` Section 7 for the schedule.

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
- **IME placement:** `.\scripts\verify-windows-ime.ps1` builds/tests both
  normal and hook variants, runs placement/lifecycle and window regressions,
  and records source state, commands, hashes and exit codes. The controlled
  check is `.\scripts\test-windows-ime-position.ps1` on a hook build.
  Use `.\scripts\test-windows-ime.ps1` separately for physical Japanese IME
  partial commit and focus-resume checks; automated placement readback does
  not establish visual behavior. Never distribute the hook build.

GUI changes are not complete on a successful build alone; confirm the actual
display or a captured image. Input changes need real key, mouse, and IME
operation. Window lifecycle changes need a check for leftover processes and
the exit code.

## libghostty-vt

- Build: `zig build -Demit-lib-vt`
- Build WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=small`
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
- Windows development record edited on `windows`: `docs/windows-port-log.md`
  (synchronization, implementation decisions and verification evidence)
- Documentation maintained on `gooztty` and read-only here:
  `docs/windows.md` (user guide), `docs/windows-roadmap.md` (implementation
  status and verification matrix), `docs/windows-release-notes.md`,
  `docs/windows-changelog.md`, `docs/version-update-checklist.md`,
  `docs/windows-upstream-feature-plan.md` (feature scope and acceptance), and
  `docs/windows-rebranding-plan.md` (branch responsibilities and rename plan)

Keep changes to shared core files minimal and guarded by
`builtin.os.tag == .windows` or `build_config`, so that upstream merges stay
manageable and other platforms keep their behavior.

## Releases

- `windows` publishes nothing: no version change, tag, release or
  installer. Releases are built from `gooztty`. `dist\windows\version.txt`
  stays as it was at the cutover; the release and installer scripts remain
  usable here for verification builds only.
- The default branch is `gooztty`. Push to `origin` only; `upstream` and
  `mattn` are configured with pushing disabled.
- Existing `vX.Y.Z-windows.N` tags record releases under the Ghostty name.
- Commit and push only when the request says so.

## Issue and PR Guidelines

These rules are about the upstream repository, `ghostty-org/ghostty`:

- Never create an issue upstream.
- Never create a PR upstream.

Issues on this fork, `fukuyori/ghostty`, are fine when the repository owner
asks for them. The fork does not use pull requests.
