# Windows Port Log

This log records each upstream synchronization into `windows` and the
evidence for port fixes made on `windows`. Only `windows` edits this file;
`gooztty` takes it unchanged through merges (see Section 1.2 of the
[rebranding plan](windows-rebranding-plan.md)). Newest entries come first.

## 2026-10-14: Parity fixture key releases and full regression

- Apply the diagnosed fixture correction to `scripts/test-windows-parity.ps1`:
  pair every synthetic `WM_CHAR` with a `WM_KEYUP`, mapping the virtual key
  with the target thread's keyboard layout. Check message-posting failures.
  No character delay is added. The post-search marker now checks the exact
  repeated-character payload `ok::All-ghostty-aaa-bbbb-1111`.
- Keep the .NET diagnosis separate: the fixture avoids coalesced key-down
  records for synthetic typing; it does not change the managed reader or
  Ghostty's product input code. Physical auto-repeat and IME remain outside
  this automated check.
- Both initial full runs passed, with cwd inheritance enabled and disabled
  (`parity-20261014-150555-733` and `parity-20261014-150612-089` under
  `zig-out/logs`). Their captures were partly covered by another window.
  The script now makes only its dedicated window topmost during capture,
  without activation, and removes topmost status in `finally`.
- Final full runs both passed, exit 0, without forced termination:
  - Inheritance enabled: `zig-out/logs/parity-20261014-150656-413.json`.
  - Inheritance disabled: `zig-out/logs/parity-20261014-150710-788.json`.
  - Copies: `zig-out/logs/parity-keyup-enabled.json` and
    `zig-out/logs/parity-keyup-disabled.json`.
- The full checks include search navigation, Unicode, empty/no-match queries,
  refocus/reopen, eight resize cycles, exact post-search terminal input,
  cursor shape and hide/restore, tab/split search isolation and close, and
  cwd behavior for new windows/tabs/splits. Both final PNGs were inspected:
  the search controls and highlighted matches are unobscured. No dedicated
  Ghostty process remained; the existing installed instance was preserved.
- PowerShell parsing and `git diff --check` passed. No executable rebuild was
  needed for this script-only follow-up. Tests used the prior SearchBar
  extraction's Debug executable, SHA-256
  `8691C466EDE7DDB65E3B14C02C6C1926BF5C8C4CA9D39FA0B3D62D615322C5E0`.
  The build/Win32/window-state results for that executable are below. This
  completes the automated parity checks for the extraction; grouped physical
  input/IME and release acceptance remain separate.

## 2026-10-14: Synthetic-input duplication diagnosis

- Environment: PowerShell 7.6.6, .NET 10.0.12; the same Debug executable
  used for the SearchBar extraction below. No search bar is needed for the
  minimal reproduction. The fixture sends a known string as rapid `WM_CHAR`
  messages, then lets the child consume the buffered input.
- `ReadConsoleInputW` receives the exact string when each record is expanded
  by `RepeatCount`. Adjacent identical key-down records are coalesced (for
  example, two colons become one record with count 2). `Console.ReadKey`
  returns one extra character for each coalesced run: `::` becomes `:::`,
  `All` becomes `Alll`, and `ghostty` becomes `ghosttty`.
