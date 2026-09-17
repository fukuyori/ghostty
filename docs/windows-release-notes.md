# Ghostty for Windows Release Notes

This is the release history of the Windows previews. See the
[Changelog](windows-changelog.md) for the full list of changes between
versions with their commits, the
[Version Update Checklist](version-update-checklist.md) for the version
numbering rules, the [User Guide](windows.md) for configuration and known
limitations, and the [Roadmap](windows-roadmap.md) for implementation status.

## 1.3.2-windows.9

- Prepared: 2026-09-17
- Source tag: `v1.3.2-windows.9` (not created yet)
- Base version: upstream Ghostty 1.3.2 series (the in-development `1.3.2-dev`)
- Status: preview. Numpad digits and operators are no longer entered twice.
  Actual numpad input confirmed by the repository owner. The signed installer
  was built and installed by the repository owner on 2026-09-17.

### Changes Since 1.3.2-windows.8

- Fix numpad digits and operators being entered twice (`0` arrived as
  `00`). The Win32 runtime dispatched the numpad key press to the core and
  then also sent the `WM_CHAR` text for the same keystroke; the numpad virtual
  keys are now text keys, so the two travel as one key event. The duplication
  predates `1.3.2-windows.1`.
- In Kitty keyboard disambiguation mode, a numpad digit arrives as its text
  alone instead of both `CSI 57399;129u` and the digit.
- Extend the Win32 text key classification test to the numpad keys.

### Verification

Before the version bump, on a Debug build of the fix, 2026-09-17:

| Item | Result |
|---|---|
| `zig build test -Dtest-filter="classify Win32 text keys"` | Passed |
| `zig build test -Dtest-filter=Win32 -Dwin32-test-hooks=true` | 145 passed, 1 skipped, 0 failed |
| Numpad `0`, `1`, `.`, `+` posted to a surface, bytes recorded by a program in the terminal | Each arrives once in normal, Kitty disambiguation, and application keypad modes. The `1.3.2-windows.8` release, `1.3.2-windows.6`, and a 2026-09-15 build all sent `00`, `11`, `..`, `++` |
| Shift input from `1.3.2-windows.8` (`:`, `?`, `A`; Shift+Enter) | Unchanged: text, and `CSI 13;130u` for Shift+Enter |
| Window-state regression | All items passed, exit code 0, no forced termination |
| Actual numpad input | Confirmed by the repository owner |

On the ReleaseFast, baseline CPU executable after the version bump,
2026-09-17:

| Item | Result |
|---|---|
| Release build script checks (PE32+, x64, WindowsGui, version information, icon, resources, compiled terminfo) | Passed. `FileVersion` and `ProductVersion` 1.3.2-windows.9, numeric version 1.3.2.9, `IsDebug` False, `bin\conpty.dll` and `bin\OpenConsole.exe` present |
| `--version`, `+list-keybinds --default` | Exit code 0; `--version` reports `Ghostty 1.3.2-windows.9` and `ReleaseFast` |
| Numpad and Shift input | Numpad `0`, `1`, `.`, `+` arrive once in normal and Kitty disambiguation modes; `:`, `?`, `A` arrive as text |
| Window-state regression on the distribution build (terminal input, IME process keys, split pane click focus, startup grid, config reload, splits, 4 monitors, multiple windows, maximize/minimize/restore, clean exit) | All items passed, exit code 0, no forced termination |
| The same regression plus GPU resource re-creation (2 controlled failures) and power resume on the test-hook build | All items passed. Resources re-created, renderers recovered on all 3 surfaces, terminal sessions preserved, duplicate resume suppressed |
| 20-iteration soak test on the test-hook build (including GPU re-creation and controlled power resume) | All 20 passed, 0 failures, 135.4 seconds elapsed |

The executables used for the checks above are unsigned builds.

Distribution on 2026-09-17:

| Item | Result |
|---|---|
| Signed installer | Built by the repository owner with `scripts/build-installer.ps1 -Sign`. `ghostty-1.3.2-windows.9-x64-setup.exe` and the staged `bin\ghostty.exe` report 1.3.2-windows.9, numeric version 1.3.2.9, `IsDebug` False; Authenticode status checked locally: Valid |
| Installation | Performed by the repository owner. The installed `bin\ghostty.exe` reports 1.3.2-windows.9 with a Valid signature, and the installed tree carries `bin\conpty.dll`, `bin\OpenConsole.exe` (1.24.260710001, Valid Microsoft signatures), and `THIRD-PARTY-NOTICES.md` |

