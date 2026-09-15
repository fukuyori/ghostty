# Ghostty for Windows User Guide

This document summarizes the configuration, operation, and known limitations
for building and using the native Windows build of this fork. The Windows
build is at the preview stage; the current version is `1.3.2-windows.1`. See
the [release notes](windows-release-notes.md) for the publication history and
the verification results of each version. There are two distribution forms: a
portable executable produced by the Release build script, and an installer
created with Inno Setup.

## Build and Launch

Debug build:

```powershell
zig build
./zig-out/bin/ghostty.exe
```

Portable Release build:

```powershell
./scripts/build-release.ps1
./zig-out/release/bin/ghostty.exe
```

To reproduce a published version, check out the tag and specify the version
number explicitly.

```powershell
git checkout v1.3.2-windows.1
./scripts/build-release.ps1 -AdditionalZigArgs '-Dversion-string=1.3.2-windows.1'
```

## Creating the Installer

An Inno Setup 6 installer can be created from the Release build.
[Inno Setup 6.3 or later](https://jrsoftware.org/isinfo.php) is required, and
`signtool.exe` from the Windows SDK when signing. The script copies the
contents of `zig-out\release` to `zig-out\installer\stage` before processing,
so the Release build itself is not modified.

```powershell
./scripts/build-release.ps1 -AdditionalZigArgs '-Dversion-string=1.3.2-windows.1'
./scripts/build-installer.ps1 -Version 1.3.2-windows.1
```

The output is `zig-out\installer\ghostty-<version>-x64-setup.exe`. The
installer's `ProductVersion` and numeric version take the same values as the
executable, and the script checks that they match. If `-Version` is passed, the
script fails when the executable's version does not match.

The installer has the following contents.

- Places `bin\ghostty.exe`, `share\ghostty` (themes, shell integration), and
  `share\terminfo\ghostty.terminfo`. The executable looks for
  `share\terminfo\ghostty.terminfo` relative to its own location to determine
  the resource directory, so this layout cannot be changed.
- The default is a per-user installation (no administrator rights required);
  installation for all users into `Program Files` can also be selected from
  the dialog.
- Registers a Start menu entry and optionally creates a desktop icon and adds
  `bin` to the `PATH` environment variable. `PATH` edits the user or system
  environment variable depending on the installation type, and the entry is
  removed on uninstall.
- Includes English and Japanese wizards. The target is x64 Windows 10 1809 or
  later.
- Because the same AppId is used, the installer for a newer version updates an
  existing installation in place.

Specify `-Sign` to attach a digital signature. The executable is signed first
and then packaged, and Inno Setup signs the installer and uninstaller with the
same certificate. By default the certificate is selected by the subject name
in the `CODESIGN_CERT` environment variable (a code-signing certificate in the
certificate store; signtool's `/n`). If subject names are duplicated, use
`-CertificateThumbprint`; a certificate that is not in the store can be
specified with `-PfxPath` and `-PfxPassword`. The PFX password appears on the
command line.

```powershell
$env:CODESIGN_CERT = "certificate subject name"
./scripts/build-installer.ps1 -Version 1.3.2-windows.1 -Sign
```

The signature is SHA-256, and by default a timestamp from
`http://timestamp.sectigo.com` is attached. Specify `-TimestampUrl` for a
different server, or `-NoTimestamp` to omit the timestamp for verification-only
builds. The result shows the signature state and signer of each file. The
uninstaller's signature can be checked on `unins000.exe` after installation.

On September 15, 2026, creating an unsigned installer and the behavior of
`-Sign` with a temporary self-signed certificate (the executable, the
uninstaller, and the installer all being signed with SHA-256) were verified.
Verification of the installation itself is still needed separately.

The test hooks used by the GPU recovery and power resume regression scripts are
not built in by default. Build an executable for regression tests as follows.
Do not specify this for distribution builds.

```powershell
zig build -Dwin32-test-hooks=true
./scripts/build-release.ps1 -TestHooks
```

The Release script places the executable and resources but does not create an
archive or installer. After building, it verifies and displays the PE format,
CPU architecture, Windows GUI subsystem, CLI and Windows version information,
the embedded icon group with large and small icons, shell integration, themes,
file size, and SHA-256.

For the source of truth when changing the version, the conditionally updated
locations, and the Release verification procedure, see the
[version update checklist](version-update-checklist.md).
The command-line version display and the `FileVersion` and `ProductVersion` in
the Windows file properties contain the same build version. Windows previews
use the format `X.Y.Z-windows.N`, a sequence number appended to the upstream
base version, and `N` goes into the fourth component of the numeric version
(for example, `1.3.2-windows.4` is `1.3.2.4`). Regular development builds are
`X.Y.Z-windows-+<hash>`, with the fourth component set to 0.

## Configuration File

The standard configuration file is located here.

```text
%LOCALAPPDATA%\ghostty\config.ghostty
```

If `XDG_CONFIG_HOME` is set, it takes precedence.

```text
%XDG_CONFIG_HOME%\ghostty\config.ghostty
```

The legacy `ghostty\config` without an extension is also read. If both exist,
the legacy file is read first and the newer `config.ghostty` afterwards, so the
settings in the latter take precedence.

Default keys related to configuration:

| Key | Action |
|---|---|
| `Ctrl+,` | Open the configuration file |
| `Ctrl+Shift+,` | Reload the configuration |

The configuration can also be checked from the command line.

```powershell
./zig-out/bin/ghostty.exe +validate-config
./zig-out/bin/ghostty.exe +show-config
./zig-out/bin/ghostty.exe +list-keybinds
```

## Terminal Type and terminfo

Ghostty sets `TERM=xterm-ghostty` and points `TERMINFO` at
`<install>\share\terminfo`. Native Windows console programs such as
`cmd.exe` and PowerShell ignore both, so they are unaffected. Programs that
read a terminfo database do use them, and report

```
'xterm-ghostty': unknown terminal type.
```

when the database does not contain the entry.

The Release build compiles the database into `share\terminfo` whenever `tic`
is available on the build machine. Git for Windows ships one in
`C:\Program Files\Git\usr\bin`, and the build also looks in the usual MSYS2
and Cygwin locations. Without `tic` the build installs only the terminfo
source, `share\terminfo\ghostty.terminfo`, and prints a warning.

### MSYS2, Git Bash, and Cygwin

The ncurses build used by these environments does not accept a Windows-style
path in `TERMINFO`, so it cannot read the shipped database directly. Compile
the entry into your home directory once; ncurses searches `~/.terminfo`
regardless of what `TERMINFO` contains.

```bash
tic -x -o ~/.terminfo "$LOCALAPPDATA/Programs/Ghostty/share/terminfo/ghostty.terminfo"
```

For a portable build, replace the path with the `share\terminfo` directory of
that build. Confirm the result with `tput longname`, which prints `Ghostty`,
and `tput colors`, which prints `256`. The line `tic` prints about the
description field is a note from newer `tic` versions, not an error.

### WSL

A Linux distribution under WSL has its own terminfo database and cannot read
the Windows one, so run the same command inside the distribution. The source
file is reachable through `/mnt`.

```bash
tic -x -o ~/.terminfo "/mnt/c/Users/$USER/AppData/Local/Programs/Ghostty/share/terminfo/ghostty.terminfo"
```

### Remote hosts over SSH

Two shell integration features cover this; set them with
`shell-integration-features` in the configuration file.

- `ssh-terminfo` installs Ghostty's terminfo entry on the remote host with
  `tic` on the first connection and caches the result. The remote host needs
  `tic`.
- `ssh-env` sends `TERM=xterm-256color` instead, which every host understands
  at the cost of Ghostty-specific capabilities.

```
shell-integration-features = ssh-terminfo,ssh-env
```

## Startup Diagnostic Log

In a normal GUI launch, standard error is not shown on screen. To investigate
startup failures or initialization errors, launch from the diagnostic script.

```powershell
./scripts/run-windows-diagnostics.ps1
```

By default the log is saved to `zig-out\logs`, and the launched process ID and
the absolute path of the log are displayed. To wait until Ghostty exits and
also obtain the exit code, run as follows.

```powershell
./scripts/run-windows-diagnostics.ps1 -Wait
```

To diagnose a specific CLI operation, use `AdditionalArguments`.

```powershell
./scripts/run-windows-diagnostics.ps1 `
    -AdditionalArguments @('+validate-config') `
    -Wait
```

The log may contain configuration values, paths, and information originating
from the programs that were run. Review its contents before sharing.

## Window State Regression Check

Text input and command execution, configuration reload, creation, movement,
visibility toggling, and closing of multiple windows, mixed-DPI monitor
tracking, split dividers, maximize, minimize, restore, and clean exit of the
Release executable can be checked all at once.

```powershell
./scripts/test-windows-window-state.ps1
```

The script launches a single dedicated Ghostty process and does not touch
existing Ghostty windows. It checks the window styles required for snapping,
the top-level structure needed to be an Alt+Tab and taskbar target, the window
class's large and small icons, and the DWM visibility state. It further checks
that the window returns from minimized to the previous maximized state, the
position and size after restoring to the normal state, and the exit code after
`WM_CLOSE`. It sends a string and Enter to a dedicated `cmd.exe` terminal and
confirms command execution from the contents of a temporary marker. It then
sends Enter and Backspace the way Windows reports them while an IME is
composing and confirms that neither reaches the shell. Using a
temporary configuration inside the repository, it also confirms that a
configuration reload switches the tab bar to shown, hidden, and shown again.
It then creates a test right split and confirms that the tab bar and split
divider track each monitor, maximize, and restore. Finally, it creates a second
top-level window and checks configuration reload synchronization to both
windows, focus movement and cycling, and hiding and restoring all windows at
once. It also checks that the original window remains after closing one
individually, and that the process exits cleanly on a close-all after
recreation. Lastly, it launches a dedicated process with the tab bar hidden and
`window-width` and `window-height` specified, and checks that the ConPTY row
count immediately after startup matches the count after a 1px resize (that is,
the startup size is applied to the terminal). Because the dedicated process is
launched with `--config-default-files=false`, the user configuration in
`%LOCALAPPDATA%` is not loaded and the results do not depend on this machine's
settings. The user's configuration file is not modified, and the temporary
configuration and marker are deleted after a clean exit or by automatic
cleanup. Standard output and standard error are saved to `zig-out/logs`. To
check a different executable, specify it as follows.

```powershell
./scripts/test-windows-window-state.ps1 `
    -Executable zig-out/version-check-script/bin/ghostty.exe
```

Recreation of D3D11, DirectComposition, shaders, the swap chain, and image
resources, and that commands can still be executed in the same terminal session
after recovery, can be verified with a dedicated test hook. This option does
not cause a physical GPU failure. The test hooks exist only in executables
built with `-Dwin32-test-hooks=true`; if an executable without the hooks is
specified, the script fails without waiting.

```powershell
./scripts/test-windows-window-state.ps1 -TestGpuRecovery
```

To test consecutive recreations in the same process, specify the count.

```powershell
./scripts/test-windows-window-state.ps1 `
    -TestGpuRecovery `
    -GpuRecoveryIterations 20
```

Finite retries after a temporary reinitialization failure can be verified by
making the first two attempts fail under control. Retries are performed by a
timer on the renderer thread, up to 6 per cycle, with wait times of 100ms,
250ms, 1 second, 2 seconds, and 5 seconds. Resize and focus handling continues
while waiting. If every attempt in a cycle fails, the app is notified and
restarts up to 3 cycles for the same surface. If recovery still does not
succeed, rendering stays stopped, a diagnostic log is left, and the cycle
starts again on the next power resume notification.

```powershell
./scripts/test-windows-window-state.ps1 `
    -TestGpuRecovery `
    -GpuRecoveryFailures 2
```

On September 15, 2026, 20 consecutive runs were performed in the same terminal
session with the Release build, confirming 20 recreation starts, 20
completions, 0 failures, and 0 known log anomalies. Subsequent terminal input,
configuration reload, splits, movement across 4 monitors, multi-window
operations, and clean exit also succeeded. In the test with 2 controlled
failures, recovery occurred on the third attempt, and the terminal session and
the full GUI regression were maintained. In the negative test performed when
the retry limit was 3, 3 controlled failures produced 1 final failure and 0
fourth attempts, confirming that retries are not infinite.

To send Windows suspend and automatic resume notifications to the dedicated
process and verify GPU resource recreation and terminal session preservation on
power resume, run the following. This test does not put the PC itself to
sleep.

```powershell
./scripts/test-windows-window-state.ps1 -TestPowerResume
```

On September 15, 2026 with the Release build, a single surface was recovered
first, and then all 3 surfaces belonging to a split window and a separate
window were recovered simultaneously. Duplicate resume notifications reaching
the second top-level window were suppressed; in total there were 2 suspend
detections, 2 resume detections, 4 GPU recreation starts and 4 completions,
and 0 failures. Terminal input after recovery and the full GUI regression also
succeeded.

For snapping, Alt+Tab, and the taskbar, what this script checks is the
structure required to be a target of the Windows shell. Actual key operations,
snap layouts, and operations from the taskbar are verified separately on real
hardware.

It moves the dedicated window to each connected monitor in turn and also
checks the origin, width, DPI, per-DPI height, and ownership relationship of
the parent client area and `GhosttyTabBar`. After the test, the window is
returned to its initial position. If monitors with different DPIs are not
connected, this does not constitute a mixed-DPI check, so review the
per-monitor DPI values in the output.

## Repeated and Long-Running Regression Checks

To repeat the window state regression test 20 times, run the following.

```powershell
./scripts/test-windows-soak.ps1 -Iterations 20
```

To include controlled recreation of GPU resources and the power resume
notification test (which does not put the PC to sleep) in each iteration, run
the following.

```powershell
./scripts/test-windows-soak.ps1 `
    -Iterations 20 `
    -DelaySeconds 0 `
    -TestGpuRecovery `
    -GpuRecoveryIterations 1 `
    -TestPowerResume
```

To run on a time basis, specify the duration in minutes. In this case the
iteration count is not used. A regression test already in progress is not cut
short; the end time is evaluated after it completes.

```powershell
./scripts/test-windows-soak.ps1 -DurationMinutes 60
```

Each iteration uses an independent Ghostty process. It repeats launch, text
input, configuration reload, splits and DPI tracking, multiple windows, and
clean exit, and saves the test results and the paths of the individual logs to
`zig-out/logs/windows-soak-*.json` every time. On failure, it still records
the results so far and the error to the JSON before exiting. This test targets
repeated process launch and exit; it is not a continuous-operation test that
keeps a single terminal session open.

On September 15, 2026, the 20-iteration baseline test was run with the Release
build, confirming that all 20 succeeded, with 0 failures, 0 forced
terminations, 0 log anomalies, and 0 leftover temporary files. The elapsed
time was 40.054 seconds. Multi-hour tests are still needed separately.

On the same day, 20 iterations including GPU recreation and controlled power
resume were also run, and all 20 independent processes succeeded in 59.004
seconds. All 100 GPU resource recreations, 5 per process, completed, with 0
recovery failures, 0 invalid JSON records, and 0 leftover temporary files.

## Keyboard Layouts

Because the physical key for a key binding is determined from the scan code,
`physical:` bindings and the default split navigation keys match by key
position even on Japanese or European layouts. Character bindings such as
`ctrl+;` are matched against the character that the key produces without
modifiers on the current layout. Only key messages posted by automation tools
without a scan code fall back to the US-layout-equivalent virtual key table.
Unit tests and regression tests pass on real hardware with a Japanese layout,
but other layouts have not been verified on real hardware.

## Manual Acceptance Check for the Windows Shell

The automated regression test checks the window structure required to be a
target of snapping, Alt+Tab, and the taskbar. Appearance and actual operation
on the Windows shell are recorded with the following manual test. When only
reviewing the items, Ghostty is not launched.

```powershell
./scripts/test-windows-shell.ps1 -ListOnly
```

To start the acceptance test, run the following.

```powershell
./scripts/test-windows-shell.ps1
```

To recheck only a specific item, the item ID can be specified.

```powershell
./scripts/test-windows-shell.ps1 -CheckId alt-tab
```

The script does not touch the user configuration; it uses a dedicated Ghostty
process launched with `--config-default-files=false` and a temporary
configuration.
For each of the following 6 items, enter `p` (pass), `f` (fail), `s` (skip),
or `q` (abort).

1. Display and focus via Alt+Tab
2. Minimize, restore, and focus via the taskbar button
3. Snapping with `Win+Left` and `Win+Right`
4. Snap layouts from `Win+Z` or the maximize button
5. Alt+Tab and individual taskbar selection with 2 windows
6. Closing individually and closing all from the taskbar preview

Sleep resume on real hardware is not included in the regular 6 items. Save
your other work first, then select it explicitly as follows.

```powershell
./scripts/test-windows-shell.ps1 -CheckId power-resume
```

After resuming, visually confirm the same terminal contents, input, and
rendering state. In addition to the manual answers, the final JSON stores the
number of suspend notifications, resume notifications, scheduled renderer
recoveries, completions, and failures obtained from the diagnostic log. Even if
pass is selected manually, the overall result is not a pass if the automatic
verification against the log fails.

`zig-out/logs/windows-shell-*.json` is updated after each answer. Even on
abort or failure, the answered items, execution environment, executable
version and SHA-256, diagnostic log, and errors are saved. At the end of the
test, the dedicated process and temporary configuration are cleaned up.

In actual operation on Windows 11 on September 15, 2026, taskbar operations,
left and right snapping, snap layouts, selection between 2 windows, and closing
individually and closing all from the taskbar passed. In the first test the
Alt+Tab icon was not the distinct one, but the test was repeated with a fixed
build that sets the large and small Ghostty icons on the window class, and it
passed. With the fixed build, the automated regression that checks the class
icons was also run for 20 iterations, all successful.

## Windows GUI Settings

Example configuration:

```text
window-show-tab-bar = auto
window-new-tab-position = current
window-theme = ghostty
window-titlebar-background = 1E1E1E
window-titlebar-foreground = F0F0F0
background-opacity = 0.90
background-blur = false
```

Main settings:

- `window-show-tab-bar`: `auto`, `always`, `never`. `auto` shows the tab bar
  when there are multiple tabs or a split is zoomed.
- `window-new-tab-position`: `current` adds a new tab immediately after the
  current tab; `end` adds it at the end.
- `window-theme`: `auto`, `system`, `dark`, `light`, `ghostty`.
  With `ghostty`, the configured colors are applied to the title bar.
- `background-opacity`: Applied to background transparency in the D3D11 build.
- `background-blur`: On Windows, the display quality depends on the
  environment. `false` is recommended at this stage.

When Windows high contrast is enabled, system colors are used for the tab bar
and split dividers, and any custom title bar colors are cleared to return to
the Windows-managed color scheme.

## Default Tab Operations

| Key or Action | Behavior |
|---|---|
| `Ctrl+Shift+T` | New tab |
| `Ctrl+Shift+W` | Close the current tab |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | Next / previous tab |
| `Ctrl+PageDown` / `Ctrl+PageUp` | Next / previous tab |
| `Alt+1` to `Alt+8` | Tab with the given number |
| `Alt+9` | Last tab |
| `Ctrl+Shift+PageDown` / `Ctrl+Shift+PageUp` | Move the tab right / left |
| Click a tab | Select the tab |
| Drag a tab | Reorder tabs |
| Double-click a tab | Set a custom tab name; leave blank to revert to the terminal title |
| `×` on a tab | Close the tab |
| `+` on the tab bar | New tab |
| Mouse wheel over the tab bar | Next / previous tab |

## Default Split Operations

| Key or Action | Behavior |
|---|---|
| `Ctrl+Shift+O` | Split right |
| `Ctrl+Shift+E` | Split down |
| `Ctrl+Alt+Arrow` | Move to the pane in the given direction |
| `Ctrl+Win+[` / `Ctrl+Win+]` | Move to the previous / next pane |
| `Ctrl+Win+Shift+Arrow` | Resize the pane in the given direction |
| `Ctrl+Shift+Enter` | Toggle zoom of the current pane |
| Drag a split divider | Resize panes |

In addition, `Ctrl+Shift+N` opens a new window, `Ctrl+Enter` toggles
fullscreen, `Alt+F4` closes the window, and `Ctrl+Shift+Q` quits Ghostty.

## Accessibility

The custom-drawn tab bar is exposed as an MSAA page tab list. Each tab's name,
position, selection state, previous/next navigation, hit testing, and default
action can be obtained.

API-level inspection and automated regression tests are complete, but speech
output with Narrator and NVDA is still under acceptance verification.

## Known Limitations

- Basic operation has been verified on Windows 11, but Windows 10 is not
  verified.
- Keyboard layouts other than the Japanese layout are not verified on real
  hardware.
- Moving between 96 DPI and 120 DPI monitors has been automatically verified
  on real hardware, but verification on real hardware at 144 DPI and 192 DPI
  is not complete.
- Restoring from maximized and minimized, and the 20-iteration soak baseline
  test, are automatically verified. Controlled recreation of GPU resources and
  terminal session preservation are automatically verified, but recovery from
  an actual GPU device loss or driver failure, a resume test that actually
  puts the PC to sleep, and multi-hour continuous tests are not verified. The
  controlled resume test using Windows suspend and resume notifications is
  verified. D3D11 present HRESULTs and device removal reasons are recorded in
  the diagnostic log.
- The terminfo database is compiled only when `tic` is available on the build
  machine, and the ncurses build used by MSYS2, Git Bash, and Cygwin cannot
  read it through the Windows-style `TERMINFO` path Ghostty sets. Those
  environments, WSL, and remote hosts need the one-time step described in
  "Terminal Type and terminfo".
- The effect and quality of `background-blur` vary with the Windows and GPU
  configuration.
- An installer can be created, but it is not bundled with the published
  versions. There is no automatic update.
- There is no GUI equivalent to the macOS SwiftUI settings window or the Linux
  GTK integration.

For details on the implementation status and verification items, see the
[Windows production-readiness roadmap](windows-roadmap.md).
