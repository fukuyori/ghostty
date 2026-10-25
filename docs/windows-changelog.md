# Gooztty Changelog

Every change between the Windows previews of this fork, grouped by kind and
listed with the commit that made it. The
[release notes](windows-release-notes.md) carry the verification results,
known issues, and known limitations of each version; the
[version update checklist](version-update-checklist.md) describes the
`X.Y.Z-windows.N` numbering.

## Unreleased

Versions up to `1.3.2-windows.16` were published under the name Ghostty.
The changes below rename the application to Gooztty on the `gooztty`
branch (rename step 9, #31).

### Changed

- Rename the application to Gooztty by selecting the Gooztty values in
  `src/brand.zig`: the executable is `gooztty.exe`, resources are in
  `share\gooztty`, the configuration is
  `%LOCALAPPDATA%\gooztty\config.gooztty`, `TERM` is `xterm-gooztty`,
  `TERM_PROGRAM` is `gooztty`, environment variables use `GOOZTTY_`, and the
  window classes, IPC pipe and notification AppUserModelID
  (`fukuyori.Gooztty`) follow the new name. The installer has a new AppId,
  so Gooztty installs beside the Ghostty for Windows previews instead of
  upgrading them. `+version` no longer links to an upstream commit. Nothing
  is migrated automatically; the README describes the manual steps.
- Use the selected ghoultty artwork as the application icon
  (`dist/windows/build-gooztty-icon.ps1` writes `ghostty.ico`) and remove
  the unused icon candidates.
- A renamed build started from inside Ghostty removes the `GHOSTTY_*`
  variables Ghostty set for its own shell (resources and binary
  directories, surface ID, shell integration and quick terminal variables)
  from its child environment; variables a user sets, such as
  `GHOSTTY_LOG`, stay (#67).
- The portable release tree no longer contains libghostty-vt
  (`ghostty-vt.dll`, its libraries, headers and pkg-config files). The
  terminal links it statically and never loaded the DLL, and the installer
  never shipped it (#68).

### Build

- Add the name values used by the build and distribution tooling to
  `src/brand.zig` (executable, resource and configuration directory names,
  configuration file name, terminfo name, `TERM_PROGRAM`, installer AppId),
  all still Ghostty. Every Windows build writes them to `brand.json` at the
  root of the install prefix, and `scripts/windows-brand.ps1` reads and
  validates it for the PowerShell scripts (rename step 8, #31).
- Take the configuration location and file name, user themes directory,
  terminfo names and `TERM` default, `TERM_PROGRAM`, the XTVERSION name,
  the `+ssh` terminfo and cache names, and the `GHOSTTY_*` environment
  variable names from `src/brand.zig`, with unchanged values (rename step 8,
  #31).
- Take the Windows executable name, the `share` resource directory, the
  terminfo and completion file names, the notification icon path and the
  executable's ProductName, FileDescription and OriginalFilename from
  `src/brand.zig`, with unchanged values and an unchanged install tree
  (rename step 8, #31).
- Rewrite the contents of the installed shell integration, completions,
  Vim and Sublime files and the configuration template from
  `src/brand.zig` at build time, keeping upstream URLs, the `window-theme`
  value and the Vim attribution; a guard fails the build on unexpected
  names. With unchanged values the installed files are byte-identical
  (rename step 8, #31).
- Make the release and installer scripts and the Inno Setup script take the
  executable, resource, terminfo, display, AppId and AUMID names from
  `brand.json`, with unchanged values (rename step 8, #31).
- Make the diagnostic and test scripts take the default executable, window
  class names, environment variable names, configuration file name and
  process name from `brand.json` (rename step 8, #31).
- Take the product name in CLI output from `src/brand.zig`: the generated
  help strings (action `--help`, `+explain-config`, `+show-config --docs`,
  fish descriptions) are rewritten at build time with upstream version
  history, website, platform statements and configuration values kept;
  `+help`, `+version`, `+ssh` usage and runtime messages use brand values.
  `+ssh-cache` now reads the same cache directory as `+ssh`. Output is
  unchanged with the current values (rename step 8, #31).
- Make the configuration template and `+ssh-cache` entry tests independent
  of the values in `src/brand.zig`, so they pass with the renamed values.

### Documentation

- Rewrite the README and its Japanese translation for Gooztty, with the
  new icon, the publication state of the rename, a section on moving from
  Ghostty for Windows, and the statement that this fork does not take pull
  requests. Update the user guide, the configuration support tables and the
  version update checklist to the new executable, paths, variables and
  installer names.
- Record the branch cutover: `gooztty` was created on 2026-10-25 and is the
  default branch; `AGENTS.md` describes each branch's role.

- Add `docs/windows-config-support.md`, listing every configuration option
  with its Windows status (runtime-verified, supported from the code,
  partial, not implemented, or not applicable) and a description, with a
  Japanese translation, and link it from the README.
- Add `README.ja.md`, a Japanese README linking the Japanese configuration
  table. Replace the README work phases with the roadmap's schedule through
  the rename (#31), with each step's status, and update the verified
  hardware scope (144/192 DPI, high contrast, Narrator, real sleep and
  resume, German layout; Windows 10 not supported). Mark the owner-run
  release step done in the roadmap.

## 1.3.2-windows.16

Includes the changes after `1.3.2-windows.15` through F8 desktop
notifications (#21); verification is recorded in the
[release notes](windows-release-notes.md#132-windows16).

### Changed

- Show desktop notifications (OSC 9 / OSC 777) and command-finished
  notifications as Windows toasts under a per-user AppUserModelID, with
  click-to-present, removal on pane close and exit, and the upstream
  `notify-on-command-finish*` settings (F8 #21). Implement BEL with
  `bell-features` `system`, `attention` and `title`. The installer removes
  the notification registration on uninstall. Debug build, Win32 tests and
  owner-run acceptance passed.
- Support `global:` keybindings with `RegisterHotKey` and add the quick
  terminal (`toggle_quick_terminal`, F7 #24): a single captionless topmost
  tool window placed in the monitor work area by the `quick-terminal-*`
  settings, excluded from session save and `toggle_visibility`, with focus
  return, autohide and `GHOSTTY_QUICK_TERMINAL=1`. A global binding that
  cannot be registered is disabled and listed in the configuration error
  dialog. Debug build and Win32 tests pass, and owner-run real-key
  acceptance passed, including conflicts, autohide, reload, a 125% monitor,
  virtual desktops and the unreachable-quit confirmation. Autohide no longer
  hides the quick terminal when Ghostty itself returns the focus after a
  reload to `keyboard-interactivity = none`.
- Handle OSC 9;4 progress reports in the Windows taskbar using
  `ITaskbarList3`, aggregating panes and tabs with Windows Terminal's state
  priority. Build and focused aggregation test pass; the owner confirms
  real-taskbar acceptance is complete.
- Register terminal HTML output as Windows `HTML Format` (CF_HTML), retaining
  the selected semantics: HTML-only for `copy_to_clipboard:html`, and HTML
  plus plain text for `mixed`. UTF-8 byte-offset tests and the Debug build
  pass. The owner confirmed Japanese text, line breaks and red text styling
  in Word. Direct inspection confirmed HTML-only registers `HTML Format`
  without `UnicodeText`, with valid UTF-8 byte offsets and Japanese/LF
  fragment content; `mixed` registers both `HTML Format` and `UnicodeText`,
  with the expected sample content in both representations. The mixed copy
  pasted all three lines into Notepad. OSC 52 wrote the expected plain-text
  value without registering HTML.
- Add opt-in Windows session save and restore using versioned JSON and atomic
  replacement. The saved state covers window placement, tabs, split trees,
  focus, titles, and OSC 7-reported working directories. Automatic PowerShell
  integration reports native drive directory changes before each prompt. It
  starts new terminal processes and does not restore process or terminal
  contents. PowerShell 7 and Windows PowerShell 5.1 integration checks and
  automated tests pass. The owner confirmed normal-exit/relaunch with two
  windows and distinct PowerShell working directories. Remaining real-machine
  checks are listed in the Windows roadmap.
- Follow the terminal cursor throughout native IME composition (#48),
  including asynchronous cursor movement after a partial commit. Stop
  tracking on composition end, focus loss and surface destruction.
  Controlled placement/lifecycle and existing input/window regressions
  passed. The owner confirmed that partial commit no longer overlaps;
  the final text was `庭にはにわ` and the test process exited with code 0.

### Diagnostics

- Clarify the #48 verification evidence and add a reproducible IME
  verification runner with source/command/hash records. Extend controlled
  checks to close a composing split/tab while retaining a responsive pane,
  record successful closure only after exit, track probe processes, and
  recover owned processes on failure. Add a deliberate cleanup-timeout
  scenario and include the IME scripts in the verification requirements.
- Add opt-in message, cursor and IMM composition-position tracing for #48,
  enabled only with `-Dwin32-test-hooks=true` and
  `GHOSTTY_TEST_IME_TRACE=1`. Add `scripts/test-windows-ime.ps1` for a
  dedicated owner-operated reproduction, and
  `scripts/test-windows-ime-position.ps1` for controlled asynchronous
  placement and tracking-lifecycle checks.

### Documentation

- Record owner confirmation that real-machine sleep/resume works, exclude
  Windows 10 from the support target, and leave real GPU-loss and long-soak
  verification unscheduled until reproducible procedures are available.
- Schedule an owner-run release from `windows` after F8 acceptance and
  before branch cutover, retaining the current Ghostty name for that release.
- Apply the corrected roadmap review: schedule pending build/distribution
  name indirection and verified upstream synchronization before cutover;
  separate F8 feature acceptance from new-name integration; link F6 snapshot
  compatibility conditions; reconcile later verification evidence, status
  labels and code references. Record remaining environment and distribution
  decisions without changing implementation or release policy.
- Clarify branch responsibilities: upstream-feature Windows support,
  including F4-F8, and port fixes belong on `windows`; branding and features
  or behavior extensions absent from upstream belong on `gooztty`. Classify
  by purpose, not implementation date, and split mixed changes accordingly.
- Reschedule name-independent fixes, real-hardware verification, F4-F8 and
  rename preparation before the product rename. Move branch cutover to
  immediately before rename implementation, and reserve final identity,
  installer and integrated-runtime acceptance for the renamed build. Record
  open specifications and external prerequisites without starting implementation.
- Reconcile the `.15` final full-suite results across the release notes,
  roadmap, rebranding plan and port log. Record the next
  branch-workflow step and distinguish completed #49 verification from its
  still-open issue status. Keep publication status in GitHub Releases rather
  than duplicating it in the documentation.

## 1.3.2-windows.15

Includes changes through `9c89f4057`; release-artifact verification is recorded in the
[release notes](windows-release-notes.md#132-windows15).

### Added

- Add opt-in lifecycle failure injection and
  `scripts/test-windows-lifecycle.ps1` for creation rollback
  ([#49](https://github.com/fukuyori/ghostty/issues/49)) and IPC UI timeout.
  The checks exercise 33 creation cases and four real IPC client cases;
  ordinary builds ignore the test controls. See the
  [port log](windows-port-log.md#2026-10-15-creation-rollback-and-ipc-ui-timeout-49)
  for results: after correcting the fallback layout defect found in image
  inspection, both desktop builds, all 37 cases and four image checks passed.
  `scripts/verify-windows-lifecycle.ps1` collects both builds and the
  capture-enabled checks in one run, preserving failed-stage results and
  leaving image inspection to a separate review record. Verification of
  this scope is complete. After the final layout correction, Win32 tests
  passed 182 tests with one skipped. The subsequent full Zig suite during
  `.15` preparation included that correction: 4040 passed, 62 skipped,
  91/91 steps, exit 0. Issue #49 remains open as of 2026-10-16.
- Handle upstream's `resize_window` action (`CSI 8 ; rows ; cols t`) on Win32
  ([#45](https://github.com/fukuyori/ghostty/issues/45)). With
  `vt-window-resize-allowed = true`, a window with a single terminal resizes
  to the requested grid; an omitted or zero dimension keeps its size, and
  only the requested dimensions are limited to the work area. The request is
  ignored while the window is maximized, minimized, fullscreen, or snapped,
  and when it has more than one tab or split. Snapping is detected with
  `IsWindowArranged` where Windows provides it, and otherwise by comparing
  the window size with its restore size. Move the Win32 window
  state handling from `App.zig` to `WindowState.zig` first, as the first step
  of [#12](https://github.com/fukuyori/ghostty/issues/12).

### Fixed

- Fix creation rollback panics when unregistering a Win32 surface before
  core initialization and when destroying an already initialized core after
  a later failure. Restore the previous active tab, native focus, logical
  focused pane and split zoom on failed tab/split creation. These failures
  were reproduced with the new lifecycle hooks; IPC timeout behavior itself
  is unchanged.
- Stop reserving tab-bar space when its auxiliary HWND could not be created.
  Desktop capture exposed an unpainted strip; the lifecycle fixture now
  asserts that the fallback terminal fills the parent client area.
- Run close confirmations, tab-title dialogs, and file-drop dialogs after
  core callbacks return. Preserve close selections by stable surface IDs and
  revalidate targets after modal dialogs; a shell exit during tab rename
  previously reproduced a crash. Add `test-windows-modal-actions.ps1`.
- Give terminal child windows accessible names and update them on shell/tab
  title changes. Notify accessibility clients after mouse-driven tab reorder,
  and announce tree reorder before selection for newly added tabs. Focused
  element names and reordered tab metadata were checked. The owner confirmed
  Narrator title speech and the automatic final-title announcement after new-tab
  creation; broader screen-reader/COM acceptance remains open. See the
  [port log](windows-port-log.md).

- Pair synthetic text with key-release messages in the Windows parity
  regression, avoiding .NET's extra character when adjacent key-down records
  are coalesced. Verify repeated-character payloads without delays, and raise
  the dedicated window only while capturing its search controls. Both cwd
  inheritance modes pass the full regression; see the [port log](windows-port-log.md).
- Defer configuration error dialogs until the Win32 main loop has returned
  from core callbacks. Closing a window or ending its shell while a reload
  diagnostic was open could free the Surface before the key callback resumed
  and crash in `Surface.endKeySequence`. Queue owned diagnostic text, show
  requests sequentially, and discard requests whose owner closed or whose
  app is quitting. Add unit tests and
  `scripts/test-windows-config-diagnostics.ps1`; evidence is in the
  [port log](windows-port-log.md).
- Keep the console size the shell sees in step with Ghostty's grid after a
  `CSI 8 t` resize request ([#46](https://github.com/fukuyori/ghostty/issues/46)).
  The bundled OpenConsole resizes its console for the request before passing
  it on, so a request Ghostty disabled or ignored left the shell at the
  requested size. Ghostty now reasserts its actual size to ConPTY after every
  request. The inbox conhost, used only when the bundled files are missing,
  does not pass the request on and is not covered.
- Stop Ctrl+clicking a link from freezing every window
  ([#36](https://github.com/fukuyori/ghostty/issues/36)). Opening a link ran
  `ShellExecuteW`, and the confirmation or blocked-link dialog for OSC 8
  links, on the UI thread while the core held its renderer lock; a key or
  focus message dispatched meanwhile re-entered the core and deadlocked the
  thread. Link requests now run from the message loop after the core
  callback returns, and the shell runs on a worker thread with COM
  initialized. Move the URL-opening code from `App.zig` to `ShellOpen.zig`
  first, as part of [#12](https://github.com/fukuyori/ghostty/issues/12).
- Stop a Debug build from panicking when a plain-text URL is Ctrl+clicked
  ([#47](https://github.com/fukuyori/ghostty/issues/47)). The link text was
  joined to the working directory and checked as a file; for a URL that is
  not a valid Windows path, and Zig's std panics on that error in Debug
  builds. Such a path is now rejected before the check. Release builds were
  not affected.

### Changed

- Complete the Win32 apprt restructuring
  ([#12](https://github.com/fukuyori/ghostty/issues/12)): every group in the
  layout has its own file and `App.zig` keeps the application lifecycle and
  wiring. The final pass ran the full Zig test suite, window-state (including
  the overlay scrollbar checks), parity, context-menu, a 20-run soak, and an
  owner-operated check of tabs, splits,
  Japanese IME, a 96/120 DPI move and IPC, followed by checks of file drop,
  palette jumps, float-on-top, reset window size, the configuration editor,
  startup maximize/fullscreen and IPC `+new-tab` arguments. Subsequent
  owner-operated checks covered German AltGr and dead keys, physical mouse
  input and appearance. IPC timeout and injected creation-failure rollback
  (#49), left unexercised by that pass, are covered by the follow-up above;
  partial IME commit (#48) is tracked separately.
  See the [port log](windows-port-log.md) for logged evidence, owner reports
  and the saved follow-up results addressing the review findings.
- Extract the CLI IPC entry point, UI request ownership and dispatch, and
  results into `IpcHandler.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12); the transport stays in
  `IpcTransport.zig`. Debug build, Win32 tests, IPC `+new-tab` and no-server
  comparisons with the previous executable, window-state with palette checks,
  parity, modal-action and config-diagnostic regressions passed. See the
  [port log](windows-port-log.md).
- Extract the parent and terminal window procedure and the userdata lookup
  into `WndProc.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12). Debug build, Win32
  tests, window-state (with palette checks, and GPU/power recovery on a hook
  build), the split/tab command check, parity, modal-action,
  config-diagnostic and context-menu regressions passed. See the
  [port log](windows-port-log.md).
- Move the action dispatch (`performAction` body) into `Actions.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12); App keeps the apprt
  entry point. Debug build, Win32 tests, window-state with palette checks,
  the split/tab command check, parity, modal-action and config-diagnostic
  regressions passed. See the [port log](windows-port-log.md).
- Move the startup show, terminal presentation, visibility toggling and
  window-state transfer from App into `WindowState.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12). Debug build, Win32
  tests, window-state (with palette checks), the split/tab command check,
  parity and modal-action regressions passed. See the
  [port log](windows-port-log.md).
- Extract key translation, key/character/IME message handling, character
  suppression with its reset on focus loss, and IME composition placement
  into `Keyboard.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12). Move the ten keyboard
  tests. Debug build, Win32 tests, window-state (input, IME process keys,
  palette), parity and modal-action regressions passed with synthetic
  messages, and an owner-operated physical keyboard and Japanese IME check
  passed. That check found that a partial IME commit leaves the remaining
  composition over the committed text
  ([#48](https://github.com/fukuyori/ghostty/issues/48), tracked separately).
  See the [port log](windows-port-log.md).
- Extract window, tab and split navigation, tab reordering, split
  resize/equalize/zoom, and tab activation into `WindowCommands.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12). Debug build, Win32
  tests, window-state (with palette checks), parity and modal-action
  regressions passed; a dedicated split/tab command check matched the
  previous executable at every step. See the [port log](windows-port-log.md).
- Extract window, tab, and split creation (including core surface
  initialization and rollback), close requests and confirmation, tab/window
  removal, and shutdown teardown into `WindowLifecycle.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12). App keeps the
  `requestSurfaceClose` entry point; deferred modal closes and stable
  surface-ID targets are unchanged. Move the close-tab mode test. Debug build,
  Win32 tests, window-state, modal-action, config-diagnostic and parity
  regressions passed; IPC `+new-tab` matched the previous executable. See the
  [port log](windows-port-log.md).
- Extract tab-bar paint preparation, pointer/drag/wheel handling, viewport,
  invalidation, and the native window procedure into `TabBarController.zig`
  for [#12](https://github.com/fukuyori/ghostty/issues/12). Keep drawing and
  geometry in `TabBar.zig` and state in `Window.zig`; preserve action and
  accessibility dispatch order. Source comparison, Debug build, Win32 tests,
  window-state, title and synthetic tab interaction checks passed; captures
  inspected. Computer Use SendInput tab/divider checks and IME conversion in
  the rename dialog and terminal also passed, followed by a display 1/2 round
  trip at 100%/125% with measured 96/120 DPI and preserved tab/split state.
  Narrator speech recap confirmed selected/renamed titles, dialog labels and
  values, and the selected title after closing a tab. New-tab creation spoke
  the initial title but not its later shell title. In the subsequent pre-fix
  owner check, only `ウインドウ` was spoken, without the title. Post-fix owner
  confirmation of title speech and the automatic new-tab final-title
  announcement is recorded under Fixed above. Broader screen-reader acceptance
  remains open. See the [port log](windows-port-log.md).
- Extract divider placement, painting, hit testing, drag/capture, cursor,
  and native window procedure handling into `SplitDivider.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12). Preserve input
  arbitration and teardown order; move the existing DPI/high-contrast
  thickness test. Verification is in the [port log](windows-port-log.md).
- Extract pane/search/scrollbar/tab-bar placement, content bounds, and native
  size/move/DPI handling into `WindowLayout.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12). Preserve layout and
  callback order; update search, config, appearance, and resize callers.
  Move existing tab-visibility and DPI-decoding tests. Verification and the
  intermediate verification failures are recorded in the [port log](windows-port-log.md).
- Extract Win32 class registration, icons, creation styles, and raw HWND
  creation into `NativeWindow.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12). App supplies the existing
  window procedures and retains userdata, ownership, fallback, and cleanup
  sequencing. Move the existing style and icon tests; verification is in the
  [port log](windows-port-log.md).
- Move accessible-name synchronization, WinEvent notifications, provider lookup,
  and detachment from `App.zig` into `TabBarAccessibility.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12). Preserve notification
  and teardown order; title actions call the owning module directly. Move the
  existing name-format test too. Verification is in the [port log](windows-port-log.md).
- Move terminal mouse buttons, motion, capture release, wheel handling,
  coordinate helpers, and cursor actions from `App.zig` into `Mouse.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12). Preserve focus/capture
  ordering, context-menu behavior, and divider arbitration. Existing tests
  move with their helpers; verification is in the [port log](windows-port-log.md).
- Move native file-drop path collection, paste handling, and warning display
  from `App.zig` into the existing `FileDrop.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12). Preserve shell quoting,
  pane targeting, paste confirmation, and cleanup order. Verification is in
  the [port log](windows-port-log.md).
- Move Win32 palette requests and App-side presentation into the existing
  `CommandPalette.zig` for [#12](https://github.com/fukuyori/ghostty/issues/12).
  Preserve posted opening, snapshot ownership, the single-palette guard,
  and Surface ownership/ID checks before restoring focus or executing a
  selected command or jump. Verification is in the [port log](windows-port-log.md).
- Move Win32 search start/end and result-update actions from `App.zig` into
  the existing `SearchBar.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12). Preserve allocation,
  pane ownership, layout, focus, and result-update order. Verification is
  recorded in the [port log](windows-port-log.md).
- Extract background-blur policy, cleanup and fallback, high-contrast
  detection, and theme-change refresh into `WindowAppearance.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12). Move the existing
  blur-policy test with the code, retaining state ownership and call order.
  Verification status is recorded in the [port log](windows-port-log.md).
- Extract Win32 GPU recovery scheduling and its cycle budget, power
  suspend/resume handling, and recovery test-message handlers into
  `Recovery.zig` for [#12](https://github.com/fukuyori/ghostty/issues/12).
  Move the existing power-event classification test with the code; retain
  App/Surface state, startup hook settings, message IDs, and compile-time
  and runtime test gates. Verification is recorded in the
  [port log](windows-port-log.md).
- Extract Win32 configuration reload and update, diagnostics, configuration
  editor launch, and scrollbar configuration into `ConfigActions.zig` for
  [#12](https://github.com/fukuyori/ghostty/issues/12). Move the four existing
  diagnostics and editor-command tests with the implementation, preserving
  behavior and App's ownership of the active configuration. Verification is
  recorded in the [port log](windows-port-log.md).
- Extract Win32 title actions, the tab-title dialog, focused-window title
  synchronization, and title-change notification from `App.zig` into
  `TabTitles.zig`, preserving behavior as part of
  [#12](https://github.com/fukuyori/ghostty/issues/12). Keep the App entry
  points as forwarding methods and retain the shared tab-bar rendering and
  accessibility helpers for their later splits. Verification is recorded in
  the [port log](windows-port-log.md).
- Merge upstream through `6d53bafb1` (238 commits since `bd1c82bc5`), the
  rebranding plan's Phase 0. Adapt the D3D11 and Win32 OpenGL renderers to
  upstream's app-scoped `renderer.Device` and drop the removed WebGL backend;
  each surface still creates its own D3D11 device. Upstream's other changes
  arrive with it, including the `resize_window` action handled above. The
  conflicts, resolutions, and verification are recorded in the new
  [port log](windows-port-log.md).

### Documentation

- Select the [ghoultty image](../dist/windows/ghoultty-icon-candidate.png)
  as the Gooztty application icon
  ([#31](https://github.com/fukuyori/ghostty/issues/31)) on 2026-10-13.
  Production icon resource generation and display validation remain part of
  implementation.
- Record the final product name **Gooztty** for [#31](https://github.com/fukuyori/ghostty/issues/31),
  replacing the provisional name Gozitty. Update the rebranding plan, roadmap,
  and port log to use Gooztty and the planned `gooztty` branch and identifiers.
- Plan three branch tiers for [#31](https://github.com/fukuyori/ghostty/issues/31):
  `main` mirrors upstream, `windows` keeps the port in step with upstream, and
  a long-lived `gozitty` branch carries the rename and Gozitty's own features.
  Restructure `src/apprt/win32` incrementally on `windows` and finish it
  before `gozitty` is created
  ([#12](https://github.com/fukuyori/ghostty/issues/12)). Decide to place the
  name indirection on `windows` with `ghostty` values. Add
  `docs/windows-port-log.md` for synchronization results and port-fix
  evidence on `windows`.

- Add [#44](https://github.com/fukuyori/ghostty/issues/44) to the roadmap as
  an investigation of `kitten icat`, `diff`, `themes`, `hints`, and `transfer`;
  distinguish existing Ghostty features from unverified kitten compatibility
  and record the design and verification decisions required before implementation.
- Change the chosen product name for [#31](https://github.com/fukuyori/ghostty/issues/31)
  from ghoultty to gozitty and decide to create a new icon instead of using the
  ghoultty candidate. Update the rebranding plan and roadmap, and create the
  `rebrand/gozitty` work branch locally from `windows`. Keep the repository
  name `fukuyori/ghostty` for now. Decide the install directory
  `{autopf}\Gozitty` and a new installer AppId, so Gozitty installs beside the
  old Ghostty instead of upgrading it. Drop the
  coexistence and shared-configuration requirement with an official Windows
  Ghostty and plan to remove the `ghostty` name from configuration paths,
  `TERM` and terminfo, environment variables, resources, and terminal-reported
  identifiers. The application has not been renamed.

## 1.3.2-windows.14

Released 2026-09-29. This preview preserves native Win32 key identity through
ConPTY instead of reducing keys such as Ctrl+Space to legacy control bytes.

### Fixed

- Implement DEC private mode 9001 (Win32 input mode), carrying virtual-key,
  scan-code, Unicode, key-down, control-state, and repeat-count fields through
  both physical-key and translated-character paths. Kitty keyboard encoding
  remains higher priority, and non-Windows or metadata-free events retain the
  existing encoding behavior. This prevents ConPTY from reconstructing a
  legacy Ctrl+Space NUL as Ctrl+Shift+2 (`e31ffe00d`, #43).

### Documentation

- Record the mode-negotiation design, snapshot compatibility consideration,
  targeted and full-suite results, bundled and OS ConPTY checks, and physical
  Ctrl+Space, ordinary text, modifier-only, binding, and Microsoft IME input
  evidence (`e31ffe00d`).

## 1.3.2-windows.13

Released 2026-09-28. This preview improves Windows font selection and
fallback, fixes three Win32 correctness issues, and adds the scoped
`+new-tab -e` IPC implementation.

### Fixes

- Select configured Windows font faces by the requested Regular, Bold, Italic,
  or Bold Italic traits instead of accepting the first file with a matching
  family name. Explicit `font-style` values are matched exactly; unavailable
  styles remain available to the shared synthetic-style completion path.
  System fallback ordering is unchanged (`5db47657a`).
- Suppress duplicate translated Ctrl+Space input while preserving unconsumed
  control-key handling and Japanese IME conversion (`5d3c06231`).
- Keep the Windows Shift+Insert default bound to clipboard paste instead of
  replacing it with the unsupported selection clipboard action
  (`0472bb8f9`).
- Release the Windows renderer frame permit before publishing a potentially
  blocking health update, without changing the non-Windows callback ordering
  (`731dd720b`).
- Treat expected ConPTY pipe closure as normal completion and report unexpected
  `ReadFile` failures instead of reaching `unreachable` (`95cb7246b`).

### Added

- Use DirectWrite `MapCharacters` for Windows system font fallback, preserving
  the configured-font and embedded-emoji priority while following the user's
  locale for characters not covered there. Convert the selected face to a
  local path and face index for FreeType, serialize shared DirectWrite access,
  and fall back to memory loading when FreeType cannot open a Unicode path
  (`6d08fc9f8`, `16f6ece01`).
- Add secure Win32 IPC for `ghostty.exe +new-tab -e <command>`. The versioned,
  bounded protocol runs over a same-logon-session named pipe, rejects remote
  clients, posts creation to the UI thread, supports GTK-compatible command,
  title, working-directory, and shell-integration overrides, and reports
  target fallback and timeout outcomes (`c1330c1f9`, `e575087f9`,
  `4ce993273`).

### Documentation

- Record Windows font-family diagnostics, configured style selection, fallback
  sizing, DirectWrite fallback design and acceptance, Ctrl+Space acceptance,
  the ordered correctness work, and the completed `+new-tab -e` IPC
  verification in the Windows roadmap and guide (`30b9b0696`, `c93c4e1a1`,
  `38889b09f`, `4da126dce`, and subsequent roadmap updates).

## 1.3.2-windows.12

Released 2026-09-26. This preview adds the native command palette, per-pane
overlay scrollbars, and Explorer file and directory drop support. It also
extends the Windows native regression and soak coverage for those features.

### Windows features in development

- Record the 2026-09-26 F1-F3 verification checkpoint: F1 controlled palette
  checks and owner-confirmed navigation, F2 controlled overlay rendering and
  owner-reported drag operation, and F3 real Explorer quoting, cmd rejection,
  pane targeting, and the elevated-window limit. A subsequent controlled run
  verified that an IME-consumed Enter does not execute a palette entry, that
  an open palette survives config reload, and that `scrollbar = never` removes
  the overlay and `system` restores it. A five-run repetition passed all of
  those controlled checks with clean exits and no forced termination. A later
  split-pane check found that divider hover consumed the left pane's right-edge
  hover before its scrollbar could reveal; scrollbar hover now runs first.
  Five consecutive post-fix runs verified independent per-pane reveal and
  maximize/restore layout tracking with clean exits. The full Debug test suite
  then passed all 91 build steps and 3874 tests, with 62 skipped. Its first run
  exposed an incorrect command-palette matcher assertion: `rld cfg` is an
  ordered subsequence of `Reload Configuration`, so the expectation was
  corrected and the focused and full reruns passed. A final Debug build and
  combined F1/F2 native regression then passed with exit code 0 and no forced
  termination; the palette and single/split scrollbar captures were inspected.
  The Win32 test-hook suite also passed 149 of 150 tests with one skipped.
  All four detected monitors reported 96 DPI, so this is not mixed-DPI
  evidence. The owner then confirmed with physical Japanese IME input that
  conversion Enter leaves the palette open without executing a command; the
  captured palette still contained the confirmed query. High-contrast captures
  then confirmed readable palette controls and a distinguishable overlay
  scrollbar thumb before normal display was restored. During a final F3 check,
  a normal Explorer drag remained stable when its target Ghostty closed after
  a scheduled 20-second shell exit; canceling the drag left Explorer working
  normally. Finally, monitor 3 was changed from 96 to 120 DPI: the automated
  multi-monitor run tracked the new DPI and scaled layout, and captures showed
  the F1 palette and F2 scrollbar correctly scaled at 125%. The monitor was
  restored to 100% and a final run confirmed all four monitors at 96 DPI. This
  completes the F1-F3 acceptance checks for the current Debug implementation.
  A separate baseline-CPU ReleaseFast verification build then completed all
  128 steps and passed PE, version, icon, resource, and terminfo validation.
  Its first F1/F2 regression exposed a test-harness race that observed the
  second palette dialog before its child controls existed; the script now
  waits for both controls. The same Release executable then passed the full
  combined native regression with exit code 0 and no forced termination, and
  its palette and single/split scrollbar captures were inspected. A subsequent
  soak initially stopped because two preserved manual-evidence directories
  already existed under `zig-out/test-state`; the soak script now snapshots
  that baseline and detects additions or removals instead of requiring an
  empty root. The ReleaseFast soak then passed 20/20 iterations in 119.803
  seconds with no failed runs. The owner also dropped `README.md` from Explorer
  into the ReleaseFast executable and confirmed a quoted path was inserted
  without Enter or command execution.
- Add a native Win32 command palette with configured actions, live pane
  destinations, shortcut labels, search, and focus restoration. Controlled
  dialog display, arrow selection, dismissal, and closing the owning window
  while the palette is open are verified. Palette display is deferred until
  the invoking key callback returns so modal teardown cannot resume through a
  freed surface. A controlled IME process-key check and config reload with an
  open palette also pass. The owner confirmed new-tab action and open-tab
  jump. The owner also confirmed that physical Japanese IME conversion Enter
  leaves the palette open without executing a command. A high-contrast capture
  confirmed readable input, selection, command list, description, and buttons.
  A 125% monitor capture confirmed scaled, unclipped controls and text; a
  subsequent automated run confirmed restoration to 100%.
- Add per-pane translucent overlay scrollbars for `scrollbar = system` and
  disable them for `never`. The thumb appears during scroll or edge hover and
  hides afterward without reducing terminal width. A controlled check and
  captured pixels verify display and auto-hide. Config reload to `never`
  removes the overlay and restoring `system` recreates it. The owner reported
  OK after a manual drag sequence. Controlled split checks verify that each
  pane reveals only its own overlay and that both overlays follow pane geometry
  through maximize and restore. Right-edge hover is evaluated before divider
  hover so an internal left pane can reveal its overlay. Controlled pixel
  measurements verify thumb movement for top/bottom/page keys, wheel input,
  and search-result navigation. Controlled alternate-screen checks verify that
  the history overlay stays hidden there and becomes available after returning
  to the normal screen. Controlled drag checks record the requested and actual
  thumb position and survive both new output and closing a temporary pane while
  it owns the drag. A dedicated 64-line-limit process confirms that empty
  history cannot reveal the overlay and that 2000 produced rows trim to a
  recent 29-row history while keeping a usable thumb. The owner completed the
  real-pointer acceptance check by revealing the overlay at the pane edge,
  dragging the thumb to older output, releasing it, and confirming that it
  hides after pointer departure.
  A high-contrast capture confirmed that the thumb remains distinguishable
  from the terminal background. A 125% monitor capture then confirmed that the
  overlay width, position, and thumb scale without clipping or displacement;
  a subsequent automated run confirmed restoration to 100%.
- Accept Explorer file and directory drops on terminal panes. Quote paths for
  the configured PowerShell or cmd startup shell, reject cmd paths containing
  `%` or `!` with a warning, and use core paste protection. An Explorer drop
  into PowerShell was captured for single and multiple files, including
  apostrophe escaping, without Enter. A subsequent `%`-path screenshot came
  from installed Ghostty with a `pwsh.exe` child. The owner then captured the
  `%` and `!` rejection warnings from development builds with `cmd.exe`
  children. The owner also reported cmd double quoting without Enter in a
  development build and confirmed right-split-only delivery. Control-character
  rejection before core paste has a unit regression check. A real check found
  that an elevated test window did not accept a drop from normal Explorer;
  the user guide records this limit. In the target-window closure check, the
  owner held a real Explorer drag over a normal Debug window until its shell
  exited after 20 seconds. The window closed, the drag was canceled, and
  Explorer showed no error or abnormal behavior.
- Update the window-state regression script to identify terminal children by
  class so other controls do not inflate the pane count. Add optional command
  palette and overlay-scrollbar display, position-sync, split-independence, and
  alternate-screen, drag-race, history-boundary, and resize checks. Wait for
  the palette edit and list controls after the dialog HWND appears so the
  ReleaseFast build cannot race dialog initialization. Preserve pre-existing
  manual test-state evidence during soak runs while requiring the entry set to
  remain unchanged after every iteration.

### Documentation

- Translate the rebranding plan, upstream feature plan, technical comparison,
  and the roadmap's repository-operation section into English. Keep the
  documented decisions, issue links, and historical release records intact.

- Add the [Windows upstream feature development plan](windows-upstream-feature-plan.md)
  with priorities, compatibility boundaries, dependencies, and acceptance
  checks for features shared by upstream Ghostty and noctty but missing from
  this fork's Windows runtime. Link it from the roadmap. No runtime changes.
- Track F1-F8 in fork issues: extend #17, #23, #24, and #21 with the plan,
  create #32-#35, and record the issue links in the development plan.
- Integrate the feature plan into the roadmap as Phase 7. Keep the original
  six phases' completion history, current rebranding priority, and open
  hardware verification distinct from the unstarted F1-F8 work.

- Add the [Windows rebranding plan](windows-rebranding-plan.md) for #31,
  covering name decisions, official Windows Ghostty coexistence, shared
  configuration, migration, and release acceptance checks. No runtime changes.

- Record the selected ghoultty icon candidate in the rebranding plan and
  add its transparent PNG for use when the name change is implemented. The
  current application icon remains unchanged.

- Record ghoultty as the chosen product name. First establish the branch
  workflow and develop on a rebrand/ghoultty branch from windows. Keep main
  as an upstream mirror and windows as the Windows development and release
  branch. Rename the GitHub repository only after implementation and
  integration, before final release-candidate validation; the destination
  name remains undecided. The work branch has not been created, and neither
  the repository nor the application has been renamed.

## 1.3.2-windows.11

Windows preview published 2026-09-22. Includes the upstream merge
and Windows usability changes below. Verification results are recorded in
the release notes and roadmap. This preview retains the current product
name; renaming and rebranding are the highest priority starting with the
next release, tracked in [#31](https://github.com/fukuyori/ghostty/issues/31).

### Windows terminal usability (2026-09-22, `969d637e3`)

- Avoid automatically selecting a whole space-filled row on Windows
  right-click. Keep the context menu, word/link selection on text, and
  existing selections. Double-click selection is unchanged.
- Configure the ConPTY execution backend to keep scrollback out of the
  active screen on resize. Preserve this setting across a terminal reset.
- Accept OSC 7 notifications for local native Windows drive paths, including
  percent-encoded spaces and Unicode, and use them with the existing window,
  tab, and split working-directory inheritance settings. Reject remote hosts
  and paths that cannot be represented as a native local drive path.
- Add a per-pane native search bar using the shared search engine. Support
  scrollback, Unicode queries, match counts, next/previous navigation, and
  Escape to return to the terminal. Retain each pane's query across tab changes.
- Apply terminal mouse cursor shapes and `mouse-hide-while-typing` using
  Windows system cursors, without changing the global cursor visibility counter.

### Verification tooling

- Add controlled native checks for search, cwd inheritance, cursor behavior,
  resize, and blank-row context menus. Retain reproduction inputs under
  `zig-out/test-fixtures` so they do not conflict with the soak test's
  temporary-file cleanup checks. Record cursor and window state on pointer
  check timeouts. Preserve the initial-grid subprocess's logs and capture
  its window and input files on failure.

### Upstream integration (2026-09-22)

- Merge upstream `main` at `bd1c82bc5` (142 commits since the previous
  upstream baseline). This includes the Bash command-status and prompt-hook
  fixes, terminal mode-query fixes, Unicode data update, and the terminal
  API option for disabling scrollback pull during resize. The new resize
  option was initially merged with its upstream default; the Windows
  usability changes above now enable it for ConPTY.
- Preserve the Win32 WGL context and window-buffer presentation path while
  adopting upstream's renderer-thread GPU initialization. Keep D3D11 device
  recovery and release its shader pipelines on renderer-thread shutdown.
- Exclude POSIX-only translated headers from Windows builds. Retain the
  fork's removal of upstream-only GitHub workflows and vouch configuration.

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
