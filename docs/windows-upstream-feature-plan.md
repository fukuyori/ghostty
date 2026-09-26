# Windows Upstream Feature Development Plan

- Created and updated: 2026-09-23
- Scope: the `windows` branch of `fukuyori/ghostty`
- Status: F1-F3 implementation and acceptance checks are complete; F4-F8 remain
- Related: [Windows roadmap](windows-roadmap.md), [user guide](windows.md)
- Source of truth for progress, priority, and issues: [roadmap Phase 7](windows-roadmap.md#phase-7-upstream-feature-coverage-on-windows). This document records feature-specific design questions and acceptance criteria.

## 1. Purpose and Selection Criteria

Develop features present in both upstream Ghostty and noctty but missing from this fork's Windows build. Prioritize daily-use value and the scope that can be implemented and verified while preserving Ghostty compatibility.

Upstream Ghostty defines the specification. Noctty is a comparison point for shared features and Windows constraints; do not adopt its original code, features, or settings. Matching feature or setting names do not establish behavioral compatibility.

Writing this plan does not start implementation. Each feature requires a separate request. Resolve open design questions before starting rather than filling specifications with assumptions.

### Compatibility Principles

- Preserve upstream setting names, values, defaults, actions, and target-pane semantics.
- Adapt UI appearance to Windows APIs while preserving the meaning of operations and settings.
- Use the existing shared core and keep OS-specific code primarily under `src/apprt/win32/`.
- Explain necessary shared-core changes and check their effects on other platforms.
- Where upstream macOS and GTK differ, record the behavior chosen for each feature.
- If an OS-specific feature cannot have the same meaning on Windows, document the unsupported scope and Windows behavior rather than silently substituting another behavior.
- Preserve copyright and license notices when using upstream code.

## 2. Investigation Baseline and Evidence

| Target | Investigated state |
|---|---|
| This fork | `19472c866b92114f2b61909de66a26f6be10e220`, with records for published `1.3.2-windows.11` |
| Integrated upstream | `bd1c82bc5306da32b16b5055ceff023d7ebc9edc`; shared core, macOS, and GTK implementations inspected |
| Local noctty | `../noctty` at `14652e3a95abb0f85320600f3dd80b2835233423`, approximately `1.3.127` |

Distinguish information about public noctty `1.3.130` from code in the local `1.3.127` checkout. Implementation comparisons here use the local code above. Recheck Git state and upstream changes before implementing.

The investigation covered feature entry points, main logic, state management, and parts of related tests. It did not audit all code, build or run tests, or compare behavior on a real machine. A test's presence is not evidence that it passes or that real behavior works. Value and effort below are code-review estimates, not measurements or schedule commitments.

Roadmap Phases 1-6 record earlier milestones. This plan expands feature coverage afterward without changing their historical completion records. It does not replace the rebranding priority (#31) or pending hardware checks.

## 3. Priority and Development Units

| ID | Feature | Value | Relative effort | Initial state | Issue |
|---|---|---|---|---|---|
| F1 | Command palette | Search and run many existing actions | Medium | Implemented; controlled UI, reload safety, owner-confirmed navigation, physical IME confirmation, high contrast, and mixed-DPI display passed | [#17](https://github.com/fukuyori/ghostty/issues/17) |
| F2 | Scrollbar | Locate and navigate long scrollback | Medium | Implemented; overlay lifecycle, position sync, split and alternate-screen behavior, drag races, history limits, resize tracking, real-pointer drag, high contrast, and mixed-DPI display verified | [#23](https://github.com/fukuyori/ghostty/issues/23) |
| F3 | File drag and drop | Enter long or multiple paths from Explorer | Medium to high | Implemented; PowerShell/cmd quoting, rejection, pane targeting, elevated-window restriction, and target-window closure checked | [#32](https://github.com/fukuyori/ghostty/issues/32) |
| F4 | Taskbar progress | See supported applications' progress outside the terminal | Low to medium | Not started | [#33](https://github.com/fukuyori/ghostty/issues/33) |
| F5 | HTML clipboard output | Paste formatted terminal output into documents | Low to medium | Not started | [#34](https://github.com/fukuyori/ghostty/issues/34) |
| F6 | Session save and restore | Reduce rebuilding tabs, splits, and working locations | High | Awaiting design | [#35](https://github.com/fukuyori/ghostty/issues/35) |
| F7 | Quick terminal and global bindings | Invoke the terminal from another app | High | Awaiting design | [#24](https://github.com/fukuyori/ghostty/issues/24) |
| F8 | Desktop and command-finish notifications | Report long-running command completion | Medium to high; depends on shell reporting | Awaiting design | [#21](https://github.com/fukuyori/ghostty/issues/21) |

On 2026-09-23, the plan was added to existing #17, #23, #24, and #21, and #32-#35 were created. Broader issue #25 also covers progress and command-finish notifications, so #33 and #21 link to it. Existing #15 separately tracks the quick-terminal CLI/IPC path.

The recommended order is F1 → F2 → F3. F4 and F5 can be inserted as smaller independent increments. Design F6-F8 after validating the initial features. This is a value-and-effort order, not a strict implementation dependency.

## 4. Initial Features: Scope and Completion Criteria

### F1: Command Palette

The shared code has `toggle_command_palette` and `command-palette-entry`, but Win32 `App.performAction` does not handle them. Upstream GTK collects commands from config and filters operations unsupported by GTK.

Initial scope:

- List and search commands using upstream-defined names, descriptions, and actions.
- Show bindings, execute the selected action, and cancel with Escape.
- Restore focus to the invoking pane and follow config reloads.
- Follow upstream policy for Windows-unsupported actions; do not present them as executable.
- Exclude noctty-specific profiles, named layouts, and recent-command history.

Before implementation, compare macOS and GTK search, ordering, and dynamic destination lists. Record the chosen behavior and unsupported scope; do not invent a separate search specification.

Windows implementation in progress: include both configured entries and live
terminal destinations, as the owner selected. The native dialog sorts titles
case-insensitively with the upstream colon ordering, matches ordered query
characters in titles and descriptions, and snapshots actions while open.
Unsupported Win32 actions are filtered. The controlled window-state check
found 76 entries and verified Up/Down selection and focus restoration after
dismissal; a captured image shows the dialog. The owner also confirmed real
Up/Down input, new-tab action, and switching to an open tab. A regression check
also closes a second window while its palette is open and verifies that the
dialog and window close without a stale surface reference while the original
window survives. A controlled VK_PROCESSKEY Enter leaves the palette open and
its selection unchanged, and the palette snapshot remains valid across config
reload. The owner then used the physical Japanese IME to enter and confirm a
query; the captured palette remained open with the confirmed text and no
command executed. A high-contrast capture then confirmed readable input,
selection, command list, description, and buttons. With monitor 3 temporarily
set to 125%, another capture confirmed scaled, unclipped input, selection,
command list, description, and buttons. The monitor was restored to 100%.

Completion criteria:

- Standard and user-defined configured commands run against the correct pane.
- IME confirmation Enter does not also execute a command; input returns to the terminal after canceling.
- Config reload, tab changes, and target-pane closure do not cause stale references or wrong execution.
- Inspect usable display in small windows, mixed DPI, and high contrast.

### F2: Scrollbar

The shared core reports scrollback position through `Surface.updateScrollbar`. `scroll_to_row` also exists, so add Win32 presentation and input rather than rebuilding history.

Initial scope:

- Per-pane scrollbars following `scrollbar = system / never`.
- Compute thumb position and size from full history and the visible range; connect mouse input to existing row navigation.
- Reflect position changes from search, wheel, keys, and new output.
- Exclude noctty-specific match markers and decoration.

Before implementation, compare upstream behavior and decide how to follow Windows system settings, consume layout space, and handle new output during dragging.

Windows implementation in progress: the owner revised `system` to use a slim
translucent overlay that appears on scroll or edge hover and hides afterward;
`never` disables it. The overlay leaves the terminal grid at full width and
sends drag navigation through `scroll_to_row`. A controlled check confirmed
the overlay HWND reveals and hides, and captured pixels confirm the thumb is
actually drawn. The owner reported OK after the manual long-output, hover,
drag, and hide sequence; exact scroll position was not recorded. Independent
split checks now confirm that each pane reveals only its own overlay and that
both overlays remain aligned to their pane through maximize and restore. The
check exposed an internal-left-pane conflict where divider hover consumed the
right-edge pointer before scrollbar hover; Win32 now evaluates scrollbar hover
first. Search and key/wheel position tracking, alternate-screen behavior,
exact post-drag position, and mixed-DPI/high-contrast presentation were the
remaining checks at that point. Later controlled pixel measurements verified
thumb positions for scroll-to-top, scroll-to-bottom, page-up, wheel-up, and
search-result navigation. Three controlled runs also verified that the overlay
cannot reveal in alternate screen and becomes available after returning to the
normal screen. Exact post-drag position, output or pane closure during drag,
and mixed-DPI/high-contrast presentation were the remaining checks at that
point. A later controlled drag requested thumb top 364 and consistently
measured 361 after the pixel-to-row-to-pixel integer conversion. New output
during capture and closing a temporary pane while its scrollbar owned capture
also completed without closing the original window or process. Empty and
history-limit cases were then checked in a dedicated process: empty history did
not reveal on edge hover, and a 64-line setting trimmed 2000 generated rows to
29 exported historical rows numbered 1930 through 1958 while retaining a
usable overlay. The owner subsequently completed the real-pointer check: edge hover
revealed the overlay, dragging its thumb moved to older output, and it hid
after release and pointer departure. High-contrast presentation was then
checked separately: a capture confirmed that the thumb remains distinguishable
from the terminal background. With monitor 3 temporarily set to 125%, another
capture confirmed that the overlay width, position, and thumb scale without
clipping or displacement. The monitor was restored to 100%. A controlled
config reload verifies that `never` destroys the
overlay and restoring `system` recreates it.

Completion criteria:

- Correct position and size with empty or extensive history, a reached history limit, and resize.
- Independent split positions and stable state across search and alternate-screen transitions.
- Handle new output or pane closure during drag without obstructing normal terminal mouse input.
- Inspect actual display for DPI changes, high contrast, and config reload to `never`.

### F3: File Drag and Drop

Upstream converts a file list into paths for pasting; noctty has an OLE drop receiver. The Win32 app now accepts Explorer file and directory drops on each terminal pane through `WM_DROPFILES`. Arbitrary HTML/URL formats and noctty-specific modifier behavior are outside this scope. The paths enter through the core paste-protection path.

The configured startup command of each pane selects PowerShell or cmd quoting;
the default shell is cmd. PowerShell paths use single quotes with doubled
apostrophes. Cmd paths use double quotes; paths containing `%` or `!` are
rejected with a warning because cmd expands them. Multiple paths are separated
by spaces. The drop is inserted without Enter, targets the pane under the
pointer, and does not convert WSL/MSYS paths. An unsupported configured shell
produces a warning. Shell changes made inside a running terminal are not
detectable from the startup setting.

The owner supplied captured Explorer drops into a PowerShell pane: a single
`README.md` path and two simultaneous paths containing spaces, Japanese text,
and an apostrophe appeared with the expected single-quote doubling and no
Enter. A later `%`-path screenshot came from the installed Ghostty with a
`pwsh.exe` child, so it was excluded from cmd verification. The owner then
captured the expected `%` rejection warning from the development build
(PID 26552, `cmd.exe` child), and the `!` rejection warning
from a relaunched development build (PID 4340, `cmd.exe` child). The owner
reported that `plain space.txt` was double-quoted without Enter in a later
development build (PID 12800, `cmd.exe` child), then confirmed that a drop
onto its right split appeared only in that pane. File-drop formatting rejects
control characters (including newline and Escape) before calling the core
paste-protection path. Valid file drops therefore do not trigger the unsafe
paste prompt. In a real Explorer check, the elevated test window did not
accept a drop from normal Explorer and no path was inserted. The normal
development build accepted drops as described above.

For the final target-window closure check, the owner held a real Explorer drag
over a normal Debug window while its PowerShell child performed a measured
20-second wait and exited. The target window closed at the expected time; the
owner canceled the still-held drag, and Explorer showed no error or abnormal
behavior. This completes the F3 acceptance criteria.

Later controlled runs verified F1 IME process-key suppression and config reload
with an open palette, and F2 `never`/`system` overlay recreation. A five-run
repetition completed with exit code 0 and no forced termination in every run.
After the split-hover ordering fix, five consecutive controlled runs also
verified F2 per-pane reveal independence and maximize/restore layout tracking;
all exited with code 0 without forced termination. These controlled results do
not complete the remaining real-input or display acceptance checks.

Three consecutive controlled position-sync runs measured the same 949-pixel
track and 221-pixel thumb: top at 3, bottom at 725, page-up at 503, wheel-up at
710, and search navigation at 405. Every run also retained split independence
and resize tracking, exited with code 0, and required no forced termination.
Three following runs passed the alternate-screen hide and normal-screen restore
checks with the position, split, and resize results unchanged; all exited with
code 0 without forced termination.

Three controlled drag runs requested thumb top 364 and measured 361 each time,
within the four-pixel allowance for two integer conversions. All three survived
40 lines of new output during drag and destruction of a temporary third pane
during its own drag, retained the original two panes, exited with code 0, and
required no forced termination.

Five controlled history-boundary runs all hid the overlay before scrollback
existed and exported the same 29 retained rows, 1930 through 1958, after 2000
rows were produced with `scrollback-limit-lines = 64`. After adding a renderer
settle interval, two final runs both measured a 573-pixel thumb on a 949-pixel
track. The dedicated processes exited with code 0 without forced termination.

The subsequent full Debug `zig build test --summary all` run completed all
91 build steps and passed 3874 of 3936 tests, with the remaining 62 skipped.
An initial run found one incorrect command-palette matcher expectation:
`rld cfg` does match `Reload Configuration` as an ordered subsequence. The
focused matcher test and the full suite both passed after correcting that test
expectation; runtime matching behavior was unchanged.

A final Debug `zig build` and combined command-palette/overlay-scrollbar native
regression completed with exit code 0 and no forced termination. The saved
palette, single-pane scrollbar, and split-pane scrollbar captures were
inspected and showed the expected controls and overlays. The Win32 test-hook
suite then passed 149 of 150 tests, with one skipped. All four monitors in the
native run reported 96 DPI, so it does not close the mixed-DPI acceptance gap.

The owner then changed monitor 3 from 96 to 120 DPI (125%). A combined native
run completed with exit code 0 and no forced termination, reporting 120 DPI
for the parent window, tab bar, and divider on that monitor while the other
three remained at 96 DPI. The tab bar scaled from 1204 x 32 to 1507 x 40, and
the divider layout tracked the 120-DPI pane. Captures taken on monitor 3 showed
the F1 palette and F2 overlay scrollbar correctly scaled and unclipped. After
the monitor was restored to 100%, a final native run completed with exit code
0 and reported all four monitors at 96 DPI.

A separate baseline-CPU ReleaseFast build completed all 128 build steps and
validated its PE32+ x64 GUI executable, `1.3.2-windows.11` file/product
versions, numeric version `1.3.2.11`, icons, resources, compiled terminfo, and
output hash. Its first combined F1/F2 regression exposed a harness timing race:
the second palette dialog HWND was visible before its edit and list controls
were available. The script now waits for both controls. The unchanged Release
executable then passed the combined regression with exit code 0 and no forced
termination; the palette and single/split scrollbar captures were inspected.
The initial soak attempt found two pre-existing manual-evidence directories in
`zig-out/test-state`. The soak harness now preserves a snapshot of existing
entries and fails only when an iteration adds or removes one. With that check,
the ReleaseFast executable passed 20 of 20 soak iterations with zero failures
in 119.803 seconds. A final real Explorer drop into that ReleaseFast executable
inserted the quoted `README.md` path without Enter or command execution.

Completion criteria:

- Paths with spaces, Japanese characters, and symbols, and multiple files produce intended input in the chosen shells.
- Actual Explorer drops reach the intended pane without running a command unexpectedly.
- Target-window closure passed with a real Explorer drag held over a Debug window until its scheduled shell exit. The elevated-window Explorer restriction was observed; the `%`/`!` warning covers rejection. Malformed control-character paths are covered by unit tests because Explorer cannot supply such filenames.

## 5. Independent Features

### F4: Taskbar Progress

The shared core passes `progress_report` to Win32, which currently does not handle it. Reflect upstream `progress-style` states in the Windows taskbar.

- Handle normal, paused, error, indeterminate, and cleared states.
- Determine which pane's state represents a multi-pane window using upstream policy.
- Verify value range, active-pane changes, cleanup after exit, and API failure.
- Test both a controlled progress sequence and a real supporting app. Do not claim automatic support for apps that emit no progress.

### F5: HTML Clipboard Output

The shared core generates HTML for `copy_to_clipboard:html` and mixed output. Current Win32 writes only `CF_UNICODETEXT` and does not register HTML.

- Connect upstream-generated HTML to Windows `HTML Format` (CF_HTML).
- Compare plain, mixed, and HTML behavior with upstream. Decide any plain-text fallback instead of guessing its content.
- Validate CF_HTML headers with UTF-8 byte offsets, Japanese text, newlines, and special characters.
- Inspect actual paste results in rich-text and plain-text destinations.
- Preserve existing copy and OSC 52 behavior.

## 6. Later Design Work

### F6: Session Save and Restore

Upstream depends on the macOS restoration mechanism. Noctty uses its own JSON format and profile management; do not adopt that implementation.

First design Windows defaults for `window-save-state`, save timing, format and migration, and restoration scope for windows, tabs, splits, titles, and working directories. Consider precedence against `-e` and an explicit startup directory, corruption and interrupted writes, missing directories, and changed monitor layouts.

Do not present this as resuming running processes. Current PowerShell integration does not automatically report the working directory, so the exit-time directory may be unavailable. Exclude noctty-specific history snapshots and named layouts.

### F7: Quick Terminal and Global Bindings

Use `toggle_quick_terminal`, `quick-terminal-*`, and `global:` as the contract. Design hotkey registration/removal and config reload, conflicts, multiple monitors, foreground display and auto-hide, focus return to the previous app, and process cleanup on exit.

Noctty substitutes ordinary focus acquisition for exclusive-input requests in one implementation. Loading the same setting is insufficient for compatibility; determine its achievable Windows meaning per setting. Verify with real keys while another app is active.

### F8: Desktop and Command-Finish Notifications

Treat `desktop_notification` and `command_finished` separately. Preserve upstream enable/disable, focus conditions, elapsed-time thresholds, and notification actions. Decide Windows notification API use, install-state requirements, click destinations, and unavailable-notification behavior first.

Command-finish notifications require shell integration or OSC 133 start/end data. Adding notification UI alone cannot detect arbitrary PowerShell command completion. Do not add noctty-specific automatic PowerShell integration under this plan.

## 7. Other Candidates and Exclusions

Reassess these shared features after the initial work:

- Tab overview: compare its value with existing tab operations and the palette.
- Undo/Redo: upstream and noctty cover different operations. Design closed-pane lifetime, process preservation, `undo-timeout`, and history disposal.
- Background-opacity toggle: a smaller `toggle_background_opacity` compatibility candidate. Opacity settings already exist. Preserve D3D11 background-opacity semantics rather than adopting noctty's whole-window alpha.

Out of scope:

- Noctty-specific automatic PowerShell/cmd integration, shell profile selection, and named layouts.
- Noctty-specific config GUI, control API, update mechanism, and palette extensions.
- Rebuilding already implemented tabs, splits, or terminal search as missing features.
- Replacing D3D11 with noctty's OpenGL renderer.

## 8. Shared Completion Criteria and Evidence

Track each feature through Not started → Specified → Implementing → Automated checks passed → Real-machine checks passed. Record distributed-build verification separately. Neither a successful build nor automated tests alone complete a GUI feature.

Select relevant checks per feature under the [roadmap verification criteria](windows-roadmap.md#9-verification-for-each-change):

- Format changed files; run `git diff --check`, meaningful targeted unit tests, and a build.
- Use `test-windows-window-state.ps1` for input, split, reload, and exit regression checks.
- Inspect actual display or images for GUI changes, and real key, mouse, and IME input for input changes.
- For window or process lifecycle changes, inspect exit codes and leftover processes; run `test-windows-soak.ps1` when needed.
- Record coverage of DPI, multiple displays, and high contrast. Check keyboard access and accessibility for new UI.
- Add GPU-recovery and power-resume checks only when the rendering lifecycle changes.

Record the commit, build configuration, executable, OS, DPI, shell, distinction between automated and manual checks, results, logs/images, and unknowns. Do not conflate controlled, real-machine, and distributed-artifact evidence.

Update this plan, `windows.md`, `windows-roadmap.md`, and `windows-changelog.md` with implementation. Roadmap Phase 7 is authoritative for F1-F8 priority, status, and issues; update the corresponding sections here at the same time. On publication, record actually included features, checks, and limitations in `windows-release-notes.md`. Do not append unpublished changes to an old release. Version changes, commits, tags, pushes, and packaging require separate requests.

## 9. Code References

Local references use the commits in Section 2.

| Target | Reference |
|---|---|
| Upstream config and actions | [`Config.zig`](../src/config/Config.zig), [`action.zig`](../src/apprt/action.zig), [`Binding.zig`](../src/input/Binding.zig) |
| Current Win32 action handling | [`App.zig`](../src/apprt/win32/App.zig) `performAction` |
| Upstream palette | [GTK `command_palette.zig`](../src/apprt/gtk/class/command_palette.zig) `collectRegularCommands`, `isActionSupportedOnGtk` |
| Upstream file drop | [GTK `surface.zig`](../src/apprt/gtk/class/surface.zig) `dtDrop` |
| Shared-core history, progress, HTML | [`Surface.zig`](../src/Surface.zig) `updateScrollbar`, `progress_report`, clipboard-format generation |
| Current Win32 clipboard | [`win32/Surface.zig`](../src/apprt/win32/Surface.zig) `setClipboard` |
| Main noctty implementation | `../noctty/src/apprt/win32.zig`: `invokePaletteRow`, `setScrollbar`, `setProgressReport`, `restoreSessionPane`, `toggleQuickTerminal` |
| Noctty helpers | `win32_surface_drop_target.zig`, `win32_surface_drop.zig`, `win32_clipboard_html.zig`, `win32_taskbar_progress.zig`, `win32_session_persistence.zig` (all under that repository's `src/apprt/`) |

Pinned upstream sources: [config](https://github.com/ghostty-org/ghostty/blob/bd1c82bc5306da32b16b5055ceff023d7ebc9edc/src/config/Config.zig), [actions](https://github.com/ghostty-org/ghostty/blob/bd1c82bc5306da32b16b5055ceff023d7ebc9edc/src/apprt/action.zig).