Uninstall is not recorded for this version.

### Building This Version

The release script reads `dist/windows/version.txt` from the working tree:

```powershell
./scripts/build-release.ps1
./zig-out/release/bin/ghostty.exe --version
```

The target version is `1.3.2-windows.9`, with numeric version `1.3.2.9`.
Use `./scripts/build-installer.ps1 -Sign` for the signed installer.

### Known Limitations

The existing limitations of `1.3.2-windows.8` still apply.

## 1.3.2-windows.8

- Prepared: 2026-09-17
- Source tag: `v1.3.2-windows.8`
- Base version: upstream Ghostty 1.3.2 series (the in-development `1.3.2-dev`)
- Status: preview. Input fix verified, including actual use in antigravity,
  as reported and confirmed by the repository owner. Release executable and
  signed installer verified locally on 2026-09-17.

### Changes Since 1.3.2-windows.7

- Fix Shift character input in antigravity by marking Shift as consumed in
  Win32 `WM_CHAR` text events. The Kitty keyboard encoder can then send the
  generated text in disambiguation mode. Existing AltGr consumption remains.
- Add tests for consumed Shift and AltGr modifiers and for plain-text
  encoding of `:`, `?`, and `A` with consumed Shift.

### Verification

The following results were reported by the repository owner for the input
fix before this version bump on 2026-09-17:

| Item | Result |
|---|---|
| `zig build test -Dtest-filter="consumed text modifiers"` | Passed |
| `zig build test -Dtest-filter="plain text with consumed shift"` | Passed |
| `zig build test -Dtest-filter=Win32 -Dwin32-test-hooks=true` | Passed |
| `zig build` | Succeeded |
| Actual Shift character input in antigravity (`:`, `?`, `!`) | Passed; confirmed by the repository owner |

Subsequent local artifact checks on 2026-09-17 confirmed:

- The distribution executable reports `Ghostty 1.3.2-windows.8` and
  `ReleaseFast` through `--version`.
- The release executable, staged distribution executable, and installer
  report `1.3.2-windows.8` with `IsDebug` set to `False`.
- Authenticode signatures on the staged executable and
  `ghostty-1.3.2-windows.8-x64-setup.exe` are `Valid`.

These artifact checks do not record a new install/upgrade/uninstall run.

### Building This Version

The release script reads `dist/windows/version.txt` from the working tree:

```powershell
./scripts/build-release.ps1
./zig-out/release/bin/ghostty.exe --version
```

The target version is `1.3.2-windows.8`, with numeric version `1.3.2.8`.
Use `./scripts/build-installer.ps1 -Sign` for the signed installer.

### Known Limitations

The existing limitations of `1.3.2-windows.7` still apply.

## 1.3.2-windows.7

- Prepared: 2026-09-17
- Source tag: `v1.3.2-windows.7`
- Base version: upstream Ghostty 1.3.2 series (the in-development `1.3.2-dev`)
- Status: preview. Distribution build, signing, and installer verification
  completed; confirmed by the repository owner on 2026-09-17.

### Changes Since 1.3.2-windows.6

- Fix an unresponsive window after terminal output fills the renderer's
  64-message mailbox. Windows IOCP Async handles now share their notification
  state across copies, so terminal IO can wake the renderer and let it drain
  the queue before a focus change needs more space.
- Add unit coverage and the optional `-TestRendererWakeup` window regression,
  which emits 70 spaced output batches and checks split focus, pane closure,
  subsequent input, and a captured window image.

### Verification

Automated fix verification used a separate Debug build with test hooks on
2026-09-17, before the version bump. The repository owner subsequently
confirmed completion of distribution-build, signing, and installer
verification for `1.3.2-windows.7`. These are recorded separately below.

