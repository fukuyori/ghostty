# Ghostty for Windows Changelog

Every change between the Windows previews of this fork, grouped by kind and
listed with the commit that made it. The
[release notes](windows-release-notes.md) carry the verification results,
known issues, and known limitations of each version; the
[version update checklist](version-update-checklist.md) describes the
`X.Y.Z-windows.N` numbering.

## 1.3.2-windows.10

Windows preview dated 2026-09-19. Resolves `xterm-ghostty` for programs that
read terminfo from a working directory outside the drive Ghostty is installed
on.

### Fixed

- Register the compiled terminfo entry in the running user's
  `%USERPROFILE%\.terminfo\78\xterm-ghostty` at startup. Ghostty points
  `TERMINFO` at its own `share\terminfo`, but the ncurses that Git for Windows
  ships resolves that Windows-style path only from a working directory on the
  drive Ghostty is installed on, so from anywhere else `less`, `tput`, and
  everything else that reads terminfo reported
  `'xterm-ghostty': unknown terminal type.` ncurses searches
  `$HOME/.terminfo` whatever `TERMINFO` holds, which makes the lookup
  drive-independent. An entry already in place is never replaced, so one
  compiled by hand with `tic` survives; the copy goes through a temporary file
  beside the destination and a move that refuses to overwrite, so a second
  Ghostty starting at the same time and one killed mid-write both leave a
  usable state; and a failure only writes to the log. The installer was left
  as it was, because Inno Setup documents that user-level files must not be
  written from an administrative install mode installer and a machine-wide
  install runs as whoever elevated it.
- Cover the empty, occupied, and leftover-temporary-file cases with unit
  tests.

### Documentation

- Correct the terminfo section of the Windows documentation. It said the
  ncurses used by MSYS2 and Git Bash does not accept a Windows-style path in
  `TERMINFO`; measurement shows that it does, from a working directory on the
  install drive, and fails elsewhere. The drive-letter explanation is now
  marked as an unconfirmed hypothesis, and the relationship between Cygwin,
  MSYS2, and Git for Windows is spelled out. Cygwin, a standalone MSYS2, and
  a custom `HOME` are not covered by the registration above and still need the
  one-time `tic`.
- Report the compiled entry as `TerminfoUserEntry` from
  `scripts/build-installer.ps1`, so that a package built without `tic`, which
  has nothing for Ghostty to copy, can be told apart.

## 1.3.2-windows.9

Windows preview dated 2026-09-17. Fixes numpad digits and operators being
entered twice. The repository owner confirmed actual numpad input.

### Fixed

- Treat the numpad digit and operator virtual keys (`VK_NUMPAD0` through
  `VK_DIVIDE`) as text keys. The key press was dispatched to the core, which
  sent the digit, and the `WM_CHAR` that `TranslateMessage` generated for the
  same keystroke sent it again, so `0` arrived as `00`. The key press now
  travels with its `WM_CHAR` as one key event, as the main-row keys do. The
  duplication predates `1.3.2-windows.1`: the `1.3.2-windows.6` and
  `1.3.2-windows.8` builds and a 2026-09-15 build before `1.3.2-windows.1`
  all reproduced it. With NumLock off the numpad reports navigation keys,
  which are unchanged.
- In Kitty keyboard disambiguation mode, a numpad digit now arrives as its
  text alone. Before, both `CSI 57399;129u` and the digit arrived.
- Extend the Win32 text key classification test to cover the numpad keys and
  the navigation keys the numpad reports with NumLock off.

## 1.3.2-windows.8

Windows preview dated 2026-09-17. Fixes Shift character input in
antigravity. The repository owner confirmed successful real input testing;
the Release executable and signed installer were also verified locally.

### Fixed

- Mark Shift as consumed when Win32 `WM_CHAR` produces text, while preserving
  the existing AltGr handling. In Kitty keyboard disambiguation mode, this
  lets characters such as `:` and `?` reach antigravity as text instead of
  being encoded with an unconsumed Shift modifier.
- Add regression tests for consumed Shift, AltGr, and their combination,
  and for plain-text encoding of `:`, `?`, and `A` with consumed Shift.

### Documentation

- Add the [Windows technical specification](windows-technical-spec.md),
  including the Win32 consumed-modifier handling and antigravity verification.
- Document how to rebuild when a running Ghostty locks the output executable.

## 1.3.2-windows.7

Windows preview dated 2026-09-17. Fixes the renderer notification hang in
`1.3.2-windows.6`. Distribution-build, signing, and installer verification
completed, as confirmed by the repository owner.

### Fixed

- Keep Windows IOCP notification state shared when Async handles are copied
  into the terminal IO and stream handler. Previously, those copies could
  accumulate cursor-blink reset messages without waking the renderer. Once
  its 64-message mailbox filled, a focus change blocked the UI indefinitely.
  The Windows adapter owns one stable notification state; other platforms
  continue to use the original libxev interface.
- Add regression coverage for notifications through copied handles before
  and after waiter registration, cross-thread notification, and repeated
  draining of a full mailbox. `test-windows-window-state.ps1
  -TestRendererWakeup` emits 70 spaced output batches, verifies split focus,
  pane closure and subsequent input, and saves a window capture.

## 1.3.2-windows.6

