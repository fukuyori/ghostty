# Gooztty User Guide

This document summarizes the configuration, operation, and known limitations
for building and using the native Windows build of this fork. The Windows
build is at the preview stage; its version is recorded in
`dist/windows/version.txt`. See
the [release notes](windows-release-notes.md) for the publication history and
the verification results of each version. There are two distribution forms: a
portable executable produced by the Release build script, and an installer
created with Inno Setup.

See the [Windows technical specification](windows-technical-spec.md)
(Japanese) for the implementation overview and input handling details.

## Build and Launch

Gooztty ships a ConPTY host next to its executable, because the one in
`kernel32.dll` drops the escape sequences that carry images. It is fetched
rather than committed, so get it once before building:

```powershell
./scripts/fetch-conpty.ps1
```

A build without it still works, it just cannot show images from programs
that use the Kitty graphics protocol, and the build says so.
`build-release.ps1` fetches it on its own. See `vendor/conpty/README.md`.

Debug build:

```powershell
zig build
./zig-out/bin/gooztty.exe
```

Portable Release build:

```powershell
./scripts/build-release.ps1
./zig-out/release/bin/gooztty.exe
```

The version of the Release build is read from `dist/windows/version.txt` in the
working tree, so it is the same whether or not the changes are committed or
tagged. The script takes no version: a version given on the command line would
only relabel the current sources.

If the install step fails with `AccessDenied` while updating
`zig-out\release\bin\gooztty.exe`, check whether that executable is running:

```powershell
Get-Process -Name gooztty -ErrorAction SilentlyContinue | Select-Object Id, Path
```

Save the terminal work, close Gooztty instances running from the output
directory, and rerun the build from another terminal. To keep Gooztty running,
choose a different output directory:

```powershell
./scripts/build-release.ps1 -OutputDirectory zig-out/release-next
```

This builds into `zig-out/release-next` instead of replacing the running
executable in `zig-out/release`.

## Creating the Installer