| Item | Result |
|---|---|
| Regression on the previous Release executable | Reproduced the focus hang after 70 spaced output batches |
| Same regression on the fixed Debug executable | Passed; output through batch 70 and subsequent input visually checked in the capture |
| Win32 unit tests with test hooks | 144 passed, 1 skipped, 0 failed |
| Window-state checks, controlled GPU recreation and power-resume notifications | Passed; 4 monitors, recovery on all 3 surfaces, terminal sessions preserved, exit code 0, no forced termination |
| 20 ordinary window regression iterations | 20 passed, 0 failed, 102.153 seconds; clean exits and no remaining test processes |
| Distribution build and installer verification | Completed; confirmed by the repository owner on 2026-09-17 |
| Distribution version metadata | Release executable and installer report 1.3.2-windows.7, numeric version 1.3.2.7, and IsDebug False |
| Signing | Completed; confirmed by the repository owner. Authenticode status of the staged executable and installer also checked locally: Valid. The original release-tree executable remains unsigned, as the installer script signs its staged copy |

### Building This Version

The release script reads `dist/windows/version.txt` from the working tree:

```powershell
./scripts/build-release.ps1
./zig-out/release/bin/ghostty.exe --version
```

The version is `1.3.2-windows.7`, with numeric version `1.3.2.7`.
Use `./scripts/build-installer.ps1 -Sign` to sign the staged distribution
executable and build the signed installer. Test-hook builds must not be
distributed.

### Known Limitations

The existing limitations of `1.3.2-windows.6` still apply. Real GPU device
loss, physical sleep/resume, and several-hour endurance testing remain
separate verification items. There is no automatic update.

## 1.3.2-windows.6

- Release date: 2026-09-16
- Tag: `v1.3.2-windows.6`
- Base version: upstream Ghostty 1.3.2 series (the in-development `1.3.2-dev`)
- Status: preview. Adds a right-click context menu to `1.3.2-windows.5`.
- Distribution format: the portable executable and resources generated by
  `scripts/build-release.ps1`, including `bin\conpty.dll` and
  `bin\OpenConsole.exe`, and an installer built from that release tree with
  `scripts/build-installer.ps1`. There is no automatic update.

### Reproducing This Version

```powershell
git checkout v1.3.2-windows.6
./scripts/build-release.ps1 -AdditionalZigArgs '-Dversion-string=1.3.2-windows.6'
./zig-out/release/bin/ghostty.exe --version
```

`--version` and the `FileVersion` file property are `1.3.2-windows.6`, and the
numeric version is `1.3.2.6`. To verify GPU recovery and power resume with the
regression script, use a separate build with `-TestHooks`. Do not include it in
the distribution.

### Changes Since 1.3.2-windows.5

The [changelog](windows-changelog.md) lists these with their commits.

- Right-clicking in a terminal opens a context menu with Copy, Paste, Clear,
  Reset, and the Split, Tab, Window, and Config submenus. It does not open
  while the program in the terminal is using the mouse, and the menu key and
  Shift+F10 still go to the terminal.

### Verification

Verified on 2026-09-16 on Windows 11 Pro (10.0.26200, four monitors) against
the ReleaseFast, baseline CPU executable.

| Item | Result |
|---|---|
| Release build script checks (PE32+, x64, WindowsGui, version information, icon, resources, compiled terminfo) | Passed. `FileVersion` and `ProductVersion` 1.3.2-windows.6, numeric version 1.3.2.6, `IsDebug` False, `bin\conpty.dll` and `bin\OpenConsole.exe` present |
| `--version`, `+list-keybinds --default` | Exit code 0 |
| Window-state regression on the distribution build (terminal input, IME process keys, split pane click focus, startup grid, config reload, splits, 4 monitors, multiple windows, maximize/minimize/restore, clean exit) | All items passed, exit code 0, no forced termination |
| The same regression plus GPU resource re-creation (2 controlled failures) and power resume on the test-hook build | All items passed. Resources re-created, renderers recovered on all 3 surfaces, terminal sessions preserved, duplicate resume suppressed |
| 20-iteration soak test (including GPU re-creation and controlled power resume) | All 20 passed, 0 failures, 131.4 seconds elapsed |
| Unit tests | 3838 of 3900 passed, 62 skipped, 0 failed |
| Context menu | A posted right-click opens the menu, Escape closes it, and Split then Split Right takes the window from 1 pane to 2. With mouse reporting turned on in the shell, a right-click opens no menu |
| Context menu with a real mouse | Confirmed on real hardware |
| Installer | `scripts/build-installer.ps1` confirmed on real hardware |