Released 2026-09-16. A preview that adds a right-click context menu to
`1.3.2-windows.5`. Full range:
[`v1.3.2-windows.5..v1.3.2-windows.6`](https://github.com/fukuyori/ghostty/compare/v1.3.2-windows.5...v1.3.2-windows.6).

### Added

- Right-clicking in a terminal opens a context menu (`fd8ec1769`, #4). It
  carries Copy and Paste, Clear and Reset, and the Split, Tab, Window, and
  Config submenus: split up, down, left, and right, close the split, change
  the tab title, open and close a tab or a window, open the configuration in
  the OS editor or in a new window, and reload it. The items follow the GTK
  menu, minus the surface title prompt, the window title prompt, and notify on
  next command finish, which the Windows runtime does not support yet. The
  menu opens when the button is released, as in other Windows applications,
  and only when `right-click-action` is `context-menu`, the default, and the
  program in the terminal is not using the mouse. Right-click still selects
  the word or the blank run under the pointer first, as before. The menu key
  and Shift+F10 still go to the terminal.

### Documentation

- The roadmap no longer says right-click selects nothing; it did select, and
  only the menu was missing (`4ab76b5cd`).


## 1.3.2-windows.5

Released 2026-09-16. A bug-fix preview for `1.3.2-windows.4`: splitting a pane
no longer empties the pane that was split. Full range:
[`v1.3.2-windows.4..v1.3.2-windows.5`](https://github.com/fukuyori/ghostty/compare/v1.3.2-windows.4...v1.3.2-windows.5).

### Fixed

- Splitting a pane no longer empties the pane that was split (`677ccc239`).
  The OpenConsole ConPTY host that `1.3.2-windows.4` introduced clears a line
  by writing spaces across all of it rather than erasing it: one pane received
  62 runs of literal spaces, up to the full 140-column width, and not a single
  erase sequence, where the in-box host sent 57. Reflow counted those spaces as
  content, so narrowing a 140-column pane to 69 columns wrapped every row into
  three: the screen grew from 30 rows to 90, the cursor moved to the top, and
  everything above it went into scrollback. Reflow now drops trailing plain
  spaces that carry no style, hyperlink, or protection, the same way it
  already dropped empty cells. A space with a style is kept, since a
  background colour makes it visible. As a side effect, trailing unstyled
  spaces on a line are not preserved across a reflow.


## 1.3.2-windows.4

Released 2026-09-16. A bug-fix preview for `1.3.2-windows.3`: programs running
in Ghostty can draw images, which they could not do in any earlier version.
Full range:
[`v1.3.2-windows.3..v1.3.2-windows.4`](https://github.com/fukuyori/ghostty/compare/v1.3.2-windows.3...v1.3.2-windows.4).

### Fixed

- Programs can draw images (`1de9481b6`, `c67f70308`). Two unrelated
  faults both had to be fixed before anything appeared, and together they hid
  each other: the escape sequences never arrived, and the images that did
  arrive were never rasterized.
  - The ConPTY in `kernel32.dll` rebuilds a program's output from a text
    screen buffer and drops what it does not model, including APC
    (`ESC _ ... ESC \`) — the envelope the Kitty graphics protocol travels
    in. Measured on Windows 11 26200: that host passes text and OSC but
    discards APC, while the OpenConsole host passes all three, at any
    `CreatePseudoConsole` flags. It is the host, not the flags;
    `PSEUDOCONSOLE_PASSTHROUGH_MODE` is in no Windows SDK header and changed
    nothing. Ghostty now loads a `conpty.dll` sitting next to its own
    executable in preference to the one in `kernel32`, by full path, and
    falls back when it isn't there. Query replies round-trip as a result:
    `ESC [ c` is answered by Ghostty (`ESC [ ?62;22;52 c`) rather than by the
    in-box console host, and `ESC [ 16 t` reports the cell size.
  - The D3D11 image vertex shader passed `z = 1.0` to the projection.
    `ortho2d` negates z, so that landed at clip `z = -1`, and D3D keeps only
    `0 <= z <= w`: every image quad was clipped away before rasterization.
    Nothing reported it — the placement was built, the texture was uploaded
    and ready, and the draw call was issued every frame. The Metal shader has
    always passed `0.0`.

### Added

- `scripts/fetch-conpty.ps1`, which downloads the pinned
  `Microsoft.Windows.Console.ConPTY` package, verifies the package and both
  extracted files against recorded SHA-256 hashes, and writes `conpty.dll`
  and `OpenConsole.exe` into `vendor/conpty` (`1de9481b6`). The binaries are
  fetched rather than committed: Zig's package manager keys the archive
  format off the file extension and refuses `.nupkg`, and Microsoft publishes
  them in no other form. A build without the pair still works, it just cannot
  show images, so a developer build needs no network round trip. The release
  and installer scripts fetch them and refuse to ship without them.

### Changed

- The installer ships `conpty.dll`, `OpenConsole.exe`, and
  `THIRD-PARTY-NOTICES.md` (`1de9481b6`, `aea4d0e5c`). The ConPTY host is
  redistributed under the MIT license, which the notices file carries. Both
  halves are required and must come from the same package version:
  `conpty.dll` on its own silently falls back to the in-box host, which looks
  like no change rather than an error.

### Documentation

- A "When Updating the Bundled ConPTY Host" section in the version update
  checklist, covering the three hashes to change and the pairing requirement
  (`1de9481b6`).

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