An Inno Setup 6 installer can be created from the Release build.
[Inno Setup 6.3 or later](https://jrsoftware.org/isinfo.php) is required, and
`signtool.exe` from the Windows SDK when signing. The script copies the
contents of `zig-out\release` to `zig-out\installer\stage` before processing,
so the Release build itself is not modified.

```powershell
./scripts/build-release.ps1
./scripts/build-installer.ps1
```

The output is `zig-out\installer\gooztty-<version>-x64-setup.exe`. The
installer's `ProductVersion` and numeric version take the same values as the
executable, and the script checks that they match. The script also fails when
the executable's version differs from `dist/windows/version.txt`.

The installer has the following contents.

- Places `bin\gooztty.exe`, `share\gooztty` (themes, shell integration), and
  `share\terminfo\gooztty.terminfo`. The executable looks for
  `share\terminfo\gooztty.terminfo` relative to its own location to determine
  the resource directory, so this layout cannot be changed.
- Places `bin\conpty.dll` and `bin\OpenConsole.exe`, the ConPTY host,
  beside the executable, which is where Gooztty looks for them. Both are
  required and must come from the same package version: `conpty.dll` on its
  own silently falls back to the host in `kernel32.dll`, and images stop
  appearing. `THIRD-PARTY-NOTICES.md` carries the MIT notice they are
  redistributed under.
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
  existing installation in place. Gooztty uses a different AppId from the
  Ghostty for Windows previews, so it installs beside them instead of
  replacing them; see
  [Moving from Ghostty for Windows](../README.md#moving-from-ghostty-for-windows).

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
./scripts/build-installer.ps1 -Sign
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
`X.Y.Z-<branch>+<hash>` (for example `1.3.2-gooztty+<hash>`), with the
fourth component set to 0.

## Configuration File

The standard configuration file is located here.

```text
%LOCALAPPDATA%\gooztty\config.gooztty
```

If `XDG_CONFIG_HOME` is set, it takes precedence.

```text
%XDG_CONFIG_HOME%\gooztty\config.gooztty
```

The legacy `gooztty\config` without an extension is also read. If both exist,
the legacy file is read first and the newer `config.gooztty` afterwards, so the
settings in the latter take precedence.

Default keys related to configuration:

| Key | Action |
|---|---|
| `Ctrl+,` | Open the configuration file |
| `Ctrl+Shift+,` | Reload the configuration |

The configuration can also be checked from the command line.

```powershell
./zig-out/bin/gooztty.exe +validate-config
./zig-out/bin/gooztty.exe +show-config
./zig-out/bin/gooztty.exe +list-keybinds
```

## Terminal Type and terminfo

Gooztty sets `TERM=xterm-gooztty` and points `TERMINFO` at
`<install>\share\terminfo`. Native Windows console programs such as
`cmd.exe` and PowerShell ignore both, so they are unaffected. Programs that
read a terminfo database do use them, and report

```
'xterm-gooztty': unknown terminal type.
```

when they cannot resolve the entry.

The Release build compiles the database into `share\terminfo` whenever `tic`
is available on the build machine. Git for Windows ships one in
`C:\Program Files\Git\usr\bin`, and the build also looks in the usual MSYS2
and Cygwin locations. Without `tic` the build installs only the terminfo
source, `share\terminfo\gooztty.terminfo`, and prints a warning.
`scripts/build-installer.ps1` reports the compiled entry as
`TerminfoUserEntry` and warns when it is absent, because the registration
described below has nothing to copy without it.

### Why `TERMINFO` is not enough

The programs that read terminfo here are not native Windows programs. `less`,
`tput`, and `tic` under `C:\Program Files\Git\usr\bin` come from MSYS2, which
is a fork of Cygwin, and Git for Windows bundles it. So a plain PowerShell
session reaches this ncurses as soon as Git pipes its output to `less`.

That ncurses cannot resolve the Windows-style path in `TERMINFO` from
everywhere. Whether the lookup succeeds turns on which drive the shell
happens to be on:

| Current directory | `TERMINFO=C:\...\Gooztty\share\terminfo` |
| ----------------- | ---------------------------------------- |
| on `C:`           | resolves                                 |
| on any other drive | `'xterm-gooztty': unknown terminal type.` |

Measured with the ncurses 6.6 in Git for Windows, from both PowerShell and
Git Bash. Only a POSIX-form path such as `/c/Users/<you>/...` resolves from
every drive. The likely mechanism is that the drive letter is dropped and the
rest is taken from the root of the current drive, but that is a hypothesis
and has not been confirmed.

### What Gooztty does about it

ncurses searches `$HOME/.terminfo` whatever `TERMINFO` holds, so an entry
there is found from any drive. Starting with `1.3.2-windows.10`, Gooztty
copies its compiled entry at startup to

```
%USERPROFILE%\.terminfo\78\xterm-gooztty
```

`78` is the hex form of `x`; this ncurses does not look in `x\`. An entry
that is already there is never replaced, so one compiled by hand with `tic`
survives. The entry is written to a temporary file beside its destination and
then moved onto it, with a move that refuses to overwrite, so nothing ever
reads a half-written file: two copies of Gooztty starting together are safe,
and one killed mid-write leaves only the temporary file, which the next start
replaces. The copy is not the installer's job: a machine-wide installation
runs as whoever elevated it, whereas every user reaches Gooztty's startup as
themselves. Nothing is removed on uninstall, for the same reason the existing
file is not replaced. A failure to copy does not stop Gooztty; the reason is
written to the log, which `scripts/run-windows-diagnostics.ps1` captures.

This covers the environments that take their home directory from the Windows
profile. Git for Windows is one: its `/etc/nsswitch.conf` carries
`db_home: env windows`.

### Cygwin, MSYS2 proper, and a custom `HOME`

Cygwin and a standalone MSYS2 keep the home directory inside their own
installation root, `/home/<user>`, rather than in the Windows profile, and
a `HOME` set in the Windows environment wins over both. In those cases the
entry Gooztty registers is in the wrong place and is not read. Compile the
entry into the home directory that environment actually uses, once.

```bash
tic -x -o ~/.terminfo "$LOCALAPPDATA/Programs/Gooztty/share/terminfo/gooztty.terminfo"
```

For a portable build, replace the path with the `share\terminfo` directory of
that build. Confirm the result with `tput longname`, which prints `Gooztty`,
and `tput colors`, which prints `256`. Run the check from a directory on a
drive other than the one Gooztty is installed on, which is where the original
failure shows up. The line `tic` prints about the description field is a note
from newer `tic` versions, not an error.

### WSL

A Linux distribution under WSL has its own terminfo database and cannot read
the Windows one, so run the same command inside the distribution. The source
file is reachable through `/mnt`.

```bash
tic -x -o ~/.terminfo "/mnt/c/Users/$USER/AppData/Local/Programs/Gooztty/share/terminfo/gooztty.terminfo"
```

### Remote hosts over SSH

Two shell integration features cover this; set them with
`shell-integration-features` in the configuration file.

- `ssh-terminfo` installs Gooztty's terminfo entry on the remote host with
  `tic` on the first connection and caches the result. The remote host needs
  `tic`.
- `ssh-env` sends `TERM=xterm-256color` instead, which every host understands
  at the cost of Gooztty-specific capabilities.

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
the absolute path of the log are displayed. To wait until Gooztty exits and
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

The script launches a single dedicated Gooztty process and does not touch
existing Gooztty windows. It checks the window styles required for snapping,
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
It then creates a test right split, confirms that clicking each pane moves
keyboard focus to it, and confirms that the tab bar and split divider track
each monitor, maximize, and restore. Finally, it creates a second
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
    -Executable zig-out/version-check-script/bin/gooztty.exe
```

## Session Save and Restore

Windows session restoration is opt-in. Add this to `config.gooztty`:

```ini
window-save-state = always
```

Interactive `pwsh` and `powershell` sessions are detected automatically and
report native drive directory changes before each prompt. UNC and device paths
are not reported. Command, file, encoded-command, and server modes keep their
original startup behavior. Set `shell-integration = none` to disable automatic
integration. If PowerShell's execution policy blocks the integration script,
Gooztty leaves the policy unchanged and PowerShell starts without directory
reporting.

For a temporary test, run these commands in PowerShell:

```powershell
zig build --prefix zig-out/powershell-integration-check
$exe = (Resolve-Path .\zig-out\powershell-integration-check\bin\gooztty.exe).Path
Start-Process -FilePath $exe -ArgumentList '--window-save-state=always' -Wait
```

After closing Gooztty normally and reopening it, Gooztty restores the windows,
tabs, split layout, focus, and titles. It restores a pane's working directory
when the shell reports it through OSC 7. PowerShell is integrated automatically
for interactive sessions and reports native drive directory changes before each
prompt when its execution policy allows the integration script. Each pane
starts a new terminal process; running processes and terminal contents are not
restored. If a saved directory is unavailable, the shell starts in its normal
startup directory. Windows moves restored windows onto an available monitor if
the saved display is gone.
The state file is stored at
`%LOCALAPPDATA%\gooztty\windows\session.json` by default, or
under `XDG_STATE_HOME\gooztty\windows\session.json` when that variable is set.

To clear the saved session, close every Gooztty window first, then remove the
state file:

```powershell
$stateFile = if ($env:XDG_STATE_HOME) {
    Join-Path $env:XDG_STATE_HOME 'gooztty\windows\session.json'
} else {
    Join-Path $env:LOCALAPPDATA 'gooztty\windows\session.json'
}
Remove-Item -LiteralPath $stateFile -ErrorAction SilentlyContinue
```

There is no dedicated clear-history option. Setting
`window-save-state = never` disables saving and restoring; it does not remove
an existing state file. If `always` remains enabled, a new session is saved
again when Gooztty exits normally.

To check it, create one window with multiple tabs and a nested split, then set
different directories in the panes. Close all Gooztty windows normally; the
PowerShell command waits for the app to exit. Then run the same command again.
Confirm that the tabs, split layout, titles, and per-pane directories return.
Multi-window save/relaunch with distinct PowerShell directories has also been
confirmed. Do not add
`-e`, `--command`, or an explicit `working-directory`: those options skip
restore and leave the saved session unchanged. The default
`window-save-state = default` does not enable Windows persistence.

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
the parent client area and `GoozttyTabBar`. After the test, the window is
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

Each iteration uses an independent Gooztty process. It repeats launch, text
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

## Fonts

Set the font with `font-family` in the configuration file. Give the **family
name**, not a style name. A style suffix does not match, and Gooztty then
falls back to another font. The diagnostic stderr log reports
`font-family <style> not found: <name>` for each missing configured style.

```
font-family = "Moralerspace Neon"
```

`Moralerspace Neon Regular` does not match, because `Regular` is a style
within the family. `Cascadia Code NF` does match, because `NF` is part of the
family name. List the installed family names to check:

```powershell
& .\zig-out\release\bin\gooztty.exe +list-fonts | Out-String
```

To check the exact name Gooztty will accept, filter the list with the same
family value. Keep the whole `--family=...` argument quoted when the name
contains spaces:

```powershell
& .\zig-out\release\bin\gooztty.exe +list-fonts "--family=Yu Gothic" | Out-String
```

An empty result means that `font-family` will not match that spelling. The
Windows FreeType backend can expose an English family name even when the font
also contains a localized Japanese family name; use the spelling shown by
`+list-fonts`. Full face names such as `Moralerspace Neon Regular` are not
accepted in place of their family name.

To see which face actually renders a character:

```powershell
& .\zig-out\release\bin\gooztty.exe +show-face --string=Aa | Out-String
```

`font-family` can be repeated. Characters missing from the first family are
looked up in the next one.

### Japanese and other non-Latin text

A Latin programming font usually has no Japanese glyphs, so those characters
come from somewhere else. What happens next depends on whether you named a
font that covers them.

| Case | Face selection | Size |
|---|---|---|
| A family in `font-family` covers the character | That family | Used at `font-size` unchanged |
| No configured family covers it | Automatic fallback | Scaled to match the primary font |

The automatic fallback walks `%SYSTEMROOT%\Fonts` and then
`%LOCALAPPDATA%\Microsoft\Windows\Fonts`, and takes the first font file
that contains the character. It does not consider whether the font is
monospaced, which language it targets, or how well it pairs with the primary
font, so which font you get depends on what is installed and in which order
the directory lists it.

A face chosen that way is resized so that its ideograph width matches the
primary font, which keeps full-width characters inside two cells. A face you
named in `font-family` is never resized; Gooztty uses your choice as it is.
That means an explicitly named font is not made to fit the cell grid, and a
mismatched pair can look unbalanced.

For predictable results, name a font that covers both scripts, or name the
Japanese font explicitly as a second family:

```
font-family = "Moralerspace Neon"
```

```
font-family = "Cascadia Code NF"
font-family = "Yu Gothic UM"
```

Fonts designed to pair Latin and Japanese at the same optical size, such as
Moralerspace or PlemolJP, need no further adjustment. Two unrelated fonts may
not line up, and there is no setting that rescales a font you named.

`font-codepoint-map` does not avoid the resizing: faces mapped that way are
treated like automatic fallbacks.

The current `.ic_width` behavior was measured on Windows with Cascadia Code NF
as the primary font. BIZ UDGothic at 12, 16, and 24 pt and at 100%, 125%,
150%, and 200% display scaling kept full-width characters on two cells without
baseline errors or top/bottom clipping. Automatic BIZ UDGothic appeared larger
than the same face named explicitly; Noto Sans JP at 16 pt showed little
visible difference between the two paths. Moralerspace Neon measured the
primary-with-ideographs branch: Moralerspace supplied the `水` glyph used for
its real `ic_width`, while missing `龘` fell back to `微軟正黑體`.
Automatic and explicitly configured `微軟正黑體` had nearly identical apparent
size, retained two-cell placement, and showed no clipping. This is the intended
upstream configured-versus-fallback distinction, so the Windows fork does not
add a separate adjustment setting.

Related work is tracked separately: unmatched configured names
([1](https://github.com/fukuyori/ghostty/issues/1)), configured style selection
([2](https://github.com/fukuyori/ghostty/issues/2)), the measured size
adjustment behavior ([3](https://github.com/fukuyori/ghostty/issues/3)), and
Windows system fallback selection
([42](https://github.com/fukuyori/ghostty/issues/42)).

## Keyboard Layouts

Because the physical key for a key binding is determined from the scan code,
`physical:` bindings and the default split navigation keys match by key
position even on Japanese or European layouts. Character bindings such as
`ctrl+;` are matched against the character that the key produces without
modifiers on the current layout. Only key messages posted by automation tools
without a scan code fall back to the US-layout-equivalent virtual key table.
Unit tests and regression tests pass on real hardware with a Japanese layout,
but other layouts have not been verified on real hardware.

Starting with `1.3.2-windows.8`, Shift characters such as `:` and `?` are
handled correctly in Kitty keyboard disambiguation mode. Actual `:`, `?`,
and `!` input in antigravity was confirmed by the repository owner.

Starting with `1.3.2-windows.9`, numpad digits and operators are entered once.
Earlier previews sent each of them twice (`0` arrived as `00`). With NumLock
off the numpad works as navigation keys, as before.

## Manual Acceptance Check for the Windows Shell

The automated regression test checks the window structure required to be a
target of snapping, Alt+Tab, and the taskbar. Appearance and actual operation
on the Windows shell are recorded with the following manual test. When only
reviewing the items, Gooztty is not launched.

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

The script does not touch the user configuration; it uses a dedicated Gooztty
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
build that sets the large and small Gooztty icons on the window class, and it
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
fullscreen, `Alt+F4` closes the window, and `Ctrl+Shift+Q` quits Gooztty.

## Terminal Search and Working Directories (1.3.2-windows.11)

Press `Ctrl+Shift+F` to open the current pane's search bar. It searches
scrollback as well as the visible screen. Enter moves to the next match,
Shift+Enter to the previous match, and Escape closes the bar and returns
focus to the terminal. Each pane retains its own query. Native controls
provide text editing and IME input; physical IME acceptance testing remains
outstanding. The `search_selection` binding can start with selected text.

Working-directory inheritance now accepts OSC 7 `file://localhost/C:/...`
and `file:///C:/...` notifications, including percent-encoded spaces and
Unicode. The local computer's hostname is also accepted case-insensitively.
The `window-inherit-working-directory`, `tab-inherit-working-directory`,
and `split-inherit-working-directory` settings control each creation mode.
Without a shell notification, Gooztty only knows the startup directory.

PowerShell can emit a notification for its current native filesystem path:

```powershell
[Console]::Write("$([char]27)]7;$([Uri]::new($PWD.ProviderPath + '\').AbsoluteUri)$([char]7)")
```

This is a one-time notification, not automatic prompt integration. Remote
hosts, UNC/device paths, WSL paths such as `/home/user`, and MSYS paths such
as `/c/work` are not translated or inherited. Native paths such as `/C:/work`
are supported. Emit a new notification after changing directories.

Terminal mouse shapes now use the configured Windows system pointers, with
the nearest available shape for cursors Windows does not provide.
`mouse-hide-while-typing` hides the pointer over the terminal and restores it
on mouse movement; native search controls retain their own pointers.

With `right-click-action = context-menu`, right-clicking text selects its
word or link and opens the menu. On a row containing only empty cells,
spaces, or tabs, the menu opens without creating a new selection. An
existing selection is retained, including when right-clicking inside it.
Double-click word selection is unchanged.

## Accessibility

The custom-drawn tab bar is exposed as an MSAA page tab list. Each tab's name,
position, selection state, previous/next navigation, hit testing, and default
action can be obtained.

API-level inspection and automated regression tests are complete, but speech
output with Narrator and NVDA is still under acceptance verification.

## Command Palette, Scrollbars, and File Drop (1.3.2-windows.12)

Press `Ctrl+Shift+P` to open the command palette. It lists configured
`command-palette-entry` actions and the open terminal panes. Type to filter
the list, select an item, and press Enter to run it; Escape closes the dialog.
Actions unavailable in the Windows runtime are omitted. The list is rebuilt
when opened, so a configuration reload is reflected the next time it opens.

With `scrollbar = system` (the default), each pane uses a slim translucent
overlay scrollbar. It appears while scrolling or when the pointer moves to
the pane's right edge, then hides after the pointer leaves. It does not reduce
terminal width. Set `scrollbar = never` to disable it. The thumb follows the
same scrollback position as wheel, keyboard, and search navigation.

Drag files or directories from Explorer onto a terminal pane to insert their
quoted paths. The pane's configured startup shell determines quoting for
PowerShell or cmd; the drop does not press Enter. A cmd drop containing `%` or
`!` is rejected with a warning. Unsupported startup shells also show a
warning. A shell switched after startup is not detected by this setting.
In a real Explorer check, an elevated Gooztty window did not accept a drop
from normal Explorer. Use a non-elevated Gooztty window for Explorer drops.

These controls are under development. The [feature plan](windows-upstream-feature-plan.md)
records their remaining input, DPI, and accessibility checks.

## Quick Terminal and Global Keybindings (1.3.2-windows.16)

A keybinding with the `global:` prefix works while another application is in
front. Bind `toggle_quick_terminal` to show and hide the quick terminal from
anywhere; there is no default binding:

```ini
keybind = global:ctrl+grave_accent=toggle_quick_terminal
```

Windows registers each global binding with `RegisterHotKey`. A global binding
that cannot be registered is disabled: it does not work anywhere, including
inside Gooztty, and the configuration error dialog lists it with the reason
at startup, on configuration reload, and after a keyboard layout change makes
it unusable. This applies to bindings with more than one action, to key
combinations already registered by another application or reserved by
Windows (such as `Win+L`), and to the keys below. Left and right modifiers are
not distinguished. Write the keys that are pressed: character keys are
translated with the current keyboard layout, and a character that needs Shift
or AltGr on that layout (such as `:` on a US layout) is disabled; write
`ctrl+shift+;` instead of `ctrl+:`. Keys Windows cannot tell apart by
virtual key are disabled too: numpad Enter (same as Enter) and the
numpad digits and decimal key (their key code depends on NumLock). Page Up,
Page Down, Home, End, Insert, Delete, and the arrow keys are registered, and
also fire from the numpad while NumLock is off. Holding the combination
performs the action once.

The quick terminal is a single window without a title bar, taskbar button, or
Alt+Tab entry, and stays above other windows while shown. Its shell and splits
keep running while it is hidden. Closing the window or its last running pane
hides it; it is destroyed when its last shell exits or when all windows are
closed, and the next toggle starts a new one. It has no tabs, is not saved by
`window-save-state`, and is skipped by `toggle_visibility` and `goto_window`.
When it is hidden explicitly, the window that was in front before it appeared,
including another Gooztty window, is activated again if the quick terminal
still had the focus.
Shells in the quick terminal get `GOOZTTY_QUICK_TERMINAL=1`.

| Setting | Windows behavior |
|---|---|
| `quick-terminal-position` | Edge or center of the monitor work area (the desktop without the taskbar) |
| `quick-terminal-size` | As upstream; sizes in `px` are device pixels. For `center`, a single size sets the width on a landscape monitor and the height on a portrait one, which is what upstream computes |
| `quick-terminal-screen` | `main` is the primary monitor, `mouse` the monitor under the pointer when shown; `macos-menu-bar` behaves like `main`. Changing it in a reload moves a shown quick terminal |
| `quick-terminal-autohide` | Hides when another window, including another Gooztty window, is activated. Dialogs owned by the quick terminal do not hide it. Default `false` |
| `quick-terminal-keyboard-interactivity` | `on-demand` takes focus when shown; `none` does not take keyboard focus when shown, clicked, or split, and a reload to `none` gives up the focus it has; `exclusive` behaves like `on-demand`, because Windows cannot withhold input from other applications |
| `quick-terminal-animation-duration` | Not supported; the window appears and hides immediately |
| `quick-terminal-space-behavior`, `gtk-quick-terminal-*` | Ignored. Switching virtual desktops leaves the quick terminal on the desktop where it was shown |

Maximize, fullscreen, decoration, and resize actions do not apply to the quick
terminal. Its placement is recomputed on configuration reload, DPI change, and
monitor or taskbar changes.

With at least one registered global keybinding and
`quit-after-last-window-closed = false` (the Windows default), Gooztty keeps
running after its last window closes so the binding can still open the quick
terminal; use the `quit` action to exit. Without a registered global
keybinding, Gooztty exits after its last window closes, as before. If only a
hidden quick terminal remains, it could never be shown again, so Gooztty
quits; when a process is still running it asks first, and declining shows the
quick terminal again. The
`+toggle-quick-terminal` command is not supported on Windows.

## Desktop Notifications and Bell (1.3.2-windows.16)

Programs can show Windows toast notifications with OSC 9 and OSC 777
(`desktop-notifications = true`, the default). A program's notification is
not shown while its pane has keyboard focus in the foreground window.
Clicking a notification brings its pane to the front, selecting its tab and
showing a hidden quick terminal or clearing a split zoom that hides it.
Notifications of a closed pane are removed from Notification Center, and
each Gooztty process removes the notifications it showed when it exits,
because a click after exit cannot reach it. When notifications are turned off
for Gooztty, for the user, or by policy, nothing is shown and the reason is
logged once; a toast that Windows later fails to show is logged with its
error. Windows can still hide an accepted toast without telling Gooztty, for
example during Do Not Disturb.

Gooztty registers `fukuyori.Gooztty` for notifications under
`HKCU\Software\Classes\AppUserModelId` when it first shows one; the process
and its shortcuts keep their normal identity, so taskbar grouping and pins
do not change. The installer removes that registration and the per-app
notification settings Windows keeps for it on uninstall, for the user who
runs the uninstaller; other users of a machine-wide installation keep theirs,
and a ZIP copy leaves them in place.

`notify-on-command-finish` (`never`, `unfocused`, `always`),
`notify-on-command-finish-action` (`bell`, `notify`), and
`notify-on-command-finish-after` work as upstream. A command counts when it
runs at least the configured time. The notification is titled "Command
Succeeded" or "Command Failed" and reports the duration and exit code; a
command end reported without an exit code counts as exit code 0. This needs a shell that reports command start and end with
OSC 133, such as the bundled Bash integration or a prompt configured to emit
it; the automatic PowerShell integration does not.

BEL follows `bell-features`: `system` plays the Windows default sound,
`attention` (default on) flashes the taskbar button until the window comes to
the front, and `title` (default on) shows a bell before the tab and window
title until the pane is focused or typed in. `audio` and `border` are not
supported on Windows.

OSC 9, OSC 777, and BEL reach Gooztty only through the bundled
`conpty.dll`/`OpenConsole.exe`. The ConPTY built into Windows drops them; OSC
133 passes through either.

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
  machine. The ncurses build used by MSYS2, Git Bash, and Cygwin reads the
  Windows-style `TERMINFO` path Gooztty sets only from a working directory on
  the drive Gooztty is installed on, so from 1.3.2-windows.10 Gooztty also
  registers the entry in `%USERPROFILE%\.terminfo`, which is found from any
  drive. That covers Git Bash. Cygwin, a standalone MSYS2, a `HOME` pointed
  elsewhere, WSL, and remote hosts keep their home directory somewhere else
  and still need the one-time step described in "Terminal Type and terminfo".
- The effect and quality of `background-blur` vary with the Windows and GPU
  configuration.
- There is no automatic update. A signed installer is published as a release
  asset from `1.3.2-windows.4` on.
- There is no GUI equivalent to the macOS SwiftUI settings window or the Linux
  GTK integration.
- The Sentry crash reporter is not available. It is disabled by default
  outside macOS and returns early on Windows even when enabled at build time,
  so no crash reports are written and `gooztty +crash-report` lists nothing.
  Use the startup diagnostic log described above instead.

For details on the implementation status and verification items, see the
[Windows production-readiness roadmap](windows-roadmap.md).
