# Windows Upstream Feature Development Plan

- Created and updated: 2026-09-23
- Scope: the `windows` branch of `fukuyori/ghostty`
- Status: Plan written and issues registered; implementation and acceptance verification have not started
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
| F1 | Command palette | Search and run many existing actions | Medium | Not started | [#17](https://github.com/fukuyori/ghostty/issues/17) |
| F2 | Scrollbar | Locate and navigate long scrollback | Medium | Not started | [#23](https://github.com/fukuyori/ghostty/issues/23) |
| F3 | File drag and drop | Enter long or multiple paths from Explorer | Medium to high | Not started; path behavior needs a decision | [#32](https://github.com/fukuyori/ghostty/issues/32) |
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

Completion criteria:

- Correct position and size with empty or extensive history, a reached history limit, and resize.
- Independent split positions and stable state across search and alternate-screen transitions.
- Handle new output or pane closure during drag without obstructing normal terminal mouse input.
- Inspect actual display for DPI changes, high contrast, and config reload to `never`.

### F3: File Drag and Drop

Upstream converts a file list into paths for pasting; noctty has an OLE drop receiver. This fork's Win32 app has no receiver. Initially support file and directory paths from Explorer, excluding arbitrary HTML/URL formats and noctty-specific modifier behavior. Route insertion through the existing input and paste-protection path.

Required decisions before implementation:

- Supported shells, such as PowerShell, cmd, and Git Bash.
- Quoting and separators for multiple paths and paths with spaces, quotes, or shell metacharacters.
- Whether to handle WSL/MSYS path conversion; do not convert implicitly.
- Target pane and focus when dropping onto a split.

Do not assume POSIX escaping or noctty quoting works across all Windows shells. Do not implement before these decisions are made.

Completion criteria:

- Paths with spaces, Japanese characters, and symbols, and multiple files produce intended input in the chosen shells.
- Actual Explorer drops reach the intended pane without running a command unexpectedly.
- Check cancelation, target-window closure, paste protection, and OS restrictions for normal/elevated users.

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
