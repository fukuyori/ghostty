# Windows Rebranding and Coexistence Plan

- Created: 2026-09-23
- Scope: the `windows` branch of `fukuyori/ghostty`
- Status: Planning. The product name is ghoultty and an icon candidate has been selected. Legacy command migration and other decisions remain open; code changes and distribution validation have not begun.
- Tracking: [Issue #31](https://github.com/fukuyori/ghostty/issues/31), [Windows roadmap](windows-roadmap.md)

## 1. Purpose and Boundaries

Give this Windows fork a distinct user-facing name and icon in response to the Ghostty team's request recorded in [noctty #119](https://github.com/amanthanvi/noctty/issues/119). This plan does not determine trademark suitability. The chosen name is ghoultty; confirm the name and artwork against the request before distribution.

The product must be able to coexist with a future official Windows Ghostty: both applications should be installable and runnable at the same time and able to use a shared Ghostty configuration file. The official Windows release's packaging and config lookup are not yet known, so testing against that actual release remains a final check. Upgrades from existing previews and migration for CLI users are also in scope.

This plan does not authorize implementation, a GitHub repository rename, or packaging. Preserve historical release records and upstream copyright and license notices.

## 2. Decisions and Open Questions

| Item | Decision or current direction | Remaining work |
|---|---|---|
| Product name | ghoultty | Apply it to Windows display and distribution names; confirm alignment with the naming request before release |
| Executable | Rename to `ghoultty.exe` | Align builds, CLI, signing, installer, and verification scripts |
| CLI | Keep existing options and subcommands available through the new executable | Decide the `+version` display, legacy invocation, and migration notice |
| Icon and logo | Apply the selected candidate PNG when implementing the ghoultty rename | Produce required sizes and formats for EXE, installer, README, and shortcuts; inspect small-size legibility |
| Repository name and URL | Rename only after implementation and integration. The destination is undecided; `fukuyori/ghoultty` is a candidate | Choose the destination; update `origin`, issues, user links, and installer URLs; verify access from the old URL |
| Legacy `ghostty.exe` | Links, aliases, and other compatibility options remain under consideration | Compare collision with the official app, old scripts, ZIP distributions, upgrades, and removal |
| Install directory and group | Use a dedicated new-name directory for both fresh and upgraded installations, never the old Ghostty directory; design handling of the old directory | Prevent reuse of the old directory and group with `UsePreviousAppDir` / `UsePreviousGroup`; determine migration of old files, shortcuts, and PATH entries |
| AppId | Proposed: keep this fork's existing GUID for upgrades | Verify upgrades and separate registration from the official app; compare identifiers when the official release exists |
| Shared-code display name | Proposed: change only for Windows targets | Check effects on macOS/Linux and upstream merges |

The repository owner chose the [ghoultty icon candidate](../dist/windows/ghoultty-icon-candidate.png) for use when implementing the name change. Keep the current `ghostty.ico` until then. The PNG is a transparent master; create and verify ICO sizes and their actual display as part of the rename.

Treat legacy command compatibility as a separate decision. Do not put `ghostty.exe` on PATH by default without a coexistence test: it could intercept commands intended for the official app. PATH resolves directories, and an environment variable alone cannot create the old command name. Shell-specific aliases cannot cover PowerShell, cmd, and explicit EXE paths together.

## 3. Shared Technical Identifiers and Separate Product Identifiers

| Keep | Reason and verification |
|---|---|
| `TERM=xterm-ghostty` and the terminfo entry | Preserve terminal capabilities and resolution on remote hosts; check with the renamed application |
| User copy at `%USERPROFILE%\.terminfo\78\xterm-ghostty` | The current app installs it only when absent. Neither app should overwrite or remove the other's entry; check version differences |
| `ghostty/config.ghostty`, legacy `ghostty/config`, and existing lookup order | Continue reading existing settings and allow sharing with the future official app |
| Upstream config keys, values, defaults, and actions | Keep the shared file readable by both apps; do not require fork-only keys in that file |
| `GHOSTTY_*` and shell integration | Preserve protocol behavior; do not set machine-wide environment variables that redirect the official app's lookup |
| `share/ghostty`, `share/terminfo`, and resource lookup | Preserve layout and loading; each app keeps its own resources in a separate install directory |
| Upstream attribution, LICENSE, and third-party notices | Preserve provenance and redistribution terms |

Separate the executable, display name, icon, shortcuts, distribution filenames, install location, and uninstall display name. Sharing a config file does not guarantee that both versions understand every key. Check supported keys and diagnostics with actual versions before promising full compatibility. Do not automatically rewrite or move settings; specify any needed migration separately.

## 4. Implementation Inventory

| Area | Current locations | Work |
|---|---|---|
| Build name | `src/build/GhosttyExe.zig` | Rename the EXE only for Windows; minimize shared-core changes |
| Windows resources | `dist/windows/ghostty.rc`, `dist/windows/ghostty.ico`, `dist/windows/ghoultty-icon-candidate.png` | Change FileDescription, OriginalFilename, and ProductName; create and apply icon sizes from the selected PNG |
| Win32 UI | `src/apprt/win32/App.zig`, `Tab.zig`, `TabBar.zig`, `TabBarAccessibility.zig`, `Surface.zig` | Update titles, errors, permission dialogs, accessibility names, and related tests |
| Internal identifiers | Window class names in `App.zig` and similar identifiers | Review `GhosttyWindow` references in `test-windows-context-menu.ps1` and `test-windows-parity.ps1`; change only where needed |
| CLI output | `src/cli/version.zig`, `scripts/build-release.ps1` | Align Windows display name and version parsing; check effects on other OSes |
| Release tooling | `scripts/build-release.ps1`, `scripts/test-windows-context-menu.ps1`, `scripts/test-windows-parity.ps1`, and related scripts | Update output EXE, resources, version handling, and default test EXE paths |
| Installer | `dist/windows/ghostty.iss`, `scripts/build-installer.ps1` | Align display, files, icons, PATH, signing targets, output name, upgrades, and removal |
| Documentation | `README.md`, `docs/windows.md`, `docs/version-update-checklist.md`, related Windows docs | Update current instructions and attribution; state in the README's upstream relationship section that this is an unaffiliated fork. Do not rewrite historical release records |
| Distribution URLs | Installer `AppPublisherURL` and related fields, README, docs | Update to the new URL after the repository rename; verify links and redirects |

Old-name strings also include protocol, config, resource, copyright, historical, and test identifiers. Classify each occurrence rather than replacing them all.

## 5. Work Sequence and Exit Criteria

Establish the branch workflow first and implement on `rebrand/ghoultty` from `windows`. Rename the GitHub repository only after implementation and integration. The work branch, integration, and rename have not happened.

1. **Branch workflow:** Keep `main` as a mirror of upstream `main` and `windows` as the Windows development and release branch. Inspect history and the working tree, then create `rebrand/ghoultty` from `windows`. Bring upstream updates into `main` and explicitly integrate them into `windows`. Do not force-push.
2. **Resolve specifications:** Record ghoultty and the selected icon in #31; decide legacy command scope, old-directory migration, and `+version`. Resolve any uncertainty about the naming request before distribution.
3. **Prepare implementation:** Record the old installation, PATH, shortcuts, and config state. Inventory old and new filenames and affected scripts.
4. **Change Windows build and UI:** Update EXE, icon, resources, Win32 strings, and CLI output. Keep non-Windows build names and output unchanged.
5. **Change distribution and migration:** Update Release and Inno scripts, signing targets, layout, upgrade, and removal. Do not reuse the old Ghostty directory. Design cleanup of the fork's old files, shortcuts, and PATH entries. Touch only this fork's old installation, not shared config or official-app files.
6. **Document and verify during development:** Update current instructions, attribution, and migration differences. Record results and open checks in #31, the roadmap, and changelog. Put actual distribution results in release notes only when publishing.
7. **Integrate:** Once implementation and development checks pass, integrate the work branch into `windows`. Integration and pushing require a separate request.
8. **Rename the repository:** As the final change after implementation and integration, choose the destination and rename `fukuyori/ghostty` on GitHub. Verify old and new URLs, issues, and `origin` fetch/push targets; update documentation and installer URLs. Keep accidental pushes to `upstream` and `mattn` disabled.
9. **Pre-release acceptance:** On the final candidate with the renamed URL, perform one real-machine pass for fresh install, upgrade from the old version, and uninstall. Do not repeat these at every development step.

Small review increments are fine, but do not treat a distribution with mixed old and new product names as complete.

## 6. Acceptance Verification

During development, verify the source, UI, and CLI affected by each change. Fresh install, upgrade, and uninstall on a real machine are required once, after the repository rename and distribution URL update, when the final release candidate is ready.

| Scope | Required checks |
|---|---|
| Source and build | Relevant Zig tests, Debug build, unchanged non-Windows names, `git diff --check` |
| New EXE | Startup, `--version` and main CLI commands, file properties, icon, resource lookup, clean exit |
| Actual UI | Title, taskbar, errors, accessibility names, multiple windows, DPI; legibility of 16/32/48-pixel icons |
| Shared config | Existing `%LOCALAPPDATA%\ghostty\config.ghostty`, `XDG_CONFIG_HOME` precedence, reload, and shared settings in both apps |
| Terminal compatibility | TERM, terminfo, shell integration, `GHOSTTY_*`, existing SSH procedure; neither app overwrites or deletes the user `xterm-ghostty` entry |
| Command resolution | PowerShell, cmd, PATH, explicit EXE paths, and collision if legacy compatibility is provided |
| Distribution | Release tree and ZIP contents, staged EXE, signatures on Inno installer and uninstaller, displayed name and version |
| Future official-app coexistence | Once available, install both and check launch, config, resources, PATH, and removal |

### One Real-Machine Pass Before Release

Use the final release-candidate installer for these three paths in one acceptance pass, not at every implementation step.

| Path | Checks |
|---|---|
| Fresh install | New-name directory, shortcuts, PATH, launch, config loading; do not install into a Ghostty directory |
| Upgrade | Upgrade from `1.3.2-windows.11` without reusing the old Ghostty directory; migrate old EXE, shortcuts, and PATH while preserving config |
| Uninstall | Clean up old and new fork-owned files, shortcuts, PATH entries, and registry entries; preserve shared config, terminfo, and other apps |

A successful build alone is insufficient. Check actual EXE display, signatures, and config loading. Record fresh install, upgrade, and removal outcomes separately in this single pre-release pass. The repository owner performs real-machine operations and records the tested version, install method, outcomes, and leftovers. Acceptance is incomplete until this is done. Package creation follows the authorization in effect at that time. If the official app is unavailable, distinguish a simulated coexistence precheck from testing with its actual release, and track the latter as unverified.

## 7. Update Rules

When naming or compatibility policy changes, update #31, this plan, and the priorities and verification entries in the [roadmap](windows-roadmap.md) together. During implementation, update the [Windows user guide](windows.md), [version update checklist](version-update-checklist.md), and [changelog](windows-changelog.md). Keep past release notes and changelogs as records of the product name used at the time.