- The .NET source confirms an off-by-one in the cached-repeat path: the
  zero-count cached event is still returned before the cache is cleared.
  See [ConsolePal.Windows.cs at v10.0.12, lines 328-401](https://github.com/dotnet/runtime/blob/v10.0.12/src/libraries/System.Console/src/System/ConsolePal.Windows.cs#L328-L401).
  A child-local `WriteConsoleInputW` injection of one colon record with count
  2 plus a sentinel also yields three colons through `Console.ReadKey`,
  without sending any Ghostty input messages. This isolates the extra
  character to the managed reader in this environment.
- The parity fixture sends character messages without key releases. A
  candidate fixture change appends a matching `WM_KEYUP` after each
  character, using the target thread's keyboard layout to map the virtual
  key. With no pacing, both raw and managed readers then return the exact
  string. This avoids the coalesced-repeat case for synthetic typing; it
  does not fix .NET or establish physical auto-repeat behavior.
- Evidence is retained under `zig-out/test-fixtures/input-duplication/`:
  `20261014-145930-857-{Raw,ReadKey}.json` (original comparison),
  `20261014-150053-066-keyup-True-{Raw,ReadKey}.json` (release-paired input),
  and `20261014-150207-376-keyup-False-InjectedReadKey.json` (direct injection).
  The reader, native declarations, and runners are in that directory.
  All completed comparisons exited 0. The first direct-injection probe
  timed out because its PowerShell value-type records were not assigned
  back to the array; the corrected probe above completed.
- The candidate change also passed the search-focused parity copy, without
  character delays: `zig-out/test-fixtures/search-actions-search-keyup.ps1`.
  See `zig-out/logs/search-actions-search-keyup.log` and its referenced JSON
  for search, resize, post-search command, tab/split isolation, and close.
  Exit was 0; no dedicated Ghostty process remained. Cursor checks were
  omitted as in the previous search-focused copy, so this is not a full
  parity pass. The tracked test script and product input code have not been
  changed by this investigation. The subsequent entry above records the
  tracked fixture correction and the completed full parity checks.

## 2026-10-14: Search-action extraction (#12)

- Move `start_search`, `end_search`, `search_total`, and `search_selected`
  handling from `App.performAction` to the existing `SearchBar.zig`.
  App forwards to `startSearch`, `endSearch`, and `updateResults`.
- Preserve lazy allocation and its failure cleanup, Surface ownership,
  start/layout/focus and stop/layout order, and result/status updates.
  A source comparison against `02a5816a3` found the three extracted bodies
  identical after module/type/parameter qualification and whitespace
  normalization. Existing native controls, message filtering, pane layout,
  focus helpers, and core search behavior are unchanged.

### Verification

- Debug build: 128/128 steps succeeded
  (`zig-out/logs/search-actions-build.log`). Win32 tests with hooks:
  91/91 steps succeeded, 178 passed and one skipped
  (`zig-out/logs/search-actions-win32-tests.log`).
- The unmodified window-state regression passed with exit 0 and no forced
  termination (`zig-out/logs/search-actions-window-state.json`).
- The unmodified parity regression reached search navigation, Unicode,
  empty/no-match queries, eight resize cycles, and Escape dismissal, then
  timed out waiting for the post-search command's output file. Run prefix:
  `zig-out/logs/parity-20261014-144805-494`. Its search capture was inspected.
- A diagnostic copy captured the failed command: repeated characters in
  synthetic terminal input caused a PowerShell ParserError. Increasing the
  timeout to 30 seconds did not resolve it. Failure capture:
  `zig-out/logs/parity-20261014-144854-660.failure.png`; cleanup exited 0.
  The saved pre-extraction recovery-hook executable reproduced the same
  failure, also exiting 0 during cleanup:
  `zig-out/logs/parity-20261014-144946-797.failure.png`. That executable's
  SHA-256 is
  `05A26A6ADDC6BDB77F21E3D22026F4481A8644D0C7B3E52C0568DF8FDD9D8CA5`.
  At this stage the cause remained unconfirmed; the subsequent diagnosis
  above isolates it to .NET's cached repeat handling.
- A temporary copy with 25 ms between synthetic characters passed the
  post-search input check, then failed the pointer-hide check. Its diagnostic
  reported the pointer over `MozillaWindowClass`, outside the test surface;
  the capture was partly obscured. See
  `zig-out/logs/search-actions-parity-paced.log`; cleanup exited 0.
- A search-focused copy retained that pacing and omitted cursor checks and
  pointer movement. Search navigation, Unicode (two matches), scrollback
  (three matches), empty/no-match queries, refocusing/reopening, eight
  resize cycles, post-search terminal input, independent tab/split queries,
  tab visibility, and closing a searching pane passed. Cwd inheritance for
  windows/tabs/splits also passed. Summary:
  `zig-out/logs/parity-20261014-145122-364.json`; the temporary script is
  `zig-out/test-fixtures/search-actions-search-check.ps1`. The dedicated
  process exited 0 without forced termination.
- These are Debug checks using synthetic input. They do not establish a
  pass for the unmodified full parity script, physical IME/input, or release
  acceptance. The rapid-input failure is investigated in the later entry
  above; grouped manual checks remain due.
- Tested `zig-out/bin/ghostty.exe`, working tree based on `02a5816a3`, SHA-256:
  `8691C466EDE7DDB65E3B14C02C6C1926BF5C8C4CA9D39FA0B3D62D615322C5E0`.

## 2026-10-14: Defer configuration diagnostics past core callbacks

- **Reproduction:** start with a valid configuration, change `font-size` to
  an invalid value, trigger `reload_config`, then close the parent window
  while its error dialog is open. No split, blur, or high-contrast operation
  is required. The normal Debug executable used for the WindowAppearance
  checks exited 3; its log shows the Surface closing before a segmentation
  fault in `Surface.endKeySequence`.
- **Cause:** `ConfigActions.reloadConfig` called `MessageBoxW` synchronously
  inside `Surface.keyCallback`. The modal loop dispatched the owner-close
  request and freed the Surface, then returned into key processing that
  still accessed it. The core treats `reload_config` as a non-closing action,
  so its usual early return for a closing binding could not protect it.
- **Fix:** queue an owned UTF-16 diagnostic snapshot and its parent HWND.
  `App.run` drains the queue outside core callbacks; a wakeup-window timer,
  following the existing ShellOpen pattern, ensures that requests queued
  in another modal loop reach the outer loop. Repeated reloads append
  requests instead of nesting message boxes. Closed owners and quit discard
  pending diagnostics; termination frees remaining text and cancels the
  timer. No Surface/core pointer is retained and shared core code is unchanged.
- The saved pre-WindowAppearance recovery-hook executable also failed the
  minimal regression with exit 3. Thus the diagnostic lifetime defect was
  present before that extraction. Its hash and run are recorded below.

### Verification

- Baseline normal Debug SHA-256:
  `60CB4D5C6C7E2489B61960EBAADC1C11D639A86E5E56B76D2DE76F2AF819FA72`.
  Reproduction summary:
  `zig-out/logs/config-diagnostics-close-20261014-142931.json`.
  The corresponding `.stderr.log` contains the crash stack.
- Saved pre-WindowAppearance Debug with hooks, SHA-256
  `05A26A6ADDC6BDB77F21E3D22026F4481A8644D0C7B3E52C0568DF8FDD9D8CA5`,
  failed `ReloadClose` with exit 3 and no forced termination. Summary:
  `zig-out/logs/config-diagnostics-20261014-143658-121.json`.
- Final Debug build: 128/128 steps succeeded
  (`zig-out/logs/config-diagnostics-build.log`). Win32 tests with hooks:
  91/91 steps succeeded, 178 passed and one skipped
  (`zig-out/logs/config-diagnostics-win32-tests.log`). Four added unit tests
  cover owned text/FIFO order, discard and reuse, invalid UTF-8, and every
  allocation failure when queuing the first diagnostic.
- Added `scripts/test-windows-config-diagnostics.ps1`. All eight scenarios
  passed: startup close, reload close, dismissal and valid reload, repeated
  reloads with distinct diagnostic snapshots, queued-owner close, owner
  close with a surviving second window, child-shell exit, and reload while
  the command palette is open. Each exited 0 with no forced termination.
  Summary: `zig-out/logs/config-diagnostics-20261014-143819-380.json` (also
  `zig-out/logs/config-diagnostics-regression.json`). Startup, reload, and
  palette-followup dialog captures with that prefix were inspected.
- During test development, posting a dialog command or assuming button ID 1
  failed to dismiss the system message box. The script now enumerates its
  single native button and posts a button click. These harness failures
  exited cleanly during cleanup; the final run above uses the corrected
  dismissal. This is separate from the baseline exit-3 product failure.
- The unmodified window-state regression also passed, exit 0 and no forced
  termination (`zig-out/logs/config-diagnostics-window-state.json`). No
  dedicated Ghostty processes remained. The regression uses synthetic
  messages and controlled shell exit; it does not establish physical-input
  or release-build acceptance.
- Final tested `zig-out/bin/ghostty.exe`, Debug working tree based on
  `44d5b1059`, SHA-256:
  `D7E4A6EBDB9973230A741A793ADA0FAFD57289C5BC9197D53B77C6607C3CFD20`.

## 2026-10-14: Window-appearance extraction (#12)

- Move background-blur policy, cleanup and fallback, high-contrast detection,
  and the setting/system-color/theme-change handler from App to
  `WindowAppearance.zig`. App and ConfigActions call the extracted entry
  points. Composition objects stay in Backdrop, and App/Window/Surface keep
  their state and teardown order.
- Expose App's existing window lookup and divider invalidation helpers for
  the extracted theme handler. Preserve its parent-window guard and refresh
  order: high-contrast state, titlebar, scrollbars, layout, tab bar, dividers.
- Move the existing blur-policy test unchanged and register the module in
  the Win32 test imports and App's comptime block.

### Verification

- Debug `zig build --summary all`: 128/128 steps succeeded. Log:
  `zig-out/logs/window-appearance-build.log`.
- Comparison against
  `zig-out/test-fixtures/window-appearance-split/App.before.zig` confirmed
  all eight extracted function bodies and the existing test body are
  unchanged. The theme handler differs only in module qualification and
  indentation. Formatting and `git diff --check` completed successfully.
- Win32 tests with hooks: 91/91 steps succeeded, 174 passed and one skipped.
  Log: `zig-out/logs/window-appearance-win32-tests.log`. The unmodified
  window-state regression passed on the normal Debug executable, exit 0,
  no forced termination. Summary:
  `zig-out/logs/window-appearance-window-state.json`.
- Dedicated fixture `zig-out/test-fixtures/window-appearance-split/check.ps1`
  uses an isolated config and a checkerboard window behind the terminal.
  Valid-config runs passed blur off, radius 12, radius 40, disable, opacity
  1, re-enable, and split-pane appearance. The larger 160-pixel checkerboard
  distinguishes the two radii visually. Its text-free sample's red-channel
  standard deviation was 33.00 without blur, 18.08 at radius 12, and 10.50
  at radius 40; the disabled sample matched the initial sample exactly.
  At opacity 1 the sample was uniformly RGB(16, 32, 48), the configured
  background. Measurements:
  `zig-out/logs/window-appearance-20261014-142442.pixels.json`.
- Setting-change, system-color-change, and theme-change messages each
  restored the configured caption color after a deliberate native-color
  change on the test window. Enabling Windows high contrast changed divider
  width from 1 to 2 pixels and changed titlebar, tab-bar, and scrollbar
  appearance; restoring it returned the divider to 1 pixel and restored the
  configured appearance. Original and final system contrast flags were both
  126; settings were not persisted to the user profile.
- Final run explicitly revealed both overlay scrollbars for capture.
  Summary: `zig-out/logs/window-appearance-20261014-142542.json`. Inspected
  split, high-contrast, and restored captures with that prefix show the
  scrollbars, tab bar, and divider. Blur/opaque captures from the preceding
  successful runs at `142322` and `142442` were also inspected. Successful
  fixture runs exited 0 without forced termination; no dedicated test
  processes remained. The Acrylic fallback was not forced; grouped manual
  checks remain due.
- Fixture corrections: DWM attribute reads for host backdrop and caption/text
  color returned `E_INVALIDARG`, so caption verification uses captured pixels.
  The pixel helper required integer promotion before RGB shifts, and divider
  lookup needed owned top-level windows rather than child-window enumeration.
  These corrections changed only the temporary fixture.
- Built executable: `zig-out/bin/ghostty.exe`, Debug working tree based on
  `b115fb108`, SHA-256
  `60CB4D5C6C7E2489B61960EBAADC1C11D639A86E5E56B76D2DE76F2AF819FA72`.

### Finding requiring investigation

- The initial fixture incorrectly used `scrollbar = always` (supported
  values are `system` and `never`). It sent repeated reloads, created a split,
  and sent `close_all_windows` while configuration diagnostics were still
  open. The run at `20261014-142221` exited 3 with a segmentation fault in
  `Surface.endKeySequence`; its stack includes nested
  `ConfigActions.showConfigDiagnostics`/`MessageBoxW` calls. Preserve
  `zig-out/logs/window-appearance-20261014-142221.stderr.log` and captures
  with that prefix as the failed-run evidence. The fixture now validates
  every configuration with `+validate-config`, uses `scrollbar = system`,
  and rejects an unexpected modal dialog before each capture.
- Correcting the fixture yielded the successful valid-config runs above;
  it does not establish that the invalid-config/modal-close crash is fixed.
  The cause and regression status were unproven at this stage. The subsequent
  investigation and diagnostic queue fix are recorded in the entry above,
  separately from this extraction.

## 2026-10-14: Recovery extraction (#12)

- Move GPU recovery scheduling and its cycle budget, power suspend/resume
  handling, and the recovery test-message IDs and handlers to `Recovery.zig`.
  App keeps action/window-message dispatch, startup hook settings, and its
  state fields; Surface keeps its counters. Expose App's existing HWND lookup
  for the extracted handlers without changing it.
- Move the power-event classification test unchanged and register the module
  in the Win32 test imports and App's comptime block. Comparison against the
  pre-extraction snapshot confirmed that function and handler bodies differ
  only in qualification, public declarations, and indentation. Preserve the
  compile-time hook gate, runtime opt-in, `DefWindowProcW` fallback, and
  parent-window-only power dispatch.
- The restructuring remains in progress; `WindowAppearance.zig` is next.

### Verification

- Normal Debug and `-Dwin32-test-hooks=true --prefix zig-out/recovery-hooks`
  builds each passed 128/128 steps. Logs: `zig-out/logs/recovery-build.log`
  and `zig-out/logs/recovery-hooks-build.log`.
- Win32 tests with hooks: 91/91 steps succeeded, 174 passed and one skipped
  (`zig-out/logs/recovery-win32-tests.log`). The unmodified window-state
  regression passed on `zig-out/bin/ghostty.exe`, exit code 0, no forced
  termination (`zig-out/logs/recovery-window-state.json`).
- The hook build passed window-state regression with `-TestGpuRecovery
  -GpuRecoveryIterations 3 -GpuRecoveryFailures 2 -TestPowerResume`: three
  GPU recoveries, terminal continuity, all three surfaces after power
  resume, and duplicate-resume suppression. Logs show the injected failures
  retrying after 100 ms and 250 ms. The temporary copy at
  `zig-out/test-fixtures/recovery-split/window-state-capture.ps1` changes
  the repository-root lookup and adds a topmost-window capture after the
  single-surface GPU/power recovery stage; its regression checks are unchanged.
  Summary: `zig-out/logs/recovery-hooks-window-state.json`; inspected capture:
  `zig-out/logs/window-state-20261014-140627-756-a68677bb.recovery.png`.
- Dedicated disabled-hook probes returned zero for both the enable probe
  and the status after a recovery request: normal build with the environment
  opt-in set to 1, and hook build with it set to 0. Summaries:
  `zig-out/logs/recovery-normal-disabled.json` and
  `zig-out/logs/recovery-hooks-disabled.json`.
- Every successful GUI run exited 0 without forced termination; no dedicated
  test processes remained. These are injected GPU failures and synthetic
  power notifications, not actual device loss or system suspend. Grouped
  manual checks remain due.
- Executables are Debug working trees based on `c4671a659` with all three
  extractions. Normal SHA-256:
  `10E73BF49F3F5AB839949142FDF800F3EC9F923A7413824B4104C26AA60B0DD1`.
  Hook-enabled SHA-256:
  `05A26A6ADDC6BDB77F21E3D22026F4481A8644D0C7B3E52C0568DF8FDD9D8CA5`.
  The hook-enabled executable is for regression use only.

## 2026-10-14: Configuration-action extraction (#12)

- Move configuration reload and update, `config_change`, startup/reload
  diagnostics, configuration editor launch, and scrollbar configuration from
  `App.zig` to `ConfigActions.zig`. App retains configuration ownership and
  dispatches to the module. Window creation, layout, and background-blur
  helpers stay in App and are exposed until their planned extraction.
- Move all four existing diagnostics and editor-command tests unchanged and
  register the module in the Win32 test imports and App's comptime block.
  Comparing the extracted bodies with the pre-extraction working-tree snapshot
  confirmed only module qualification, public entry declarations, and
  indentation changed. The preceding `TabTitles.zig` extraction is retained.
- The restructuring remains in progress; `Recovery.zig` is next.

### Verification

- Debug build: 128/128 steps succeeded
  (`zig-out/logs/config-actions-build.log`). Win32 tests with hooks: 91/91
  steps succeeded, 174 passed and one skipped
  (`zig-out/logs/config-actions-win32-tests.log`).
- Unmodified `scripts/test-windows-window-state.ps1`, using
  `-Executable zig-out/bin/ghostty.exe`: passed, exit code 0, no forced
  termination. Summary: `zig-out/logs/config-actions-window-state.json`.
- The first extended run with `-TestCommandPalette -TestOverlayScrollbar`
  could not measure the bottom scrollbar position. Its saved screenshot
  showed another app covering the test window. A temporary copy,
  `zig-out/test-fixtures/config-actions-split/window-state-topmost.ps1`,
  adjusts the repository-root lookup and makes the dedicated test window
  and measured scrollbars topmost. The checks themselves are unchanged.
  This run passed, including palette reload, scrollbar removal/recreation
  across `never`/`system`, position synchronization, split independence,
  and drag races. Exit code 0, no forced termination. Summary:
  `zig-out/logs/config-actions-window-state-topmost.json`. Palette and
  single/split scrollbar PNGs under
  `zig-out/logs/window-state-20261014-135936-521-82269d57` were inspected.
- Dedicated fixture `zig-out/test-fixtures/config-actions-split/check.ps1`:
  startup and reload diagnostics were displayed and dismissed; a valid
  reload showed no diagnostic. `open_config:new_window` used `VISUAL`
  ahead of an invalid `EDITOR` fallback and passed the exact Japanese,
  space-containing configuration path to a mock editor. The child process
  used an isolated `XDG_CONFIG_HOME` inside the fixture. Summary:
  `zig-out/logs/config-actions-20261014-135906.json`; the startup/reload
  diagnostic and valid-config captures with that prefix were inspected.
  Exit code 0, no forced termination. The OS-associated editor route was
  not exercised. These are controlled checks, not physical input acceptance;
  the planned grouped manual checks remain due.
- Tested executable: `zig-out/bin/ghostty.exe`, Debug working tree based on
  `c4671a659` with both extractions, SHA-256
  `BE26546A1B935C096A424359CFFFED429F8BFAE0EDCA2220B338FFCFBCDF7617`.

## 2026-10-14: Tab-title extraction (#12)

- Move title actions, the tab-title dialog and its constants, focused-window
  title synchronization, and title-change notification from `App.zig` into
  `TabTitles.zig`. App retains forwarding entry points for the surface API;
  action dispatch and tab-bar double-click handling call the module directly.
- Preserve allocation, error handling, dialog results, ownership lookups,
  title precedence, and the order of repaint and accessibility notifications.
  The shared tab-bar helpers remain in App and are exposed for this module
  until their planned extraction. Register the new module in App's comptime
  block and the Win32 test imports. Existing title-model tests remain with
  `Tab.zig`.
- The restructuring is still in progress. `ConfigActions.zig` is the next
  group; the final cross-module and grouped manual checks remain due.

### Verification

- Debug `zig build --summary all`: 128/128 steps succeeded.
- `zig build test -Dtest-filter=Win32 -Dwin32-test-hooks=true --summary all`:
  91/91 steps succeeded; 174 tests passed and one skipped. Log:
  `zig-out/logs/tab-titles-win32-tests.log`.
- `scripts/test-windows-window-state.ps1 -Executable zig-out/bin/ghostty.exe`:
  passed, exit code 0, no forced termination. Summary:
  `zig-out/logs/tab-titles-window-state.json`.
- A dedicated fixture, `zig-out/test-fixtures/tab-titles-split/check.ps1`,
  exercised OSC window titles, `set_tab_title`, override retention across OSC
  updates, clearing an override, the tab-bar double-click dialog, accepting a
  Japanese title, opening the dialog through `prompt_tab_title` and cancelling,
  and title restoration across two tabs. It checked the window title and
  tab-bar accessible name, exited 0, and required no forced termination.
  Final summary: `zig-out/logs/tab-titles-20261014-135111.json`. The `.dialog.png`
  and `.renamed.png` captures with the same prefix were inspected and show
  the Japanese text in the dialog, tab bar, and window title. Input was
  synthetic; this is not physical keyboard/IME acceptance evidence.
- Tested executable: `zig-out/bin/ghostty.exe`, Debug working tree based on
  `c4671a659`, SHA-256
  `E4545914F48BF9D914039D860EB5D2506F71E341B2FE98DD0D9EA9A23CF09C49`.

## 2026-10-12: Debug panic on plain-text URLs (#47)

- **Defect:** `Surface.resolvePathForOpening` joins plain-text link text to
  the pwd and calls `accessAbsolute`. A joined URL contains `:` past the
  drive, NT returns `OBJECT_NAME_INVALID`, and Zig's std panics in Debug.
  Reproduced by automated input and by hand on a Debug build; a ReleaseFast
  build of the same commit opened the URL without a panic.
- **Fix:** shared core, Windows only. `src/os/windows_path.zig` (fork-only)
  adds `isCheckable` (forbidden characters including `:`, components over 255
  UTF-16 units, paths over 32000 units, invalid WTF-8);
  `resolvePathForOpening` returns null for a path it rejects or one that
  stays relative after `resolve`. `src/os/main.zig` exports the module and
  references it in its Windows test block.
- **Review:** Codex found that the first version let a 256-unit component
  (`OBJECT_NAME_INVALID`, checked with an attribute query), a path longer
  than std's 32767-unit buffer (from source), and a drive-relative path on
  another drive through; all three are now rejected. Alternate data streams
  are no longer resolved against the pwd.

### Verification

By hand on the Debug build: the plain-text `http://127.0.0.1:65530/` opened
the browser and the log has no panic; `./notes.txt` printed in a terminal
started in its directory opened in Notepad. Unit tests for valid and invalid
paths pass.

## 2026-10-12: Link opening deadlock (#36)

- **Split commit:** `openUrl`, the OSC 8 link policy and its dialogs, and
  `shellOpen` moved from `App.zig` to `ShellOpen.zig` without behavior
  changes, the second incremental split for #12. Verified with
  `zig build test` and `scripts/test-windows-window-state.ps1`.
- **Reproduction:** a fresh Debug instance showing an OSC 8 link to
  `http://127.0.0.1:9/`; two quick Ctrl+clicks left the window not
  responding, with the process alive at 0.75 s of CPU time. Reproduced by
  automated input and by hand. Two `open_config` calls (OpenWith dialog) did
  not hang in four runs.
- **Root cause:** `cdb -pv` stack of the UI thread: `mouseButtonCallback` →
  `processLinks` (renderer state mutex held) → `openUrl` → `shellOpen` →
  `ShellExecuteW` → USER32 dispatch → `wndProc` → `keyCallback` →
  `modsChanged` → `lockUncancelable` on the same mutex.
- **Fix:** `open_url` queues the request and arms a 50 ms timer on the wakeup
  window; `App.run` drains the queue at the top of its outermost loop, where
  the UI thread holds no core lock, and stops the timer. The policy dialogs
  run there; `ShellExecuteW` runs on a detached worker (COM STA with OLE1DDE
  disabled, no owner window, page allocator, failures logged with a job id
  and `GetLastError`). Queued requests are dropped once `WM_QUIT` is pending.
  Two Codex reviews shaped the design: the first found the same deadlock
  through the `MessageBoxW` dialogs (`WM_KILLFOCUS` → `focusCallback`), the
  second the worker's allocator lifetime at exit, a wakeup consumed by a
  modal loop entered from `GetMessageW`, and opens running after a quit
  request.

### Verification

- By hand on the queue revision: double Ctrl+click on an OSC 8 web link, a
  custom-scheme link with its confirmation dialog, and a `file:` link with
  the blocked dialog; the window stayed responsive and the log showed three
  shell opens without failures.
- By hand on the final revision (drain timer, quit check, worker
  allocator), with the same three links: the web link opened the browser
  twice (shell opens id 1 and 2 in the log), and both dialogs returned to a
  responsive window.
- `zig build test -Dtest-filter=Win32` and
  `scripts/test-windows-window-state.ps1` pass on the final revision.
- Separate finding: Ctrl+clicking a plain-text URL panics a Debug build in
  `Surface.resolvePathForOpening` (`OBJECT_NAME_INVALID` treated as a
  programmer bug by Zig's std).

## 2026-10-12: ConPTY size after `CSI 8 t` (#46)

- **Defect:** the bundled OpenConsole resizes its console for
  `CSI 8 ; rows ; cols t` and passes the sequence on. When Ghostty does not
  resize, the shell keeps the requested size.
- **Investigation:** nudging the window by 1px (grid unchanged) made termio
  resend the same grid with `ResizePseudoConsole`, and the console returned
  to Ghostty's size.
- **Fix:** shared core, Windows only. `Surface.resizeWindow` queues a
  `conpty_resync` IO message on every return; `termio/Thread.zig` coalesces
  it with resizes and, when no resize is pending, resizes only the backend
  to the current grid.

### Verification

Debug build, PowerShell child writing the sequence and reading
`[Console]::WindowWidth`/`WindowHeight` and the buffer size 2.5 s later, no
window nudge:

| Case | Bundled OpenConsole: shell / Ghostty | Inbox conhost: shell |
|---|---|---|
| Disabled, `CSI 8;30;100 t` | 80×24 / 80×24 | 100×30 |
| Allowed, `CSI 8;30;100 t` | 100×30 / 100×30 | 100×30 |
| Allowed, maximized | 250×67 / 250×67 | 100×30 |
| Allowed, `CSI 8;20 t` | 80×20 / 80×20 | 80×24 |
| Allowed, `CSI 8;200;400 t` | 249×66 / 249×66 (work area) | 400×200 |

With the inbox conhost the sequence did not reach Ghostty (no
`resize_window` in the log, three of three disabled runs), so nothing
triggers a resync. In the earlier #45 measurement a `resize_window` was
logged for the inbox host only after the window nudge; where it came from
was not determined. Releases ship OpenConsole, so the inbox host is used only
when `conpty.dll` and `OpenConsole.exe` are missing.

`zig build test` and `scripts/test-windows-window-state.ps1` pass. Real TUIs
and Vim were not checked.

## 2026-10-12: `resize_window` on Win32 (#45)

- **Split commit:** window state handling (maximize, fullscreen, decorations,
  always-on-top, sizing) moved from `App.zig` to `WindowState.zig` without
  behavior changes, the first incremental split for
  [#12](https://github.com/fukuyori/ghostty/issues/12). Verified with
  `zig build test` (exit 0) and `scripts/test-windows-window-state.ps1`.
- **Change:** `WindowState.resizeWindow` handles `.resize_window`. It resizes
  the window by the difference between the requested size and the surface's
  current size in device pixels and keeps the position. Only the requested
  dimensions are limited to the monitor's work area; an omitted or zero
  dimension keeps its size even when it exceeds the work area. It ignores the
  request while the window is maximized, minimized, fullscreen, or snapped,
  and when the window has more than one surface.
- **Snap detection:** `IsWindowArranged` is looked up in `user32.dll` at run
  time, because not every supported Windows 10 release exports it. Without
  it, a window whose size differs from the restore size in
  `GetWindowPlacement` is treated as snapped; that fallback misses a window
  snapped into a zone of exactly its restore size.
- **Review:** a Codex review found that the first version compared sizes
  only, missing a window snapped into a zone of its restore size, and limited
  both dimensions to the work area, shrinking an omitted dimension. Both were
  fixed before push.

### Verification

Debug build, cells 10×21 px, padding 2 px, starting at 80×24 (804×508 px):

| Case | Surface after the request |
|---|---|
| `vt-window-resize-allowed = true`, `CSI 8;30;100 t` | 1004×634 px = 100×30 |
| Default config, `CSI 8;30;100 t` | Unchanged; core logs that the request is disabled |
| Allowed, `CSI 8;20 t` | 804×424 px = 80×20, width kept |
| Allowed, started maximized | Unchanged, still maximized |
| Allowed, window widened to 3000 px (work area 2512 px), `CSI 8;20 t` | 2984×424 px: width kept, 20 rows |

`zig build test -Dtest-filter=Win32` and
`scripts/test-windows-window-state.ps1` pass. `IsWindowArranged` resolves
on the Windows 11 test machine.

Checked by hand on 2026-10-12 at `4985657fb` (Debug build, with the #46 resync
in place), alternating `CSI 8;30;100 t` and `CSI 8;24;80 t`: a single window
resized; a window snapped with Win+Left kept its snapped size; with two tabs
and with a split (made from the context menu) the window kept its size; after
closing the extra tab or pane the window resized again. Every request queued
one ConPTY resync.

ConPTY applies `CSI 8 t` to its own buffer as well: `[Console]::WindowWidth`
and `WindowHeight` inside the shell reported 100×30 in every case, including
the ones where Ghostty kept its size. When the request is ignored, the
console size the shell sees can therefore differ from Ghostty's grid until
the next resize. Tracked as
[#46](https://github.com/fukuyori/ghostty/issues/46).

## 2026-10-12: Upstream synchronization (rebranding plan Phase 0)

- **Branch:** `sync/upstream-20261012`, merged into `windows`.
- **Upstream range:** `bd1c82bc5` (2026-09-22) to `6d53bafb1` (2026-10-11),
  238 commits. `main` was fast-forwarded to `6d53bafb1`.
- **Toolchain:** Zig 0.16.0.

### Conflicts and resolutions

Upstream moved the renderer to an app-scoped `renderer.Device`, initialized
once in the core `App`, and removed the WebGL renderer.

- `src/renderer.zig`: dropped the WebGL import, kept `D3D11`, and selects
  `GraphicsAPI` from `opengl`, `metal`, and `d3d11`. `renderer.Device` is
  `GraphicsAPI.Device`.
- `src/renderer/backend.zig`: the backend enum is `opengl`, `metal`, and
  `d3d11`; Windows still defaults to `d3d11`.
- `src/renderer/D3D11.zig` and new `src/renderer/d3d11/Device.zig`: D3D11
  gets a stateless `Device` that only satisfies the interface. Each surface
  still creates its own D3D11 device and DirectComposition presenter, so
  device-loss recovery is unchanged. Sharing one D3D11 device across
  surfaces is left for a separate change.
- `src/renderer/opengl/Device.zig`: on Windows `init` leaves the device
  undefined, because Win32 uses one WGL context per surface and no EGL
  display.
- `src/renderer/OpenGL.zig`: takes the device pointer; the Windows branches
  of `init`, `deinit`, `threadEnter`, and `threadExit` never read the EGL
  fields. `present` takes upstream's new presentation-health argument and
  keeps the Windows blit path.
- `src/renderer/opengl/Frame.zig`: the Windows present call passes the
  renderer's presentation health.
- `.github/VOUCHED.td` and the flatpak, release-tag, release-tip, snap, and
  `test.yml` workflows remain deleted, as on `windows` before the merge.

The fork's ConPTY shutdown and resize handling, DEC private mode 9001,
`PageList` trailing-blank handling, and render health notifications are
preserved.

### Verification

| Check | Result |
|---|---|
| `zig build` (Debug, D3D11) | Pass; `+version` runs |
| `zig build -Drenderer=opengl` | Pass |
| `zig fmt --check`, `git diff --check` | Pass |
| `zig build test` | Pass: 4023 passed, 62 skipped, 0 failed. The runner prints "failed command" because the upstream `TerminalFormatter` benchmark test writes to stderr; the test itself passes |
| `scripts/test-windows-window-state.ps1` | Pass: input, IME process keys, initial grid, splits and click focus, config reload, four monitors, multiple windows, maximize/minimize/restore; exit code 0, no forced termination, no leftover process |
| Codex CLI review of the merge | No regression found; one upstream feature gap (below) |

### Upstream features not yet handled on Win32

- `resize_window` (`CSI 8 ; rows ; cols t`, upstream `714fe9b90`,
  `219cca932`, `3175f6733`, `211149dbc`): the Win32 `performAction` does not
  handle it, so the request is ignored. It is gated by
  `vt-window-resize-allowed`, which defaults to `false`, so default behavior
  is unchanged. To be implemented on `windows`
  ([#45](https://github.com/fukuyori/ghostty/issues/45)).