The executables used for the automated checks above were unsigned builds.

### Known Limitations

Unchanged from `1.3.2-windows.1`; see that section below. The context menu
does not offer the surface title prompt, the window title prompt, or notify on
next command finish.


## 1.3.2-windows.5

- Release date: 2026-09-16
- Tag: `v1.3.2-windows.5`
- Base version: upstream Ghostty 1.3.2 series (the in-development `1.3.2-dev`)
- Status: preview. A bug-fix release for `1.3.2-windows.4`; splitting a pane
  no longer empties the pane that was split.
- Distribution format: the portable executable and resources generated by
  `scripts/build-release.ps1`, including `bin\conpty.dll` and
  `bin\OpenConsole.exe`, and an installer built from that release tree with
  `scripts/build-installer.ps1`. There is no automatic update.

### Reproducing This Version

```powershell
git checkout v1.3.2-windows.5
./scripts/build-release.ps1 -AdditionalZigArgs '-Dversion-string=1.3.2-windows.5'
./zig-out/release/bin/ghostty.exe --version
```

`--version` and the `FileVersion` file property are `1.3.2-windows.5`, and the
numeric version is `1.3.2.5`. To verify GPU recovery and power resume with the
regression script, use a separate build with `-TestHooks`. Do not include it in
the distribution.

### Changes Since 1.3.2-windows.4

The [changelog](windows-changelog.md) lists these with their commits.

- Splitting a pane no longer empties the pane that was split. The ConPTY host
  introduced in `1.3.2-windows.4` clears lines by writing spaces, and reflow
  wrapped those spaces into extra rows when the pane narrowed, pushing its
  contents into scrollback.

### Verification

Verified on 2026-09-16 on Windows 11 Pro (10.0.26200, four monitors: three at
96 DPI and one at 120 DPI) against the ReleaseFast, baseline CPU executable.

| Item | Result |
|---|---|
| Release build script checks (PE32+, x64, WindowsGui, version information, icon, resources) | Passed. `FileVersion` and `ProductVersion` 1.3.2-windows.5, numeric version 1.3.2.5, `IsDebug` False |
| `--version`, `+list-keybinds --default` | Exit code 0 |
| Window-state regression on the distribution build (terminal input, IME process keys, split pane click focus, startup grid, config reload, splits, 4 monitors, multiple windows, maximize/minimize/restore, clean exit) | All items passed, exit code 0, no forced termination |
| The same regression plus GPU resource re-creation (2 controlled failures) and power resume on the test-hook build | All items passed. Resources re-created, renderers recovered on all 3 surfaces, terminal sessions preserved, duplicate resume suppressed |
| 20-iteration soak test (including GPU re-creation and controlled power resume) | All 20 passed, 0 failures, 133.0 seconds elapsed |
| Unit tests | 3837 of 3899 passed, 62 skipped, 0 failed |
| Split pane | After splitting and clicking back into the original pane, the command and its output remain. The new reflow test fails without the fix |
| Installer | `scripts/build-installer.ps1` succeeds (`TerminfoCompiled` True) and the payload contains `bin\ghostty.exe`, `bin\conpty.dll`, `bin\OpenConsole.exe`, and `THIRD-PARTY-NOTICES.md` |
| Install, upgrade, and uninstall | Confirmed on real hardware |

The installer script check above built an unsigned installer. A right-aligned
prompt still wraps its last character onto a new row when its pane narrows;
it is real content out to the old right edge, and the shell does not redraw
it.

### Known Limitations

Unchanged from `1.3.2-windows.1`; see that section below.


## 1.3.2-windows.4

- Release date: 2026-09-16
- Tag: `v1.3.2-windows.4`
- Base version: upstream Ghostty 1.3.2 series (the in-development `1.3.2-dev`)
- Status: preview. A bug-fix release for `1.3.2-windows.3`; programs running
  in Ghostty can draw images.
