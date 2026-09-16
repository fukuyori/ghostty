# Ghostty for Windows Changelog

Every change between the Windows previews of this fork, grouped by kind and
listed with the commit that made it. The
[release notes](windows-release-notes.md) carry the verification results,
known issues, and known limitations of each version; the
[version update checklist](version-update-checklist.md) describes the
`X.Y.Z-windows.N` numbering.

## 1.3.2-windows.3

Released 2026-09-16. A bug-fix preview for `1.3.2-windows.2` that resolves
every known issue of that version. Full range:
[`v1.3.2-windows.2..v1.3.2-windows.3`](https://github.com/fukuyori/ghostty/compare/v1.3.2-windows.2...v1.3.2-windows.3).

### Fixed

- A click no longer leaves keyboard focus on the wrong split pane
  (`a1d619c96`). Surfaces are `WS_CHILD` windows, which never take focus on
  their own, and the mouse handler passed the event to the core without
  calling `SetFocus`. With a single pane the top-level focus handler always
  routed focus to the only surface, so the omission stayed hidden; after a
  split, the pane the split did not focus ignored every keystroke and looked
  unresponsive, while `goto_split` still worked.
- Programs that read a terminfo database resolve `xterm-ghostty`
  (`d61ffd900`). The build skipped compiling the database on Windows and
  installed only the terminfo source, so MSYS2, Git Bash, Cygwin, WSL, and
  remote hosts reported `'xterm-ghostty': unknown terminal type.` The
  database is now compiled with `tic` when it can be found, searching the Git
  for Windows, MSYS2, and Cygwin locations in addition to `PATH`.
- The installer ships the compiled terminfo database (`fa058e342`). It staged
  only `share\terminfo\ghostty.terminfo`, so an installed copy never got the
  database even after the build produced one.

### Changed

- The installer file name drops the build metadata, so a development build no
  longer encodes its commit hash and changes the name on every commit
  (`fa058e342`):
  `1.3.2-windows-+abc1234` becomes `ghostty-1.3.2-windows-x64-setup.exe`,
  while `1.3.2-windows.3` stays `ghostty-1.3.2-windows.3-x64-setup.exe`.
  `-OutputBaseName` overrides the name, and packaging a development build now
  warns that it is not a distributable release.
- The release script reports whether the compiled terminfo database is
  present and warns when it is missing (`d61ffd900`).

### Added

- A regression phase that clicks each split pane in turn and requires
  keyboard focus, measured with `GetGUIThreadInfo`, to follow the click
  (`a1d619c96`).

### Documentation

- A changelog covering every change between preview versions (`b31d7f80d`).
- A "Fonts" section in the user guide: how `font-family` matches family
  names, what happens when it does not, how the automatic fallback picks a
  face on Windows, and which faces are resized.
- A "Crash Reports and Diagnostics" section in the README. The Sentry crash
  reporter is not available on Windows, so the startup diagnostic log takes
  its place.
- `AGENTS.md` rewritten for this fork: Windows commands, the verification
  scripts, the Windows directory layout, release rules, and issue and pull
  request guidance that applies the upstream prohibition to upstream only.
- The README covers only the Windows build. Sections inherited from upstream
  were removed and replaced with a short pointer, including a notice that
  upstream runs a strict contribution process and that this fork, being
  developed with AI assistance, opens nothing upstream.
- Terminfo handling documented for MSYS2, Git Bash, Cygwin, WSL, and SSH.

## 1.3.2-windows.2

Released 2026-09-15. A bug-fix preview for `1.3.2-windows.1` that resolves
every known issue of that version. Full range:
[`v1.3.2-windows.1..v1.3.2-windows.2`](https://github.com/fukuyori/ghostty/compare/v1.3.2-windows.1...v1.3.2-windows.2).

### Fixed

- Keys consumed by an IME no longer reach the terminal (`37aae742f`). While
  composing Japanese text, Enter inserted a newline around the committed text
  and Backspace deleted already committed characters; Tab, the arrow keys, and
  Escape leaked the same way. Windows substitutes `VK_PROCESSKEY` for the
  virtual key of every keystroke an active IME consumes while leaving the
  physical scan code intact, and keys are resolved from the scan code, so
  those messages produced real key presses. `WM_KEYDOWN` and `WM_KEYUP` now
  hand `VK_PROCESSKEY` to `DefWindowProc`. This regressed in `eab11dfd5`,
  where key identification moved to scan codes.
- The startup window size now reaches the terminal (`a2973ab14`). With
  `window-width` and `window-height` set, the terminal grid and the ConPTY
  stayed at the placeholder 800x600 equivalent until the first manual resize,
  leaving the lower part of the window unused. The core requests
  `initial_size` while it is still initializing, and the resulting `WM_SIZE`
  arrived before `core_surface` was set, so nothing forwarded it. The size is
  now synchronized once after the core surface is attached.
- A checkout of a preview tag builds without `-Dversion-string`
  (`a2973ab14`). The build system rejected the tag format outright; it now
  accepts `vX.Y.Z-<pre-release>` tags whose numeric part matches
  `build.zig.zon`.

### Added

- An Inno Setup installer (`e5d034e73`), built by
  `scripts/build-installer.ps1` from `dist/windows/ghostty.iss`. The script
  stages the release tree, reads the version from the executable, compiles the
  installer, and checks that the installer's version resource matches. With
  `-Sign` it signs the executable, the installer, and the uninstaller using
  the certificate named by `CODESIGN_CERT` (`signtool /n`); a subject,
  thumbprint, or PFX file can be given instead.
- The installer offers per-user or machine-wide installation, Start Menu and
  optional desktop shortcuts, an optional `PATH` entry that is removed on
  uninstall, and English and Japanese wizards (`e5d034e73`).
- Two regression phases in `scripts/test-windows-window-state.ps1`: one that
  sends the composition Enter and Backspace and requires the shell output to
  be unchanged (`37aae742f`), and one that starts a dedicated process with the
  tab bar hidden and checks that the ConPTY row count right after start equals
  the configured `window-height` and survives a 1px resize (`a2973ab14`).
  Both fail against the `1.3.2-windows.1` build.
- Unit tests covering the `VK_PROCESSKEY` hazard (`37aae742f`).

### Changed

- The regression script reads marker files through a shared helper, so a
  sharing violation raised while `cmd.exe` still holds a redirected file open
  is treated as "not ready yet" instead of failing the run (`37aae742f`).

### Documentation

- The README and the Windows documentation are in English (`b8f790e63`). The
  Windows section and header links of the README, the user guide, the roadmap,
  the version update checklist, and the release notes were translated;
  structure, code blocks, paths, config keys, commit hashes, dates, and
  version strings are unchanged, and the installer's Japanese wizard messages
  are intentionally kept.
- The README no longer pins a preview version (`1934f8321`). It points at the
  release notes and uses a replaceable version in the build example, and the
  installer command relies on the version read from the release executable.
- The release notes record `1.3.2-windows.2` and mark the known issues of
  `1.3.2-windows.1` as fixed (`640551ea0`).

## 1.3.2-windows.1

Released 2026-09-15. The first Windows preview of this fork, based on the
in-development upstream `1.3.2-dev`. See the
[release notes](windows-release-notes.md) for its contents, verification
results, and known issues.
