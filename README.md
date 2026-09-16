<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty
</h1>
  <p align="center">
    Native Ghostty for Windows — a work-in-progress Windows application fork.
    <br />
    Win32, D3D11, DirectComposition, native tabs, and split panes.
    <br />
    <a href="#ghostty-for-windows">Windows Build</a>
    ·
    <a href="docs/windows.md">User Guide</a>
    ·
    <a href="docs/windows-release-notes.md">Release Notes</a>
    ·
    <a href="docs/windows-changelog.md">Changelog</a>
    ·
    <a href="docs/windows-roadmap.md">Roadmap</a>
    ·
    <a href="#relationship-to-upstream">Upstream</a>
  </p>
</p>

## Ghostty for Windows

This repository is a development fork that brings Ghostty to Windows as a
native application suitable for daily use. Rather than waiting for Windows
support to land upstream, the native implementation and its verification
are developed on the `windows` branch.

Highlights of the Windows build:

- Native Win32 windows, title bar, and tab bar
- D3D11 and DirectComposition rendering, background opacity, and automatic
  recovery after GPU device loss and power resume
- Multiple windows, native tabs, and nested split panes
- Tab management, reordering, and split-divider resizing by keyboard and mouse
- Windows IME, clipboard, and URL and file handling
- Per-Monitor V2 DPI, high contrast, and MSAA tab information
- Loading and reloading `%LOCALAPPDATA%\ghostty\config.ghostty`
- A portable release build script and an Inno Setup installer script with
  code signing support
- Build version information shared by the CLI and the Windows file properties

Build and run:

```powershell
zig build
./zig-out/bin/ghostty.exe
```

Portable release build:

```powershell
./scripts/build-release.ps1
./zig-out/release/bin/ghostty.exe
```

See the [Windows release notes](docs/windows-release-notes.md) for preview
versions, contents, and verification results, and the
[changelog](docs/windows-changelog.md) for what changed between them. To reproduce a specific preview,
replace `<version>` below with the version listed in the release notes
(without the tag's `v` prefix):

```powershell
$releaseVersion = '<version>'
git checkout "v$releaseVersion"
./scripts/build-release.ps1 -AdditionalZigArgs "-Dversion-string=$releaseVersion"
```

Building the Inno Setup installer uses the release executable's version
automatically (`-Sign` signs the executable, the installer, and the uninstaller):

```powershell
./scripts/build-installer.ps1
./scripts/build-installer.ps1 -Sign   # certificate subject from $env:CODESIGN_CERT
```

Repeated regression runs against the release build:

```powershell
./scripts/test-windows-soak.ps1 -Iterations 20
# Include controlled GPU resource recovery and power resume
./scripts/test-windows-soak.ps1 -Iterations 20 -DelaySeconds 0 `
    -TestGpuRecovery -TestPowerResume
```

Manual Windows shell acceptance checks:

```powershell
./scripts/test-windows-shell.ps1 -ListOnly
./scripts/test-windows-shell.ps1
# Real sleep and resume only when selected explicitly
./scripts/test-windows-shell.ps1 -CheckId power-resume
```

The Windows build is a preview. Basic operation has been verified on
Windows 11; Windows 10, 144 and 192 DPI, keyboard layouts other than
Japanese, real sleep and resume, and long-running sessions have not been
verified yet. An installer can be built but is not bundled with the published
preview, and there is no automatic update. Background opacity works, but
`background-blur` quality depends on the environment, so leaving it disabled
is recommended for now.

### Work Phases

Windows support is developed in six phases. The percentages are rough
estimates of the work involved.

| Phase | Scope | Status |
|---|---|---:|
| 1 | Core runtime: startup, input, IME, clipboard, DPI | Done |
| 2 | Rendering: D3D11, DirectComposition, background opacity | Done |
| 3 | Window features: multiple windows, fullscreen, config reload | Done |
| 4 | Split panes: create, navigate, resize, zoom | Done |
| 5 | Windows GUI polish: tabs, mouse handling, DPI, accessibility | ~98% |
| 6 | Release quality: diagnostics, release verification, hardware tests, distribution | ~97% |

Overall progress is about 98%. Current work is the environment-specific GUI
verification of phase 5 and the release-quality work of phase 6 in parallel.

Configuration, default keybindings, diagnostics, and known limitations are in
the [Windows user guide](docs/windows.md); implemented items and remaining
work are in the [Windows roadmap](docs/windows-roadmap.md).

## Crash Reports and Diagnostics

Ghostty's Sentry-based crash reporter is not available in the Windows build.
It is off by default for every platform except macOS
(`src/build/Config.zig`), and the reporter returns early on Windows even when
built with `-Dsentry=true` (`src/crash/sentry.zig`). No crash directory is
created, and `ghostty +crash-report` lists nothing.

Use the startup diagnostic log instead. The executable is a GUI subsystem
binary, so its standard output and standard error are not attached to the
console that launched it; the script below redirects both to files and
reports the exit code.

```powershell
.\scripts\run-windows-diagnostics.ps1
.\scripts\run-windows-diagnostics.ps1 -AdditionalArguments @('+validate-config') -Wait
```

Logs land in `zig-out\logs`. To capture a session you start yourself, set
`GHOSTTY_LOG=stderr=true` and redirect standard error. D3D11 presentation
failures, device removal reasons, GPU resource recovery, and power
suspend and resume notifications are all recorded there.

## Relationship to Upstream

This repository is a fork of
[`ghostty-org/ghostty`](https://github.com/ghostty-org/ghostty), which
maintains Ghostty itself and its macOS and Linux applications. Only the
Windows application is developed here, on the `windows` branch; upstream
changes are pulled in from time to time.

For everything that is not Windows-specific, use the upstream resources:

- [About Ghostty](https://ghostty.org/docs/about)
- [Documentation](https://ghostty.org/docs), including configuration
  reference and keybindings, which apply to this build as well
- [Downloads](https://ghostty.org/download) for macOS and Linux
- [Contributing](https://github.com/ghostty-org/ghostty/blob/main/CONTRIBUTING.md)
  and [Developing](https://github.com/ghostty-org/ghostty/blob/main/HACKING.md)
  for upstream development

Report anything specific to the Windows build in this repository's issues.

> [!IMPORTANT]
>
> **Upstream runs a strict contribution process, and this fork does not take
> part in it.**
>
> - **Vouching is required.** First-time contributors must open a vouch
>   request discussion and be approved by a maintainer. Pull requests from
>   contributors who have not been vouched are closed automatically.
> - **You must understand your own code.** Upstream asks that you not
>   contribute if you cannot explain a change and how it interacts with the
>   rest of the system without the help of an AI tool.
> - **All AI usage must be disclosed**, naming the tool and the extent of the
>   assistance. See the
>   [AI Usage Policy](https://github.com/ghostty-org/ghostty/blob/main/AI_POLICY.md).
> - **Repeated rule-breaking or low-quality work leads to denouncement**,
>   which is recorded publicly.
>
> This fork is developed with AI assistance, so **no issues or pull requests
> are opened upstream from here.** Everything stays in this repository. If you
> want to raise something with upstream, do it yourself, on your own account,
> under the rules above.
>
> The full text is in
> [CONTRIBUTING.md](https://github.com/ghostty-org/ghostty/blob/main/CONTRIBUTING.md).
> None of it applies to issues and pull requests on this fork.

## License

MIT. See [LICENSE](LICENSE). The upstream copyright notice is retained.