- Distribution format: the portable executable and resources generated by
  `scripts/build-release.ps1`, and an installer built from that release tree
  with `scripts/build-installer.ps1`. From this version the distribution also
  carries `bin\conpty.dll` and `bin\OpenConsole.exe`. The signed installer
  `ghostty-1.3.2-windows.4-x64-setup.exe` is published as a release asset on
  [the release page](https://github.com/fukuyori/ghostty/releases/tag/v1.3.2-windows.4).
  There is no automatic update.

### Reproducing This Version

```powershell
git checkout v1.3.2-windows.4
./scripts/build-release.ps1 -AdditionalZigArgs '-Dversion-string=1.3.2-windows.4'
./zig-out/release/bin/ghostty.exe --version
```

`--version` and the `FileVersion` file property are `1.3.2-windows.4`, and the
numeric version is `1.3.2.4`. The release script fetches the ConPTY host with
`scripts/fetch-conpty.ps1` before building; a build without it cannot show
images. To verify GPU recovery and power resume with the regression script,
use a separate build with `-TestHooks`. Do not include it in the
distribution.

### Changes Since 1.3.2-windows.3

The [changelog](windows-changelog.md) lists these with their commits.

- Programs running in Ghostty can draw images with the Kitty graphics
  protocol. Two unrelated faults had to be fixed: the ConPTY in `kernel32.dll`
  discarded the APC sequences the protocol travels in, and the D3D11 image
  shader clipped every image quad away before rasterizing it.
- Ghostty now loads the OpenConsole ConPTY host from beside its own
  executable, falling back to `kernel32.dll` when it isn't there. Query
  replies round-trip as a result: `ESC [ c` is answered by Ghostty rather than
  by the in-box console host, and `ESC [ 16 t` reports the cell size.
- The distribution and the installer carry `conpty.dll`, `OpenConsole.exe`,
  and the MIT notice they are redistributed under.

### Verification

Verified on 2026-09-16 on Windows 11 Pro (10.0.26200, four monitors: three at
96 DPI and one at 120 DPI) against the ReleaseFast, baseline CPU executable.

| Item | Result |
|---|---|
| Release build script checks (PE32+, x64, WindowsGui, version information, icon, resources, compiled terminfo) | Passed. `FileVersion` 1.3.2-windows.4, numeric version 1.3.2.4, `IsDebug` False, `TerminfoCompiled` True |
| `--version`, `+list-keybinds --default` | Exit code 0 |
| Window-state regression on the distribution build (terminal input, IME process keys, split pane click focus, startup grid, config reload, splits, 4 monitors, multiple windows, maximize/minimize/restore, clean exit) | All items passed, exit code 0, no forced termination |
| The same regression plus GPU resource re-creation (2 controlled failures) and power resume on the test-hook build | All items passed. Resources re-created, renderer recovered, terminal session preserved |
| 20-iteration soak test (including GPU re-creation and controlled power resume) | All 20 passed, 0 failures, 141.9 seconds elapsed |
| Unit tests | 3835 of 3897 passed, 62 skipped, 0 failed, across 77 build steps |
| Images through the Kitty graphics protocol | `terminal-browser` renders a page. The log reports `using the sideloaded conpty.dll next to our executable` |
| Installer | `scripts/build-installer.ps1` succeeds and the payload contains `bin\conpty.dll`, `bin\OpenConsole.exe`, and `THIRD-PARTY-NOTICES.md` |
| Published installer | `ghostty-1.3.2-windows.4-x64-setup.exe`, 17798192 bytes. `FileVersion` and `ProductVersion` 1.3.2-windows.4. Authenticode signature `Valid`, signer `CN=Noriaki Fukuyori`, timestamped by Sectigo |

The six manual Windows shell acceptance items carry over the results that
passed on 2026-09-15; this version changes nothing related to Alt+Tab, the
taskbar, or Snap. The published installer is signed and verified as a file,
but installing, uninstalling, and upgrading through it are not verified on
real hardware. The image path is verified with
`terminal-browser` only, not with other programs that draw images.

### Known Limitations

Unchanged from `1.3.2-windows.1`; see that section below.


## 1.3.2-windows.3

- Release date: 2026-09-16
- Tag: `v1.3.2-windows.3`
- Base version: upstream Ghostty 1.3.2 series (the in-development `1.3.2-dev`)
- Status: preview. A bug-fix release for `1.3.2-windows.2`; it fixes every
  known issue listed for that version.
- Distribution format: the portable executable and resources generated by
  `scripts/build-release.ps1`, and an installer built from that release tree
  with `scripts/build-installer.ps1`. There is no automatic update. Signing is
  done at distribution time.

### Reproducing This Version

```powershell
git checkout v1.3.2-windows.3
./scripts/build-release.ps1 -AdditionalZigArgs '-Dversion-string=1.3.2-windows.3'
./zig-out/release/bin/ghostty.exe --version
```

`--version` and the `FileVersion` file property are `1.3.2-windows.3`, and the
numeric version is `1.3.2.3`. To verify GPU recovery and power resume with the
regression script, use a separate build with `-TestHooks`. Do not include it in
the distribution.

### Changes Since 1.3.2-windows.2

The [changelog](windows-changelog.md) lists these with their commits.

- A click moves keyboard focus to the split pane under the cursor. The pane
  the split did not focus no longer looks unresponsive.
- Programs that read a terminfo database resolve `xterm-ghostty`. The build
  compiles the database when `tic` is available, and the installer ships it.
- The installer file name no longer changes on every commit, and packaging a
  development build warns that it is not a distributable release.
- The user guide documents fonts, including how `font-family` matches family
  names and which faces are resized.

### Verification

Verified on 2026-09-16 on Windows 11 Pro (10.0.26200, four monitors: three at
96 DPI and one at 120 DPI) against the ReleaseFast, baseline CPU executable.

| Item | Result |
|---|---|
| Release build script checks (PE32+, x64, WindowsGui, version information, icon, resources, compiled terminfo) | Passed. `FileVersion` 1.3.2-windows.3, numeric version 1.3.2.3, `IsDebug` False, `TerminfoCompiled` True |
| `--version`, `+list-keybinds --default` | Exit code 0 |
| Window-state regression on the distribution build (terminal input, IME process keys, split pane click focus, startup grid, config reload, splits, 4 monitors, multiple windows, maximize/minimize/restore, clean exit) | All items passed, exit code 0, no forced termination |
| The same regression plus GPU resource re-creation (2 controlled failures) and power resume (3 surfaces) on the test-hook build | All items passed |
| 20-iteration soak test (including GPU re-creation and controlled power resume) | All 20 processes passed, 0 failures, 115.0 seconds elapsed, no leftover temporary files |
| Unit tests for Win32, D3D11, and build helpers | Passed |

The six manual Windows shell acceptance items carry over the results that
passed on 2026-09-15 with the icon-fix build; this version changes nothing
related to Alt+Tab, the taskbar, or Snap. Installation, uninstallation, and
upgrade behavior of the installer itself are not verified.

### Known Limitations

Unchanged from `1.3.2-windows.1`; see that section below. The font behavior
described in the user guide is tracked as issues
[1](https://github.com/fukuyori/ghostty/issues/1),
[2](https://github.com/fukuyori/ghostty/issues/2), and
[3](https://github.com/fukuyori/ghostty/issues/3).

## 1.3.2-windows.2

- Release date: 2026-09-15
- Tag: `v1.3.2-windows.2`
- Base version: upstream Ghostty 1.3.2 series (the in-development `1.3.2-dev`)
- Status: preview. A bug-fix release for `1.3.2-windows.1`; it fixes every
  known issue listed for that version.
- Distribution format: the portable executable and resources generated by
  `scripts/build-release.ps1`, and an installer built from that release tree
  with `scripts/build-installer.ps1`. There is no automatic update. Signing is
  done at distribution time.

### Reproducing This Version

```powershell
git checkout v1.3.2-windows.2
./scripts/build-release.ps1 -AdditionalZigArgs '-Dversion-string=1.3.2-windows.2'
./zig-out/release/bin/ghostty.exe --version
```

`--version` and the `FileVersion` file property are `1.3.2-windows.2`, and the
numeric version is `1.3.2.2`. From this version on, a checkout of the tag also
builds the published version without `-Dversion-string`. To verify GPU recovery
and power resume with the regression script, use a separate build with
`-TestHooks`. Do not include it in the distribution.

### Changes Since 1.3.2-windows.1

The [changelog](windows-changelog.md) lists these with their commits.

- Keys consumed by an IME no longer reach the terminal. During Japanese
  composition, Enter no longer inserts a newline around the committed text and
  Backspace no longer deletes already committed characters. Tab, the arrow
  keys, and Escape are affected the same way and are also fixed.
- The startup window size is applied to the terminal. With `window-width` and
  `window-height` set, the terminal grid and the ConPTY now match the window
  immediately, instead of staying at the default 800x600 equivalent until the
  first manual resize.
- A checkout of a preview tag builds without `-Dversion-string`. The build
  system now accepts `vX.Y.Z-<pre-release>` tags whose numeric part matches
  `build.zig.zon`.
- New: an Inno Setup installer script (`scripts/build-installer.ps1` and
  `dist/windows/ghostty.iss`) that offers per-user or machine-wide
  installation, Start Menu and optional desktop shortcuts, an optional `PATH`
  entry removed on uninstall, English and Japanese wizards, and `-Sign` for
  signing the executable, the installer, and the uninstaller.
- The regression script gained two phases: one that rejects keys consumed by
  an IME, and one that checks the terminal grid right after startup. Both fail
  against the `1.3.2-windows.1` build.

### Verification

Verified on 2026-09-15 on Windows 11 Pro (10.0.26200, four monitors: three at
96 DPI and one at 120 DPI) against the ReleaseFast, baseline CPU executable.

| Item | Result |
|---|---|
| Release build script checks (PE32+, x64, WindowsGui, version information, icon, resources) | Passed. `FileVersion` 1.3.2-windows.2, numeric version 1.3.2.2, `IsDebug` False |
| `--version`, `+list-keybinds --default` | Exit code 0 |
| Window-state regression on the distribution build (terminal input, IME process keys, startup grid, config reload, splits, 4 monitors, multiple windows, maximize/minimize/restore, clean exit) | All items passed, exit code 0, no forced termination |
| The same regression plus GPU resource re-creation (2 controlled failures) and power resume (3 surfaces) on the test-hook build | All items passed |
| 20-iteration soak test (including GPU re-creation and controlled power resume) | All 20 processes passed, 0 failures, 110.7 seconds elapsed, no leftover temporary files |
| Unit tests for Win32, D3D11, and build helpers | Passed |

The six manual Windows shell acceptance items carry over the results that
passed on 2026-09-15 with the icon-fix build; this version changes nothing
related to Alt+Tab, the taskbar, or Snap. Installation, uninstallation, and
upgrade behavior of the installer itself are not verified.

### Known Issues

Both are fixed in `1.3.2-windows.3`.

- After a split, clicking the pane that the split did not focus does not move
  keyboard focus to it, so that pane looks unresponsive and typing keeps going
  to the other one. Child windows never take focus on their own and the mouse
  handler did not set it. Moving between panes with `goto_split` works. Fixed
  in the next version.
- Programs that read a terminfo database report
  `'xterm-ghostty': unknown terminal type.` The Windows build ships only the
  terminfo source, not a compiled database, while still setting
  `TERM=xterm-ghostty`. Native Windows console programs are unaffected; MSYS2,
  Git Bash, Cygwin, WSL, and remote hosts are. Compiling the entry once with
  `tic -x -o ~/.terminfo <source>` works around it. The next version ships the
  compiled database and documents the remaining cases.

### Known Limitations

Unchanged from `1.3.2-windows.1`; see that section below.

## 1.3.2-windows.1

- Release date: 2026-09-15
- Tag: `v1.3.2-windows.1`
- Base version: upstream Ghostty 1.3.2 series (the first Windows preview based
  on the in-development `1.3.2-dev`)
- Status: preview. It covers what has been verified on Windows 11, and the
  not-verified items below are published as known limitations.
- Distribution format: the portable executable and resources generated by
  `scripts/build-release.ps1`. No installer or automatic update is included.
  Signing is done separately at distribution time.

### Reproducing This Version

```powershell
git checkout v1.3.2-windows.1
./scripts/build-release.ps1 -AdditionalZigArgs '-Dversion-string=1.3.2-windows.1'
./zig-out/release/bin/ghostty.exe --version
```

`--version` and the `FileVersion` file property are `1.3.2-windows.1`, and the
numeric version is `1.3.2.1`. To verify GPU recovery and power resume with the
regression script, use a separate build with `-TestHooks`. Do not include it in
the distribution.

### Highlights

- Win32-native window, title bar, tab bar, and split borders
- Rendering with D3D11 and DirectComposition, background transparency
- Automatic re-creation of GPU resources on device loss and power resume (with
  timer retries, failure notification, and a cycle limit)
- Multiple windows, native tabs, and nested split panes, operable from both
  keyboard and mouse
- Windows IME, clipboard, URL and file operations
- Layout-independent key identification based on scan codes, and unmodified
  characters from the current layout
- Per-Monitor V2 DPI, high contrast, and tab information exposed through MSAA
- Loading and reloading of `%LOCALAPPDATA%\ghostty\config.ghostty`
- Scripts for the Release build, window-state regression, soak test, shell
  acceptance test, and startup diagnostic log

### Verification

On 2026-09-15, the following was verified on Windows 11 Pro (10.0.26200, four
monitors: three at 96 DPI and one at 120 DPI) against the ReleaseFast, baseline
CPU executable.

| Item | Result |
|---|---|
| Release build script checks (PE32+, x64, WindowsGui, version information, icon, resources) | Passed. `FileVersion` 1.3.2-windows.1, numeric version 1.3.2.1, `IsDebug` False |
| `--version`, `+list-keybinds --default` | Exit code 0 |
| Window-state regression (terminal input, config reload, splits, moving across 4 monitors, multiple windows, maximize/minimize/restore, normal exit) | All items passed on the distribution build, exit code 0, no forced termination |
| The same regression plus GPU resource re-creation (2 controlled failures) and power resume (3 surfaces) | All items passed on the test-hook build |
| 20-iteration soak test (including GPU re-creation and controlled power resume) | All 20 processes passed, 0 failures, 51 seconds elapsed, no leftover temporary files |
| Unit tests for Win32, D3D11, and build helpers | Passed |

The six manual Windows shell acceptance items carry over the results that
passed on 2026-09-15 with the icon-fix build. This version has no changes
related to Alt+Tab, the taskbar, or Snap. Authenticode signing is done
separately at distribution time.

### Known Issues

All of these are fixed in `1.3.2-windows.2`.

- When `window-width` and `window-height` are set, the terminal grid and ConPTY
  right after startup remain at the default 800×600 equivalent (about 26 rows),
  and the lower part of the window is unused. Resizing the window once corrects
  this. The cause is that the resize notification from `initial_size` during
  core initialization is not delivered; this will be fixed in the next version.
- Running `zig build` without `-Dversion-string` with the tag `v1.3.2-windows.1`
  checked out fails because the build system rejects the tag format. Passing
  `-Dversion-string=1.3.2-windows.1` as in the reproduction steps succeeds. The
  next version will accept the tag format.
- Keys consumed by an IME also reach the terminal. While composing Japanese
  text, Enter inserts a newline around the committed text and Backspace
  deletes already committed characters in addition to the composition. Other
  control keys used during conversion (Tab, arrows, Escape) leak the same way.
  This will be fixed in the next version.

### Known Limitations

- Windows 10 is not verified. Verified on Windows 11.
- 144 DPI and 192 DPI are covered by unit tests only and are not verified on
  real hardware. Mixed 96 DPI and 120 DPI environments are verified by
  automated regression.
- Keyboard layouts other than the Japanese layout are not verified on real
  hardware.
- Resuming from an actual PC sleep, recovery from an actual GPU device loss,
  and continuous operation on the scale of several hours are not verified.
  Controlled resume using Windows notifications and the 20-iteration soak test
  are verified.
- Screen reading with Narrator or NVDA, and display in an environment with high
  contrast actually enabled, are not verified.
- `background-blur` varies in quality depending on the environment, so
  disabling it is recommended.
- There is no installer or automatic update. There is no GUI equivalent to the
  macOS settings window or the Linux GTK integration.
- If another process of the same user posts the power notification message,
  GPU resources are re-created for all surfaces. The display is only briefly
  disturbed and the session is preserved.
