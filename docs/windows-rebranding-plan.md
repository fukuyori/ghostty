# Windows Rebranding Plan

- Created: 2026-09-23
- Scope: the `windows` branch of `fukuyori/ghostty`
- Status: Planning. The product name is gozitty (changed from ghoultty on 2026-10-11), and a new icon will be created for it. On 2026-10-11 the coexistence and shared-configuration requirement was dropped: the renamed application keeps no `ghostty` name in its files, configuration, environment, or terminal identifiers. Smooth upstream synchronization after the rename takes priority (Section 1.1). Implementation starts only after `windows` has been synchronized with upstream (Phase 0). The `rebrand/gozitty` work branch exists locally and has not been pushed; it will be recreated after that synchronization. The naming decisions are complete; code changes and distribution validation have not begun.
- Tracking: [Issue #31](https://github.com/fukuyori/ghostty/issues/31), [Windows roadmap](windows-roadmap.md)

## 1. Purpose and Boundaries

Give this Windows fork a distinct name and icon in response to the Ghostty team's request recorded in [noctty #119](https://github.com/amanthanvi/noctty/issues/119). This plan does not determine trademark suitability. The chosen name is gozitty; confirm the name and artwork against the request before distribution.

The earlier plan (2026-09-23) required coexistence with a future official Windows Ghostty and a shared Ghostty configuration file. On 2026-10-11 the repository owner dropped that requirement, because the Ghostty project does not plan to ship a Windows GUI build: on 2026-10-10 its maintainer stated in [ghostty-org/ghostty#14608](https://github.com/ghostty-org/ghostty/pull/14608) that Windows support for core Ghostty is no longer a priority and that forking is the proper response for a Windows GUI. The renamed application therefore leaves no `ghostty` name in what it installs or exposes: executable, resources, configuration paths, terminfo and `TERM`, environment variables, window classes, and terminal-reported identifiers.

The intended exceptions are upstream copyright, license, and attribution notices, which must be preserved; historical release records; and identifiers inside the source code that are shared with upstream, which are kept to stay in sync with upstream (decided 2026-10-11, Section 2).

Gozitty is installed as a separate application from the existing Ghostty previews, not as an upgrade (new AppId, decided 2026-10-11). Migration for CLI users is in scope. Existing user settings are not migrated automatically; users copy them to the new location themselves (decided 2026-10-11).

This plan does not authorize implementation, a GitHub repository rename, or packaging.

### 1.1 Upstream Synchronization Priority

The most important requirement of this rebrand is that upstream changes can still be merged smoothly after the rename (decided 2026-10-11). Every rename choice is judged by its effect on upstream merges, and the following rules apply.

1. **Keep the new names in one fork-owned file.** Define the product name, `TERM` name, environment variable prefix, resource directory name, and similar values in a single fork-owned module (for example `src/brand.zig`). Shared upstream files reference that module with the smallest possible change, ideally one line per site.
2. **Prefer build-time or output-time rewriting to source edits.** Shell integration scripts and CLI help text stay as upstream has them and are rewritten when installed or generated. Apply the same approach wherever it avoids editing shared source.
3. **Do not rewrite upstream test expectations unless a test fails.** Change a shared test only when the rename actually breaks it.
4. **Check the shared-code diff at every synchronization.** Shared files already carry Windows adaptations from before the rename. Measure the rename against the synchronized `windows` baseline: after each upstream merge, confirm that the rename-related part of the shared-code diff stays limited to the rename sites, and record the conflicts that the rename caused.
5. **Synchronize before renaming.** Merge upstream into `windows` first, so the rename is built on current upstream code and its conflicts are not mixed with pending upstream changes.

Fork-only code (`src/apprt/win32/`, `dist/windows/`, `scripts/`) is not shared with upstream and can be renamed freely.

## 2. Decisions and Open Questions

| Item | Decision or current direction | Remaining work |
|---|---|---|
| Product name | gozitty (replaces ghoultty, 2026-10-11). The display name is written **Gozitty** (decided 2026-10-11); file, command, `TERM`, and other identifiers use lowercase `gozitty` | Apply it to Windows display and distribution names; confirm alignment with the naming request before release |
| Executable | Rename to `gozitty.exe` | Align builds, CLI, signing, installer, and verification scripts |
| CLI | Keep existing options and subcommands available through the new executable. `+version` prints `Gozitty <version>` on its first line; the version numbering continues the current `X.Y.Z-windows.N` scheme (decided 2026-10-11) | Keep the first-line format that the release script parses. Remove the OSC 8 commit link that `+version` adds to its first line on a terminal; it points to the upstream repository (decided 2026-10-11) |
| Icon and logo | Create a new icon for gozitty; the ghoultty candidate PNG is not used | Design the icon; produce required sizes and formats for EXE, installer, README, and shortcuts; inspect small-size legibility |
| Repository name and URL | Keep `fukuyori/ghostty` for now (decided 2026-10-11). The rebrand does not include a repository rename | If a rename is decided later, choose the destination; update `origin`, issues, user links, and installer URLs; verify access from the old URL |
| Official Windows Ghostty coexistence | Dropped (2026-10-11); the configuration is no longer shared | None |
| Configuration location | Move away from `ghostty`: a `gozitty` directory under `%LOCALAPPDATA%` (decided 2026-10-11) | The file name is `config.gozitty` (decided 2026-10-11); with `XDG_CONFIG_HOME` the path is `$XDG_CONFIG_HOME/gozitty/config.gozitty`. Existing `ghostty/config.ghostty` and `ghostty/config` settings are not migrated: users copy them themselves (decided 2026-10-11); document the copy step. The installer and uninstaller leave `%LOCALAPPDATA%\ghostty` untouched so the old settings remain available for the manual copy (decided 2026-10-11) |
| `TERM` and terminfo | Rename `xterm-ghostty` to `xterm-gozitty` (decided 2026-10-11) | Use one branded terminfo definition for the generated entry, the `+ssh` route, and the XTGETTCAP `TN` response, and change the installed source file name together with the resource-detection sentinel in `src/os/resourcesdir.zig` (`terminfo/ghostty.terminfo` on Windows). Create the new user entry under `%USERPROFILE%\.terminfo` beside the old `xterm-ghostty` entry; never rename, overwrite, or delete the old entry. Remote hosts and WSL: rename the existing routes (`+ssh` with `ssh-terminfo` / `ssh-env`, and the documented WSL `tic` step); redesign them if they do not work on Windows. Verify during implementation |
| Environment variables | Rename `GHOSTTY_*` and other `ghostty` values such as `TERM_PROGRAM` to the `GOZITTY_` prefix and `TERM_PROGRAM=gozitty` (decided 2026-10-11) | Shell integration: keep the scripts in the repository as upstream has them and rename `ghostty` names when the build installs them into `share/gozitty` (decided 2026-10-11). Gather the Zig-side variable names into one constant. Rewrite installed file names, exported shell identifiers (for example the Nushell module `ghostty`), loader paths in `src/termio/shell_integration.zig` (`ghostty.bash`, `use ghostty *`), and injected commands together through the name module, and verify that the renamed files are actually loaded. Cover environment consumers as well as producers (`GHOSTTY_LOG`, `GHOSTTY_PAGER`, the `zig build run` environment in `build.zig`), and decide how `GHOSTTY_*` variables inherited from a parent terminal are handled when Gozitty is started from the old Ghostty |
| Resource layout | Rename `share/ghostty` to `share/gozitty` (decided 2026-10-11) | Update resource lookup, themes, and shell integration paths |
| Terminal-reported identifiers | Rename `ghostty` in responses such as XTVERSION (decided 2026-10-11) | Inventory every response and protocol string that carries the name |
| Window classes and other Win32 identifiers | Rename `Ghostty*` classes and the IPC named-pipe prefix `fukuyori.ghostty.win32-ipc` to `fukuyori.gozitty.win32-ipc` (decided 2026-10-11) | Update tests and scripts that look up the class names; verify that each product's CLI reaches only its own running instances |
| CLI help and configuration docs | Keep source comments, function names, and variable names as upstream has them. Rewrite `Ghostty` / `ghostty` to the new name only in the output of `+help`, `--help` for each action, `+explain-config`, and `+show-config --docs`, at help-string generation or output time (decided 2026-10-11) | Implement the rewrite in the generation or output step; list sentences where a plain rewrite would be wrong, such as platform-specific upstream statements, and exclude them |
| Name-bearing configuration values | Keep upstream values as they are, including `window-theme = ghostty` (decided 2026-10-11): changing the configuration parser would add recurring merge conflicts. This is an accepted exception to the no-`ghostty` policy | Exclude these values from help rewriting so the help never advertises an unsupported `gozitty` value; inventory any other configuration values that carry the name |
| Configuration template | Rewrite the template that is written when no configuration exists (`src/config/config-template`, embedded by `Config.zig`) at build or output time, keeping the upstream source | Verify that a fresh launch creates correctly branded content and working links |
| User themes | Resolve user themes under the new `gozitty` namespace instead of `ghostty/themes` (`src/config/theme.zig`) | Include custom themes in the README migration steps |
| Generated completions and editor files | Rewrite the file names and contents of the generated fish, zsh, and bash completions, Vim/Neovim files, and the bat/Sublime syntax at build time, keeping the upstream generators (`src/build/GhosttyResources.zig`, `src/extra/*`). They are part of the release tree and ZIP even though the installer currently copies only `share\terminfo` and `share\ghostty` | Decide which of them are shipped; include them in release-tree and ZIP checks |
| Runtime CLI messages and logs | Rewrite user-visible stdout, stderr, and diagnostic messages outside the help mechanism (for example `src/main_ghostty.zig`, `src/cli/explain_config.zig`, `src/cli/ssh.zig`, startup log lines in `src/global.zig`) through the name module or at the output boundary | Inventory these messages separately from the help strings |
| Legacy `ghostty.exe` | Gozitty provides no `ghostty.exe` link, alias, or copy (decided 2026-10-11). Existing `ghostty` invocations keep reaching the old Ghostty installation until the user removes it, and stop working after that | Announce the new command name in the release notes. The old PATH entry is removed when the user uninstalls the old Ghostty |
| Source identifiers shared with upstream | Keep (decided 2026-10-11) to prioritize synchronization with upstream: source file names, Zig module and type names, the C API in `include/ghostty.h`, `libghostty-vt` and its headers, and build step names. They are not installed or shown to users | If `ghostty-vt.dll` is ever shipped, decide its file name separately |
| Install directory and group | Install to `{autopf}\Gozitty` (for example `C:\Program Files\Gozitty`; decided 2026-10-11, capitalized like the display name) never the old Ghostty directory; use the Start menu group `Gozitty` and shortcut names `Gozitty` / `Uninstall Gozitty`. The installer does not delete the old `{autopf}\Ghostty` files or old shortcuts: removing old files is not the application's job, and the README tells users to delete folders they no longer need (decided 2026-10-11) | None beyond the installer changes |
| AppId | Use a new GUID (decided 2026-10-11, replacing the earlier decision to keep `{6F0C5B4E-2B6D-4E4A-9C2E-3A1D5F7B8C90}`). Gozitty registers as a separate application; the old Ghostty stays in Apps & features, and its own uninstaller removes its files, shortcuts, and PATH entry. Both can be installed at the same time until the user removes the old one | Generate the GUID when implementing; document in the README that the old Ghostty is uninstalled from Apps & features |
| Shared-code display name | Rewrite user-facing names in shared code for all platforms, without Windows-only conditionals (decided 2026-10-11). This fork ships only the Windows build, and conditionals would add shared-code diff | Keep each change small to limit upstream merge conflicts |

On 2026-10-11 the repository owner decided to create a new icon for gozitty. The earlier [ghoultty icon candidate](../dist/windows/ghoultty-icon-candidate.png) is not carried over. Keep the current `ghostty.ico` until the new icon is ready. Prepare the new icon as a transparent master, then create and verify ICO sizes and their actual display as part of the rename.

## 3. Identifiers to Rename and Identifiers to Keep

| Rename | Notes |
|---|---|
| Executable, display name, icon, shortcuts, distribution file names, install location, uninstall display name | Product identity |
| `%LOCALAPPDATA%\ghostty\config.ghostty` and legacy `ghostty/config` | New `gozitty` location; no automatic migration, users copy existing settings themselves |
| `TERM=xterm-ghostty`, the terminfo entry, and the user copy under `%USERPROFILE%\.terminfo` | Remote hosts and WSL receive the new entry through the renamed `+ssh` route or the documented `tic` step; the old user entry is left in place |
| `GHOSTTY_*`, `TERM_PROGRAM`, and shell integration | Scripts and tools that read these values must be updated or are affected |
| `share/ghostty`, resource lookup, user themes, generated completions and editor files, configuration template | Themes, shell integration, and generated files move with it |
| IPC named-pipe prefix and runtime CLI messages | Keeps old and new instances from talking to each other; user-visible messages carry the new name |
| XTVERSION and other terminal-reported names | Programs that detect the terminal by name are affected |
| Win32 window classes and similar identifiers | Tests and scripts that use the class names are updated together |

| Keep | Reason |
|---|---|
| Upstream copyright, LICENSE, attribution, and third-party notices | Required by the license terms; preserve provenance |
| Historical release notes and changelog entries | Records of the name used at the time |
| Source identifiers shared with upstream | Synchronization with upstream (decided 2026-10-11); not installed or shown to users |
| Configuration values defined upstream, such as `window-theme = ghostty` | Synchronization with upstream (decided 2026-10-11); excluded from help rewriting |

Old-name occurrences are classified one by one rather than replaced in bulk. Config keys, values, defaults, and actions keep upstream syntax and semantics unless separately decided; only the names above change.

## 4. Implementation Inventory

| Area | Current locations | Work |
|---|---|---|
| Build name | `src/build/GhosttyExe.zig` | Rename the EXE only for Windows; minimize shared-core changes |
| Windows resources | `dist/windows/ghostty.rc`, `dist/windows/ghostty.ico` | Change FileDescription, OriginalFilename, and ProductName; create and apply icon sizes from the new gozitty icon |
| Win32 UI | `src/apprt/win32/App.zig`, `Tab.zig`, `TabBar.zig`, `TabBarAccessibility.zig`, `Surface.zig` | Update titles, errors, permission dialogs, accessibility names, and related tests |
| Win32 identifiers | Window class names in `App.zig`, the IPC pipe prefix in `IpcTransport.zig`, and similar identifiers | Rename `Ghostty*` classes and the pipe prefix; update `test-windows-context-menu.ps1` and `test-windows-parity.ps1` |
| Configuration | Both lookups in `src/config/file_load.zig` (`config.ghostty` and legacy `config`), `src/config/Config.zig`, user themes in `src/config/theme.zig`, and the template in `src/config/config-template` | Switch every automatic lookup to the `gozitty` namespace; do not read the old location; rewrite the template at build or output time |
| Terminal identity | `src/terminfo/ghostty.zig`, `src/terminfo/Source.zig` (XTGETTCAP `TN`), the terminfo install step, the resource sentinel in `src/os/resourcesdir.zig`, the user entry in `src/os/terminfo.zig`, `TERM`, `TERM_PROGRAM`, XTVERSION and other responses | Rename and install the new terminfo entry; rename `xterm-ghostty` in `src/cli/ssh.zig` and the SSH cache; redesign the remote and WSL routes if needed |
| Environment and shell integration | `GHOSTTY_*` producers and the shell integration scripts | Rename variables through one constant; add a build step that renames `ghostty` names in the installed shell integration files, leaving the repository copies unchanged |
| Resources | `share/ghostty` layout and resource lookup; generated completions and editor files in `src/build/GhosttyResources.zig` | Rename the directory and its lookup; rewrite generated file names and contents at build time |
| Runtime messages | `src/main_ghostty.zig`, `src/cli/*.zig` messages, `src/global.zig` log lines | Rewrite user-visible names through the name module or at the output boundary |
| CLI help output | `src/build/HelpStrings.zig`, `src/cli/help.zig`, `src/cli/explain_config.zig`, `src/cli/show_config.zig` | Rewrite the name at generation or output time; leave source comments unchanged |
| CLI output | `src/cli/version.zig`, `scripts/build-release.ps1` | Align Windows display name and version parsing; check effects on other OSes |
| Release tooling | `scripts/build-release.ps1`, `scripts/test-windows-context-menu.ps1`, `scripts/test-windows-parity.ps1`, and related scripts | Update output EXE, resources, version handling, and default test EXE paths |
| Installer | `dist/windows/ghostty.iss`, `scripts/build-installer.ps1` | Align display, files, icons, PATH, signing targets, output name, new AppId, and removal |
| Documentation | `README.md`, `docs/windows.md`, `docs/version-update-checklist.md`, related Windows docs | Update current instructions, configuration paths, and attribution; state in the README's upstream relationship section that this is an unaffiliated fork. Add a migration section to the README (decided 2026-10-11): copy the old settings to the new location and rename them (for example `%LOCALAPPDATA%\ghostty\config.ghostty` to `%LOCALAPPDATA%\gozitty\config.gozitty`), then delete folders that are no longer needed. Do not rewrite historical release records |
| Distribution URLs | Installer `AppPublisherURL` and related fields, README, docs | Keep the current `fukuyori/ghostty` URLs; verify that links still work after the rebrand |

## 5. Work Sequence and Exit Criteria

Synchronize with upstream first, then implement on `rebrand/gozitty` created from the synchronized `windows` (decided 2026-10-11). The GitHub repository keeps the name `fukuyori/ghostty` for now. A work branch was created locally from `windows` at `d440594ab` on 2026-10-11 and has not been pushed; it predates the synchronization and will be recreated in Phase 1. Integration has not happened.

Workload is a relative estimate based on the number and difficulty of changes, not a time measurement.

| Phase | Workload | Notes |
|---|---|---|
| 0. Upstream synchronization | Large | About 223 upstream commits as of 2026-10-11; a trial merge conflicts in `src/renderer.zig`, `src/renderer/OpenGL.zig`, and `src/renderer/backend.zig`; upstream no longer builds core on Windows, so build breakage is unpredictable |
| 1. Branch workflow | Small | Recreate `rebrand/gozitty` from the synchronized `windows` |
| 2. Resolve specifications | Done | All naming decisions recorded on 2026-10-11 |
| 3. Prepare implementation | Small | The impact inventory already covers most occurrences |
| 4. Build and UI | Medium | Mostly fork-only code (Win32 UI, resources, scripts) without merge conflicts; the executable name in `src/build/GhosttyExe.zig` and other build files are shared and count as shared-code changes |
| 5. Configuration and terminal identity | Large | Small edits across about 15-20 shared files plus build- or output-time rewriting for shell integration, CLI help, the configuration template, and generated completions and editor files |
| 6. Distribution | Medium | Inno script with the new AppId, release and installer scripts, signing targets, test scripts |
| 7. Documentation and development checks | Medium | README migration section, user guide, checklist, changelog; check for leftover `ghostty` names |
| 8. Integrate | Small | Merge the work branch into `windows` |
| 9. Repository name | None | Out of scope |
| 10. Pre-release acceptance | Medium | One real-machine pass by the repository owner |
| Icon | Medium | Create the new icon and its ICO sizes before Phase 4 completes |

0. **Upstream synchronization:** Bring upstream into `main`, then merge it into `windows`. Resolve the renderer conflicts and restore the Windows build and tests before any rename work. Record the result in the roadmap.
1. **Branch workflow:** Keep `main` as a mirror of upstream `main` and `windows` as the Windows development and release branch. Inspect history and the working tree, then recreate `rebrand/gozitty` from the synchronized `windows`. Bring later upstream updates into `main` and explicitly integrate them into `windows`. Do not force-push.
2. **Resolve specifications:** The naming decisions were completed on 2026-10-11 and recorded in #31. Record any decision that the implementation reveals in #31 and this plan. Resolve any uncertainty about the naming request before distribution.
3. **Prepare implementation:** Record the old installation, PATH, shortcuts, configuration, and terminfo state. Inventory every `ghostty` occurrence and classify it as rename or keep (Section 3).
4. **Change Windows build and UI:** Update EXE, icon, resources, Win32 strings and identifiers, and CLI output. User-facing names in shared code change for all platforms without Windows-only conditionals (Section 2), through the fork-owned name module (Section 1.1).
5. **Change configuration and terminal identity:** Switch the configuration location, `TERM` and terminfo, environment variables, shell integration, resource layout, and terminal-reported names, following the rules in Section 1.1. Do not add automatic settings migration.
6. **Change distribution and migration:** Update Release and Inno scripts, signing targets, layout, the new AppId, and removal. Do not reuse the old Ghostty directory. Do not delete the old installation's files or shortcuts; the README covers manual removal.
7. **Document and verify during development:** Update current instructions, configuration paths, attribution, and migration differences. Record results and open checks in #31, the roadmap, and changelog. Put actual distribution results in release notes only when publishing.
8. **Integrate:** Once implementation and development checks pass, integrate the work branch into `windows`. Integration and pushing require a separate request.
9. **Repository name:** Keep `fukuyori/ghostty` for now (decided 2026-10-11). A repository rename is outside this rebrand; if one is decided later, verify old and new URLs, issues, and `origin` fetch/push targets, and update documentation and installer URLs. Keep accidental pushes to `upstream` and `mattn` disabled.
10. **Pre-release acceptance:** On the final candidate, perform one real-machine pass for fresh install, install alongside an existing Ghostty preview, and uninstall. Do not repeat these at every development step.

Small review increments are fine, but do not treat a distribution with mixed old and new names as complete.

## 6. Acceptance Verification

During development, verify the source, UI, and CLI affected by each change. Fresh install, install alongside an existing Ghostty preview, and uninstall on a real machine are required once, when the final release candidate is ready.

| Scope | Required checks |
|---|---|
| Source and build | Relevant Zig tests, Debug build, `git diff --check`; the shared-code diff against upstream is limited to the rename sites (Section 1.1) |
| New EXE | Startup, `--version` and main CLI commands, file properties, icon, resource lookup, clean exit |
| Actual UI | Title, taskbar, errors, accessibility names, multiple windows, DPI; legibility of 16/32/48-pixel icons |
| Configuration | New `gozitty` location, `XDG_CONFIG_HOME` precedence, reload; the old `ghostty` location is not read, and a manually copied configuration loads |
| Terminal identity | `TERM`, terminfo, `TERM_PROGRAM`, XTVERSION, shell integration, renamed environment variables, SSH to a host without the new terminfo entry |
| No `ghostty` residue | Gozitty-owned artifacts and writes (its install tree, file names, registry entries, shortcuts, PATH entry, environment it sets, configuration it creates, window classes, IPC pipes, and terminal responses) contain no `ghostty` name, except license and attribution notices. An old Ghostty installation and its state are checked separately and must be left untouched |
| Command resolution | PowerShell, cmd, PATH, explicit EXE paths; `gozitty` reaches Gozitty, and `ghostty` reaches only an old installation that is still present |
| Distribution | Release tree and ZIP contents including generated completions and editor files, staged EXE, signatures on Inno installer and uninstaller, displayed name and version |

### One Real-Machine Pass Before Release

Use the final release-candidate installer for these three paths in one acceptance pass, not at every implementation step.

| Path | Checks |
|---|---|
| Fresh install | `{autopf}\Gozitty` directory, shortcuts, PATH, launch, configuration loading from the new location |
| Alongside an old Ghostty | Install with the latest published Ghostty preview present: both appear separately in Apps & features; the old installation, shortcuts, PATH entry, and settings are untouched; uninstalling the old Ghostty afterwards removes only its own files, shortcuts, and PATH entry |
| Uninstall | Remove the Gozitty installation's own files, shortcuts, PATH entry, and registry entries; leave the old Ghostty installation, `%LOCALAPPDATA%\ghostty`, and other apps untouched |

A successful build alone is insufficient. Check actual EXE display, signatures, and configuration loading. Record fresh install, side-by-side install, and removal outcomes separately in this single pre-release pass. The repository owner performs real-machine operations and records the tested version, install method, outcomes, and leftovers. Acceptance is incomplete until this is done. Package creation follows the authorization in effect at that time.

## 7. Update Rules

When naming or compatibility policy changes, update #31, this plan, and the priorities and verification entries in the [roadmap](windows-roadmap.md) together. During implementation, update the [Windows user guide](windows.md), [version update checklist](version-update-checklist.md), and [changelog](windows-changelog.md). Keep past release notes and changelogs as records of the product name used at the time.
