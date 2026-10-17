# Windows Port Log

This log records each upstream synchronization into `windows` and the
evidence for port fixes made on `windows`. Only `windows` edits this file;
`gooztty` takes it unchanged through merges (see Section 1.2 of the
[rebranding plan](windows-rebranding-plan.md)). Newest entries come first.

## 2026-10-17: HTML clipboard output (F5, #34)

- The shared core provides only `text/html` for `copy_to_clipboard:html` and
  both `text/plain` and `text/html` for `mixed`. The macOS write path
  registers the supplied MIME representations, so the Windows port follows
  that behavior and does not synthesize a plain-text fallback.
- Implemented Windows `HTML Format` (CF_HTML) registration with UTF-8 byte
  offsets. The offset test covers Japanese text, a non-BMP character, and
  literal LF bytes. `zig build test '-Dtest-filter=CF_HTML'` passed after
  adding LF coverage; the MIME-selection test, Debug `zig build`, `zig fmt`,
  and `git diff --check` also passed.
- Added `scripts/test-windows-html-clipboard.ps1` as a repeatable manual
  fixture. Running it under Windows PowerShell 5.1 printed the three test
  lines with Japanese text and red foreground as intended. Its `-TestOsc52`
  option sends a known OSC 52 clipboard-write value for the remaining
  regression check.
- Claude Code reviewed the supplied working-tree diff. It found no
  high-severity defect and identified inconsistent F5 status text and a test
  description that claimed newline coverage before the test contained a
  literal newline; these documentation and test records are now aligned.
- The owner tested rich-text paste in Word; the visible paste retained
  Japanese text, line breaks, and red terminal text styling. Direct clipboard
  inspection after the HTML-only binding returned only `HTML Format`, no
  `UnicodeText`; after `mixed`, both formats were present. Both CF_HTML
  payloads had a Version 1.0 header, four valid offsets, and fragments
  containing the Japanese sample, red-text sample, second line, and literal
  LF. The mixed plain-text representation contained the same sample lines.
  The owner pasted the mixed copy into Notepad and confirmed all three lines.
- Ran `scripts/test-windows-html-clipboard.ps1 -TestOsc52` inside Ghostty via
  its `-e` command path. The clipboard contained exactly
  `OSC52 clipboard regression` as Unicode text and did not contain
  `HTML Format`, confirming the existing OSC 52 plain-text write path.
- Partial registration remains possible: if `CF_UNICODETEXT` is accepted
  and the subsequent HTML registration fails, text stays on the clipboard
  while the operation reports an error. This failure path was not injected.

## 2026-10-16: IME review follow-up (#48)

Claude Code CLI reviewed `604034f7a`. It reported six P3 findings about
test/report precision and coverage, no confirmed P1/P2 defect, and two
unverified runtime hypotheses. This follow-up changes test tooling and
documentation; the application sources under `src/` remain at `604034f7a`.

- Clarified which earlier checks preceded the final diagnostic-dispatch
  exclusion. The earlier main-PID absence check is identified explicitly;
  it was not a child-process-tree check or a field in the old session JSON.
- Renamed the cancellation test to describe synchronous timer dispatch.
  It verifies the inactive guard; it does not establish OS timer removal
  or actual queued-message delivery. No synthetic flag is treated as proof
  that `KillTimer` removed an OS timer.
- Added composing split/tab closure with the original pane retained and
  responsive. Successful window closure is recorded only after exit and
  crash/leak checks. Probe process records include start times; the runner
  retains process handles and reports observed probe exits and leftovers.
  On a close timeout it force-terminates only its own recorded processes,
  reports `ForcedTermination`, and keeps the overall test failed.
- Added `verify-windows-ime.ps1` and listed both IME checks in AGENTS and
  roadmap section 9. The runner saves HEAD, working-tree patch/changed-file
  hashes, commands, exit codes and executable hashes. The unchanged
  application source was rebuilt and retested with the updated scripts:
  `zig-out/logs/ime-verification-20261016-195608-194/summary.json` records all
  seven stages passing, with `AutomatedPassed=true`. Normal and hook Debug
  builds passed 128/128 steps; both Win32 test configurations passed 182
  tests with one skipped (91/91 steps). Both window-state regressions exited
  0 without forced termination. Documentation result entries were added
  after this run; the recorded script hashes identify what was executed.
- The expanded placement regression passed all eight check groups:
  `zig-out/test-fixtures/ime-position-20261016-195901-768/result.json`, exit
  0, no forced termination, no crash/leak marker and no observed survivors
  among the main process and three probes. Diagnostic executable SHA-256:
  `0DAA9277BB8E705C3B536F6EBF19F87EB5E9FD4594BA66D3E3E2D2137FA128E3`.
- Failure-cleanup verification on the final script used
  `-SimulateCloseTimeout`. The run intentionally failed, recorded one
  forced termination and no observed survivors, and did not list window
  closure as successful. Evidence:
  `zig-out/test-fixtures/ime-position-20261016-195945-018/result.json`.
- An input-free launch/close check of `test-windows-ime.ps1` saved
  `MainProcessExited=true`, `ProbeExited=true`, no observed survivors and
  exit 0 in `zig-out/test-fixtures/ime-20261016-195935-398/session.json`.
  It tests the new lifecycle records, not physical IME input; no trace was
  expected without composition. The earlier owner-operated visual result
  below remains the physical partial-commit acceptance evidence.
- During script development, a first run incorrectly treated a matching
  probe PID as reused: `ConvertFrom-Json` already returned a DateTime, and
  reparsing its string representation lost time/zone precision. Preserving
  the DateTime value fixed the comparison; later successful and forced-exit
  runs above exercised it. The failed run is retained at
  `zig-out/test-fixtures/ime-position-20261016-195446-472/result.json`.

Focus loss/return with a retained native composition and output-heavy/TUI
composition remain unverified hypotheses, not confirmed defects. Physical
focus-resume, resize/DPI and other-IME scenarios are now explicit separate
manual checks. The synthetic lifecycle cases do not establish those native
IME behaviors, and no speculative application change was made for them.

## 2026-10-16: Partial IME commit diagnostics (#48)

- Started schedule step 1 on the owner's instruction. Before correction,
  the code set
  the composition position only at `WM_IME_STARTCOMPOSITION`; saved input
  evidence contains the correct final `庭にはにわ` despite the reported
  overlap. This establishes the observed symptom, not its cause.
- `ImeDiagnostics.zig` observes start/composition/end, `WM_CHAR`, focus
  loss and cursor changes sampled during composition. Each record includes
  `GetTickCount64`, the terminal child handle, flags, cursor coordinates,
  the expected cell origin, the IMM composition form and string lengths.
  The IMM form is configuration readback, not proof of the actual drawn
  position; visual inspection is still required. The trace does not log
  input text and never changes IME placement or consumes IME messages.
- Tracing requires both `-Dwin32-test-hooks=true` and
  `GHOSTTY_TEST_IME_TRACE=1`. The observation timer stops on composition
  end, focus loss and surface destruction. Normal builds disable tracing.
- `scripts/test-windows-ime.ps1` launches a dedicated recorder, saves
  completed lines/UTF-8 bytes separately, and captures the executable hash,
  stderr and exit status. Typed input is not executed as shell commands.
  Build with `zig build -Dwin32-test-hooks=true --prefix zig-out/ime-diagnostics`,
  then run `./scripts/test-windows-ime.ps1` and reproduce the partial commit.
- Diagnostic Debug build: 128/128 steps passed. Win32 tests with hooks:
  182 passed, one skipped, 91/91 steps passed. Window-state regression with
  tracing enabled passed terminal input, IME process-key suppression,
  startup grid, split focus, config reload, multi-window/monitor and window
  lifecycle checks; exit 0, no forced termination or remaining test process.
  Logs: `zig-out/logs/ime-diagnostics-build.log`,
  `ime-diagnostics-tests.log`, `ime-diagnostics-window-state.log` and
  `window-state-20261016-151127-560-3d1cb264.stderr.log` in the same directory.
- The owner reproduced the overlap with the diagnostic executable
  (`3CC3F0E906172943AEEE1D923F9C8D70E8D590EA5DC75ABE86AD2A0DAB3F2E2C`).
  Evidence: `zig-out/test-fixtures/ime-20261016-164646-305/`.
  At tick 88407875, a `WM_IME_COMPOSITION` notification with flags `0x1db8`
  had six result bytes and four remaining composition bytes. The following
  three `WM_CHAR` notifications still saw cursor column 7 and point (72,86).
  At tick 88407906, the cursor was at column 13 and point (132,86), but IMM
  still reported (72,86). It remained there until the next commit more than
  eight seconds later. This confirms the missing position update after
  asynchronous terminal output. Exit was 0, with no crash/leak marker.
  This run did not save an Enter-terminated line; the earlier final-text
  evidence above is a separate run.
- `Keyboard.zig` now follows the cursor on the UI thread throughout native
  composition, updating `CFS_POINT` only when the cell-origin coordinates
  change. A 16 ms window timer observes later terminal output; it does not
  assume that output completes within a fixed delay. Composition end,
  focus loss and surface destruction cancel tracking. All composition
  messages still reach `DefWindowProc`, preserving the native clause UI
  and the existing committed-character delivery.
- `scripts/test-windows-ime-position.ps1` exercises two delayed PTY cursor
  moves during one composition, end/focus cancellation (including synchronous
  timer-message dispatch after cancellation), restart and close while composing.
  This checks the inactive guard, not OS timer removal or queued delivery.
  The opt-in diagnostic
  query (`WM_USER + 113`, integer correlation ID only) records IMM readback
  and tracking state. All six check groups passed with exit 0 and no
  crash/leak marker; evidence is in
  `zig-out/test-fixtures/ime-position-20261016-165235-107/`. After excluding
  the diagnostic dispatch from normal builds, all six groups passed again
  in `zig-out/test-fixtures/ime-position-20261016-165446-667/`; the diagnostic
  executable hash is `59116E1B21218C43BD9FAA36901317068964DC49FC556E3835528BA641947DC8`.
  Before the final diagnostic-dispatch exclusion, the corrected code passed
  Win32 tests (182 passed, one skipped) and the diagnostic executable passed
  window-state regression (exit 0, no forced termination); logs are
  `zig-out/logs/ime-fix-tests.log` and `ime-fix-window-state.log`.
- Final normal and diagnostic Debug builds passed 128/128 steps each
  (`ime-fix-normal-build.log` and `ime-fix-build.log` in `zig-out/logs`).
  The normal build passed window-state regression with exit 0 and no forced
  termination (`ime-fix-normal-window-state.log`). Even with the trace
  environment variable set, its stderr contained no `win32_ime_trace`
  records, confirming that diagnostics were disabled.
- Physical Japanese IME acceptance passed on 2026-10-16. The owner confirmed
  that the remaining composition no longer overlaps the partially committed
  text. Evidence: `zig-out/test-fixtures/ime-20261016-165519-925/`, using the
  corrected executable hash above. At tick 92990453 the partial commit
  arrived with six result bytes and four remaining composition bytes; at
  tick 92990484 the terminal point and IMM form both read (132,86). After
  composition end, subsequent character records show `tracking=false`.
  The probe saved `庭にはにわ` with UTF-8
  `E5BAADE381ABE381AFE381ABE3828F`. The process exited with code 0, no
  crash/leak marker. A separate `Get-Process -Id 19164 -ErrorAction SilentlyContinue`
  check returned no process; this checked the main test PID, not its child
  process tree, and was not saved in `session.json`. Schedule step 1 is Done.
- On the owner's instruction, issue #48 was closed as completed on
  2026-10-16 after this acceptance. The correction and documentation were
  still local working-tree changes at closure; no commit or push was
  performed as part of the closure request.

## 2026-10-16: Roadmap review and pre-cutover prerequisites

Claude Code CLI reviewed `7b2c255fb`; a follow-up covered the initially unread
roadmap sections and reassessed the findings. This entry records documentation
changes only, not implementation or newly executed runtime verification.

- The current sequence is #48 and F4-F8 on `windows`, followed by branch
  cutover immediately before the rename. Earlier entries' "next rebranding
  phase" or "next step" describe the plan at those checkpoints; use the
  [current schedule](windows-roadmap.md#schedule-before-and-after-the-rename)
  for execution order.
- Runtime name indirection exists, but the build/distribution/output scope
  remains a separate task on `windows` with unchanged `ghostty` values.
  The executable build name and PowerShell release paths still use literal
  product names. This task and upstream synchronization with verification
  are explicit pre-cutover prerequisites; the completed Win32 file
  restructuring stays complete.
- F8 acceptance uses the current product identity. New-name registration
  and activation are revalidated after renaming. F6 links to the #43 mode-bit
  compatibility review if its design adopts persistent terminal snapshots.
- Verification rows now reference the later physical mouse, tab and
  high-contrast reports without asserting unrecorded component coverage.
  Windows 10 and other environment-dependent gaps remain pending. The
  emergency-distribution route during rename implementation remains an
  owner decision; no release policy was changed.
- Feature status labels and the current action-dispatch reference were
  reconciled. Historical evidence and withdrawn review claims were not
  rewritten as current defects.

## 2026-10-16: Preview .15 verification reconciliation

- The saved `zig-out/logs/windows15-full-zig-test.log` reports 91/91 steps
  succeeded, 4040/4102 tests passed and 62 skipped; the accompanying
  `windows15-full-zig-test-exit.txt` records exit 0. This `.15` preparation
  run includes the final fallback-layout correction and supersedes the
  earlier full-suite verification gap in the lifecycle entry below.
- #12 is closed. #49 remains open despite its completed controlled-failure
  verification; #48 remains the separately tracked partial IME commit defect.
- Upstream synchronization through `6d53bafb1` and Win32 restructuring are
  complete. `gooztty` is absent locally and on `origin`; the next rebranding
  phase is the branch workflow described in the
  [rebranding plan](windows-rebranding-plan.md#5-work-sequence-and-exit-criteria).
- This was a documentation reconciliation using saved logs and current
  Git/GitHub metadata. No tests were rerun.

## 2026-10-15: Creation rollback and IPC UI timeout (#49)

Follow-up on `windows`, verified as working-tree changes based on `653033b4c`.
This is separate from the restructuring acceptance at `92d3a5d25` below.
Issue #49 remains open as of 2026-10-16. The later full-suite result is
recorded above.

Verification is complete for the controlled rollback and IPC timeout scope
described below, including the final fallback-layout correction.

| Check | Final recorded result |
|---|---|
| Ordinary and hook-enabled Debug builds | Both 128/128 steps, exit 0 |
| Creation rollback/fallback and IPC timeout | 33 creation cases plus four IPC cases passed; all app exits 0 and no observed leftover processes |
| Ordinary-build hook rejection | Passed |
| Representative display checks | Four captures inspected; the 32-pixel fallback strip is resolved |
| Win32 tests after the layout correction | Hooks enabled: 182 passed, one skipped, 91/91 steps, exit 0 |
| Unfiltered Zig suite | Before the layout correction: 4039 passed, 63 skipped, 91/91 steps, exit 0. Subsequently, `.15` preparation included the correction: 4040 passed, 62 skipped, 91/91 steps, exit 0 (see the 2026-10-16 entry above) |

Final desktop evidence is `lifecycle-acceptance-20261015-185443-952.json`
and its separate `*-visual-review.json`. The original completion judgment
used the post-correction Win32 tests and desktop checks; the full-suite run
on the final source followed during `.15` preparation. Saved failures and
earlier test results are retained below to distinguish them from final
acceptance.

### Reproduction and fixes

- With injection added to the otherwise unchanged lifecycle code, a tab
  failure after core registration (`core_config`) exited 3: rollback called
  `App.deleteSurface`, which unwrapped a still-null `Surface.core_surface`.
  A failure immediately after successful core initialization (`core_ready`)
  also exited 3: `initCoreSurface` freed the core before the outer
  `Surface.deinit` used it. Saved reproduction results are
  `zig-out/logs/lifecycle-20261015-180306-844.json` and
  `lifecycle-20261015-180323-670.json`, with their matching stderr files;
  injection-only executable SHA-256
  `E7E35EC56C2C6B8698C3504486E8C31E077DB3AC06C673403743C4EC1C1D4B42`.
- Win32 unregister now compares the optional core pointer without unwrapping
  it. Before core initialization succeeds, `initCoreSurface` owns its
  allocation and registration; afterwards, `Surface.deinit` owns both.
  Later failures therefore use the fully initialized surface's destructor
  exactly once.
- Failed tab/split creation now restores the previous active tab and native
  focus; split rollback also restores the logical focused pane and zoom.
  `lifecycle-20261015-180330-610.json` detected changed split state, and
  `lifecycle-20261015-180551-901.json` isolated a changed logical focused
  pane despite an unchanged native focus HWND. The final fixture starts
  with three tabs, selects the first, and creates two panes with one zoomed.
- Keep `removeTabAt(...) catch unreachable` in tab rollback: the successful
  insertion guarantees an existing new tab and a surviving original tab,
  and removal cannot allocate. The injected post-insertion failures exercise
  this invariant. Do not suppress an ownership violation as a recoverable
  creation failure.

### Regression controls and scope

`LifecycleTestHooks.zig` requires both `-Dwin32-test-hooks=true` and
`GHOSTTY_TEST_LIFECYCLE=1`. The private message accepts numeric operations,
not caller pointers. Failure injection is one-shot. The ordinary build
ignores these controls even when the environment variable is set.

`scripts/test-windows-lifecycle.ps1` uses isolated configs and dedicated
processes. Its 17 checkpoints cover parent/child/tab-bar HWND creation,
runtime surface/window initialization, window-list append, tab/split
insertion and ownership, core allocation/registration/configuration,
before/after core initialization, and after scrollbar configuration.
There are 33 action/checkpoint combinations: 13 window, 10 tab, 10 split.
For rollback it compares native HWND sets, core/window/tab counts, and a
fingerprint of registration, ordered tabs/surfaces, split structure/ratios,
focus, zoom and parent USERDATA; it also checks live ownership and retries
creation. Tab-bar failure instead checks the supported fallback: a usable
new window without a tab bar, then a subsequent window with a tab bar.
Every case checks normal exit and absence of crash/allocator-leak diagnostics.
A final process scan checks for leftover observed descendants and fixture
shells across the run.

IPC controls hold the UI-owned request while leaving the message loop
responsive. Four real `+new-tab` client cases cover the existing five-second
timeout followed by late success, late creation failure, shutdown before
timeout, and shutdown after timeout. They check the client error, retained
request counts, later completion/release, subsequent IPC where applicable,
and zero live requests at shutdown. The timeout remains "completion unknown;
the tab may be created later"; it does not cancel the request. Unit tests
also check either owner releasing the request first. No production IPC
timeout or protocol behavior was changed.

These are controlled boundary failures, not exhaustive allocator-failure
enumeration or physical GPU/USER-resource exhaustion. In particular,
`core_init` fails before entering `CoreSurface.init`; it does not inject
every partial initialization inside the core or renderer. Physical input,
OpenGL, and the separate partial IME commit defect (#48) are outside this
follow-up.

### Build and verification evidence

- Debug executable SHA-256 before the fallback-layout correction below:
  Hook build:
  `FE7BD86F22AD12E895F02B6602455002DD312708F8BC4C3BDD3B0430C5715465`.
  Ordinary Debug executable SHA-256:
  `17EAE28106FA694EC3FC12C56EE90AE4B2C7DAEE115BE1C62C8D154D1BB5B786`.
- `zig build test -Dtest-filter=Win32 -Dwin32-test-hooks=true`: 91/91
  steps, 182 passed, one skipped, exit 0
  (`zig-out/logs/lifecycle-win32-tests-final.log`). This includes three new
  tests for uninitialized unregister, request ownership and one-shot opt-in.
- Unfiltered `zig build test --summary all` before the fallback-layout
  correction: 91/91 steps, 4039 of
  4102 tests passed, 63 skipped, exit 0
  (`lifecycle-full-zig-test.log`). The main test run reports 4034 passed and
  63 skipped; the build-helper tests contribute the other five passes.
  The log again prints `failed command:` after two formatter roundtrip
  `equal=true` messages, despite a successful step and command exit. See
  the runner-source explanation below; the line is preserved in the log.
- The same Win32 filter without test hooks also passed 182 tests, one
  skipped, 91/91 steps, exit 0 (`lifecycle-normal-win32-tests.log`).
- Initial complete automated lifecycle run: 37/37 cases passed (33 creation cases and
  four IPC cases), all server exits 0, no forced termination or crash/leak
  diagnostic, empty `Leftovers`, 246 observed child processes across the
  run (`lifecycle-20261015-181717-486.json`). Three timeout cases took
  5.16-5.32 seconds including client startup; pre-timeout shutdown was
  requested after 0.060 seconds. All four held-request clients exited 1.
  The ordinary-build control rejection check passed with normal tab creation,
  exit 0 and empty leftovers (`lifecycle-20261015-181900-096.json`).
  All 32 rollback cases also logged the expected failed binding action
  (`lifecycle-action-error-check.json`); the tab-bar case is the intentional
  successful fallback. The script now asserts that failure report as well.
  A `tab-core_ready` rerun with that assertion passed, with empty leftovers
  (`lifecycle-20261015-182226-150.json`).
- Existing ordinary-build regressions passed: window-state (input,
  process-key suppression, startup grid, split focus, multi-window lifetime,
  reload, four-monitor layout and minimize/maximize/restore), exit 0 without
  forced termination (`lifecycle-window-state.json`, underlying log prefix
  `window-state-20261015-181911-001-c3b0c86f`); and all four modal-action
  cases, exit 0 without forced termination
  (`modal-actions-20261015-181922-040.json`). Palette/overlay/recovery options
  were not enabled in this window-state run.
- In the sandbox, both executable compilations and installations succeeded, but both
  complete build commands exited 1: 125/128 steps succeeded, with the only
  failing step being Git's `tic.exe` (`couldn't create signal pipe, Win32
  error 5`). See `lifecycle-hooks-build-final.log` and
  `lifecycle-normal-build.log`. Commands set `ZIG_GLOBAL_CACHE_DIR` to
  `.zig-cache/global`; without that override, resource-manifest creation
  failed with `AccessDenied`. These attempts were not successful full builds;
  the subsequent desktop builds below passed. No release package was checked.
- Screenshot attempts failed with `CopyFromScreen` Win32 error 6
  (`invalid handle`), also reproduced by a standalone 32x32 desktop capture
  (`lifecycle-desktop-capture-error.log`). The later desktop captures below
  succeeded. `-CaptureWindows` enables strict capture
  checks when a desktop capture can be obtained.

### Final review and environment diagnostics

- The installed Zig 0.16.0 runner explains the misleading `failed command:`
  line. `lib/std/Build/Step/Run.zig:1541` records the command before spawning;
  its successful test-completion path retains buffered stderr at line 1746
  and uses `test_results.isSuccess()` at line 1385 to decide failure.
  `lib/compiler/build_runner.zig:1381` displays diagnostics regardless of
  step success, and its printer at line 1518 labels the recorded command
  `failed command:`. Here the stderr comes from the unconditional
  `std.debug.print` in `src/benchmark/TerminalFormatter.zig:470`, not a failed
  equality assertion. This source inspection explains the current log;
  no runner/library source or benchmark output was modified.
- `tic.exe -V`, without any terminfo input, independently failed with
  `couldn't create signal pipe, Win32 error 5`
  (`lifecycle-tic-version.log`, exit recorded in
  `lifecycle-tic-version-exit.txt`). The corresponding diagnostic in the
  [MSYS runtime](https://github.com/msys2/msys2-runtime/blob/master/winsup/cygwin/sigproc.cc)
  belongs to signal-thread initialization. This narrows the failure to
  runtime startup, before Ghostty's terminfo data is processed; it does not
  establish the precise ACL responsible. No terminfo build step was skipped
  or changed to turn the failed build into a success.
- The environment probe (`zig-out/test-fixtures/lifecycle-environment/probe.ps1`)
  recorded a restricted process token and a `CodexSandboxDesktop-*` thread
  desktop. A direct GDI `BitBlt`, using source and destination DCs whose object
  types were valid (3 and 10), failed with error 6
  (`lifecycle-environment.json`). Thus the capture failure also occurs below
  the .NET wrapper. The sandbox/token/desktop configuration was not changed;
  the normal interactive PowerShell comparison is recorded below.
- Final script review corrected the capture timing: `-CaptureWindows` now
  captures the restored state immediately after rollback, before retrying
  creation. The tab-bar fallback capture targets the newly created window
  without a bar, rather than the original window after the successful retry.
  `CaptureStage` records which state was requested, and pane text identifies
  the fixture. A capture error still fails the case.
- The revised fixture passed all 37 automated cases again, with empty
  leftovers (`lifecycle-20261015-182851-451.json`). Capture-enabled checks
  reached `rollback-before-retry` and `tab-bar-fallback-before-retry`, then
  failed with the same `CopyFromScreen` error. These are failed capture runs,
  not visual acceptance (`lifecycle-20261015-183044-362.json` and
  `lifecycle-20261015-183047-955.json`); both app processes exited 0 without
  a crash/leak diagnostic or forced termination.
- The first capture failure's immediate process scan still saw an OpenConsole
  child, which had exited by the later inspection. The script now waits up
  to `TimeoutSeconds` for observed children to exit, saving `InitialLeftovers`,
  `CleanupSeconds` and final `Leftovers`; it does not kill those children.
  A capture-failure rerun observed one OpenConsole initially and none after
  2.47 seconds (`lifecycle-20261015-183149-830.json`). A normal
  `tab-core_ready` rerun passed with empty final leftovers
  (`lifecycle-20261015-183205-728.json`).

`scripts/verify-windows-lifecycle.ps1` now runs both full builds, the
ordinary-build control-rejection check, and all 37 cases with captures in
sequence. It stops on a failed step and saves its exit code and log path in
`zig-out/logs/lifecycle-acceptance-<timestamp>.json`. On success it collects
the executable hashes and four image paths; its raw `VisualInspection` stays
`Pending`, with completed inspection recorded in a separate review JSON.
The script restores the
calling process's cache environment setting on exit.

The runner's failure path was exercised here: `normal-build` exited 1 on
`tic.exe`, and no later step was run
(`lifecycle-acceptance-20261015-184228-998.json`). The test script's new
explicit summary-path option was separately verified through child `pwsh`
processes: ordinary-build control rejection and `tab-core_ready` both passed,
with empty leftovers (`lifecycle-summarypath-normal.json` and
`lifecycle-summarypath-hook.json`).

### Owner-run desktop acceptance and fallback-layout correction

The owner ran the acceptance script in an interactive PowerShell:
`zig-out/logs/lifecycle-acceptance-20261015-184520-800.json`. Both full Debug
builds passed 128/128 steps, exit 0, including `tic` (93 ms normal, 53 ms
hooks); executable hashes match those above. Control rejection and all 37
capture-enabled cases passed, all app exits were 0, with no forced exit,
crash/leak diagnostic or initial/final leftovers. The raw runner summary
correctly leaves `VisualInspection` as `Pending`.
The separate `lifecycle-acceptance-20261015-184520-800-visual-review.json`
records the image inspection below without changing that raw summary.

Inspection of `lifecycle-20261015-184525-247-{window,tab,split}-core_ready.png`
confirmed three tabs with the first selected, the restored zoomed pane and
readable fixture text. However, `*-window-tab_bar_hwnd.png` exposed an
unpainted strip above the fallback terminal containing another pane's text.
`WindowLayout.tabBarVisible` considered configuration and tab state but not
the missing tab-bar HWND, so layout still reserved the bar's height.

The fixture now checks the fallback pane's four native insets relative to
the parent client rectangle, even without screenshots. Against the desktop
run's executable it failed with `[0, 32, 0, 0]` (left, top, right, bottom),
exit 0 and no leftovers (`lifecycle-fallback-layout-before.json`). The fix
makes a missing tab-bar HWND invisible to layout, so the terminal can fill
the client area. The previous 37/37 result did not assert this geometry and
must not be treated as successful fallback visual acceptance.

The corrected hook executable compiled and installed successfully, SHA-256
`CD7B3192D9EEDD94998F710256AE9F1A0654923FF90AA066F505DDDAC2DC393F`.
The sandbox full build still exited 1 solely at `tic` (125/128 steps;
`lifecycle-fallback-layout-build.log`). Targeted Win32 tests with hooks
passed 182 tests, one skipped, 91/91 steps, exit 0
(`lifecycle-fallback-layout-win32-tests.log`). The unfiltered full-suite
result above predates this three-line layout correction.
All 37 cases passed again on the corrected hook executable, with zero
fallback insets `[0, 0, 0, 0]`, no forced exit or crash/leak diagnostic and
no final leftovers (`lifecycle-fallback-layout-after.json`). This rerun did
not capture images; the subsequent desktop run below supplies that evidence.

The owner reran the corrected version with the same command from an ordinary
interactive PowerShell:

```powershell
./scripts/verify-windows-lifecycle.ps1
```

Final summary: `lifecycle-acceptance-20261015-185443-952.json` (18:54-18:57).
Both Debug builds passed 128/128 steps, exit 0, including `tic` (16 ms normal,
29 ms hooks). The normal executable SHA-256 is
`1140B33FB6B6E57B8CE9461B660E485811AD20C08DFD0ED828AA5D6471BCCFCA`;
the hook executable retains `CD7B3192D9EEDD94998F710256AE9F1A0654923FF90AA066F505DDDAC2DC393F`.
Both on-disk hashes were checked against the summary. The associated
`*-hooks-disabled.json` confirms ordinary-build controls are ignored;
`*-cases.json` records 37/37 passes, zero fallback insets, all app exits 0,
no forced termination or crash/leak diagnostics, and empty initial/final
leftovers.

All four `lifecycle-20261015-185533-242-*.png` captures were inspected. The
three `core_ready` images show the first of three tabs selected, the restored
zoomed pane and readable fixture output. The fallback image shows readable
terminal output directly below the title bar, without the former unpainted
strip or another pane's text inside the client area. Capture stages remain
before retry. The separate
`lifecycle-acceptance-20261015-185443-952-visual-review.json` records this
successful inspection; the raw automated summary retains its original
`VisualInspection: Pending`. Desktop acceptance of the correction is now
complete for the documented injection scope. No release, commit or issue
closure is recorded by this verification.

## 2026-10-15: Win32 apprt restructuring final verification (#12)

Final pass required by roadmap Section 7 (goal 4), on `windows` at
`92d3a5d25`, Debug executable SHA-256
`E4424F4A62809F407B79B1447203B2A3F018D60E6328BC0E4A1985B9A1FEA2B9`.

- Full Zig test suite (`zig build test`, no filter): 91/91 steps, 4037 of
  4099 tests passed, 62 skipped, exit 0, about 10 minutes
  (`zig-out/logs/final-pass-zig-test.log`). The log contains a
  `failed command:` line for the `ghostty-test` run directly after two
  `terminal-formatter roundtrip ... equal=true` stderr lines; the same step is
  reported as `success` (4032 pass, 62 skip) and no test failure is recorded.
  Why the build runner printed that line was not investigated in that pass;
  the later lifecycle follow-up above records a Zig runner source inspection.
- `test-windows-window-state.ps1 -TestCommandPalette` passed: input, IME
  process keys, initial grid, split click focus, multi-window navigation,
  hide/restore together, individual close and close-all, config reload,
  palette, four monitors, minimize/restore, exit 0 without forced termination
  (`window-state-20261015-143859-311-07e54627`).
- `test-windows-parity.ps1` passed (search, Unicode matches, input after
  search, mouse shape/visibility, cwd inheritance), exit 0
  (`parity-20261015-143905-820.png`). `test-windows-context-menu.ps1` passed
  (blank rows, word and existing selections), exit 0
  (`blank-context-20261015-143914-113`).
- `test-windows-soak.ps1 -Iterations 20` against `zig-out\bin\ghostty.exe`:
  20 of 20 runs passed with graceful exit, config reload, window navigation
  and visibility toggle on four monitors, 129 seconds
  (`windows-soak-20261015-143925-339.json`). The script prints "Windows
  Release regression" as a fixed label; it forwards `-Executable` to each run.
- Owner-operated GUI check with the physical keyboard, mouse and Japanese IME
  (`zig-out/test-fixtures/final-pass-manual/`, `session-20261015-144233.json`):
  tabs (F2 new tab, tab-bar selection, drag reorder), splits (F3, click focus,
  divider drag), IME commit of `日本語` in the terminal (UTF-8
  `E697A5E69CACE8AA9E`) and in the tab-title dialog, a move between a 96 DPI
  and a 120 DPI (125%) monitor, and IPC `+new-tab` sent from this session
  (client exit 0, fallback window reported, `created Win32 tab tabs=3`). The
  owner reported every item as OK; the log records the tab and split creation,
  the 120 DPI scale and the IME placement. The process exited 0 with no crash
  or leak markers. The rename-dialog input and drag reorder are owner-confirmed
  only.
- After each run, a process query for `ghostty.exe` under `zig-out` returned
  no remaining test processes. These queries were made from the session and
  their output was not saved; the soak summary records a graceful exit for
  each of its runs.
- Overlay scrollbar: the unmodified script with `-TestOverlayScrollbar`
  failed on both this build and the previous executable because another
  application's window covered the scrollbar area being measured (capture
  `window-state-20261015-143750-271-6440e803.scrollbar.png`). It was then run
  with the existing topmost copy
  `zig-out/test-fixtures/config-actions-split/window-state-topmost.ps1`, which
  differs from the current script only in the repository-root lookup and two
  `SetWindowPos(HWND_TOPMOST)` calls for the test window and the measured
  scrollbar (the script is unchanged since 2026-09-26). With
  `-TestCommandPalette -TestOverlayScrollbar` it passed: reveal and hide
  after delay, `never`/`system` reload, split independence, resize tracking,
  alternate-screen hiding, exact drag (delta -3 px within 4), output and pane
  close during drag, key/wheel/search position sync, and scrollback history
  limits; exit 0 without forced termination. The first topmost run
  (`window-state-20261015-145044-722-828f8b25`) returned these values only to
  the console, so it was rerun with the returned object saved:
  `zig-out/logs/final-pass-overlay-topmost.json`
  (`window-state-20261015-150647-789-158fb3b0`), with the same results,
  exact drag expected 364 / actual 361 (delta -3, tolerance 4), exit 0, no
  forced termination. Single and split scrollbar captures of both runs were
  inspected.
- Known issue #48 (partial IME commit) is tracked separately.
- Items left unexercised by the individual extraction steps were then checked
  against the same executable:
  - File drop (`zig-out/test-fixtures/file-drop-extraction/run-final-pass.ps1`,
    a copy of the review-fixes fixture pointed at `zig-out/bin`): PowerShell,
    cmd and unsupported-shell cases passed, covering exact quoting with
    Unicode, the target pane, no automatic Enter, invalid-path rejection and
    cmd `%`/`!` rejection; all exit 0 (`file-drop-20261015-145354-866.json`).
  - Command palette (`palette-extraction/actions.ps1`, run in a fresh
    PowerShell process because the shared native type was already loaded):
    nested request ignored, palette action created a tab, jump to the other
    tab focused it, a jump to a closed pane was ignored, and the close action
    exited 0 (`palette-actions-20261015-145411-195.json`).
  - New fixture `zig-out/test-fixtures/final-pass-extra/check.ps1`
    (`final-pass-extra-20261015-150622-280.json`), all cases exit 0 without
    forced termination or crash/leak markers:
    `toggle_window_float_on_top` set and cleared `WS_EX_TOPMOST`;
    `reset_window_size` returned a 920x568 window resized to 1120x688 to
    920x568; `open_config:new_window` used `VISUAL` ahead of an invalid
    `EDITOR`, passed the isolated configuration path containing a space and
    Japanese, and titled the window `Editing configuration file ...`;
    `maximize = true` started zoomed; `fullscreen = true` covered the
    2560x1440 monitor without a caption; IPC `+new-tab --title=...
    --working-directory=... -e ...` with `GHOSTTY_SURFACE_ID=0` exited 0
    without a fallback message and created the second tab, titled it, and
    ran the `-e` command in the requested working directory (a path with a
    space and Japanese). The `-e` command is a separate probe script that
    writes its own marker; the configured default shell ran only in the
    first tab.
  - The first run of this fixture (`final-pass-extra-20261015-145600-573`)
    used the same probe script for the default shell and the `-e` command, so
    it could not show that `-e` was applied, and it did not record leftover
    processes. The Codex review found both gaps; the fixture was corrected and
    rerun as above. The rerun's summary records leftover processes after
    the cases: no fixture shells, mock editors or Ghostty processes remained
    (`Leftovers` in the JSON). The leftover query was checked against a dummy
    process carrying the fixture path, which it detected.
  - `present_terminal` has no Win32 binding path: the core sends it only for
    the `present_surface` message (`src/Surface.zig:1127`), which only the GTK
    runtime posts. Its presentation code (`WindowState.presentSurface`) is
    exercised by `goto_window` and palette jumps above.
  - Not exercised: an IPC request exceeding the 5 s UI timeout and injected
    creation failures (rollback paths), which need fault injection not
    present in the build (the rollback work is tracked as
    [#49](https://github.com/fukuyori/ghostty/issues/49)).
  - Grouped manual checks (roadmap Section 7, "Verification": input,
    display and IPC, batched by area). Covered in this pass: keyboard and
    Japanese IME, AltGr (below), divider and tab-bar dragging (owner-reported),
    the 96/120 DPI move and layout, GPU recovery and power resume (hook
    build, during the WndProc step), and real `+new-tab` requests.
  - The remaining grouped areas, physical mouse input and appearance, were
    then checked by the owner with the same executable
    (`zig-out/test-fixtures/grouped-manual/`, `session-20261015-172856.json`,
    `keys-25632.jsonl`, `zig-out/logs/grouped-manual-20261015-172856.stderr.log`).
    The owner reported every item as OK; the process exited 0 with no crash
    or leak markers. Evidenced by the records: drag selection, context-menu
    Copy and Paste delivering `two-words-here` to the recorder; two splits
    created (context menu and F3); 19 configuration reloads; the Gaussian
    backdrop blur applied (`standard_deviation=20`) after
    `background-blur = true`; and `window-theme = light` as the final
    configuration. Owner-confirmed only: double- and triple-click selection,
    wheel scrolling, click focus between panes, background opacity and the
    `window-theme = ghostty` title-bar colors at startup, the `dark` theme,
    and high contrast on and off (no log entry is written for these).
  - AltGr: after the owner added the German (de-DE, `0407:00000407`) layout,
    an owner-operated check with the same executable passed in the key
    recorder (`zig-out/test-fixtures/altgr-manual/keys-37572.jsonl`,
    `session-20261015-155733.json`). AltGr+Q/E/7/8/9/0/ß/+ produced
    `@€{[]}\~` (UTF-8 `40E282AC7B5B5D7D5C7E`), each delivered with
    Ctrl+Alt modifiers; left Ctrl+Alt+Q also produced `@`; unmodified keys
    produced `öäüßz`; the `^` and `´` dead keys composed `âé` (UTF-8
    `C3A2C3A9`); Ctrl+C arrived as Control+C (U+0003) without ending the
    shell; left Alt+Q produced `q` with Alt. Retyped keystrokes in the record
    (a mistyped `ß`, and an accent followed by a non-composing key emitting
    both characters) match standard Windows dead-key behavior. The process
    exited 0 with no crash or leak markers. The ISO-only AltGr+< (`|`) was
    not tested because the physical keyboard has no ISO 102nd key.

With every group in the layout table in its own file and this pass recorded,
the Phase 1 restructuring on `windows` is complete. Creating `gooztty`
(rebranding plan Phase 2) is the next step and is done only when requested.

## 2026-10-15: IPC handler extraction (#12)

- Add `IpcHandler.zig` for the CLI entry point body (`performIpc`), the UI
  request (`IpcUiRequest`) with its reference counting, the transport
  callback (`ipcHandler`), window-thread processing (`processIpcRequest`),
  `WM_IPC_REQUEST` dispatch from the wakeup window (`dispatch`), and
  shutdown discard of posted requests. App keeps `performIpc` as the apprt
  entry point the CLI calls, the wakeup window procedure (which forwards
  `WM_IPC_REQUEST` in one line), and the server lifetime in `init` and
  `terminate`. App no longer imports `Overrides`. The pipe transport stays in
  `IpcTransport.zig`.
- The 213 moved lines are identical to `HEAD:src/apprt/win32/App.zig` apart
  from `pub`, the `processIpcRequest(app, request)` call form, and the new
  `dispatch` signature and doc comment.

### Verification

- Debug build: 128/128 steps (`zig-out/logs/ipc-handler-build.log`). Win32
  hook tests: 91/91 steps, 179 passed, one skipped
  (`ipc-handler-win32-tests.log`).
- IPC `+new-tab` against a dedicated Debug instance matched the previous
  `zig-out/review-fixes-v2/bin/ghostty.exe`: the tab was created, the client
  exited 0 and reported the fallback window, the server logged the
  pre-existing `OverlappedIoFailed` warning, and WM_CLOSE showed
  `Close Terminal?`. Both test servers were then ended by their own PID.
  Logs: `zig-out/logs/window-lifecycle-ipc-ipchandler*`.
- With no server running, the client printed `No running Ghostty instance was
  found.` and exited 1 in four alternating runs of both executables
  (`ipchandler-noserver2-*`). An earlier single run of the previous
  executable, started immediately after a test server was force-ended,
  printed `Ghostty IPC failed: error.OverlappedIoFailed` instead; its state was
  not recorded, so the cause is not established.
- `test-windows-window-state.ps1 -TestCommandPalette` passed, exit 0 without
  forced termination (`window-state-20261015-140558-567-aa803993`). The four
  modal-action cases and eight config-diagnostic cases passed with exit 0.
- Parity first failed three times at `OSC 22 hand cursor` with
  `CURSORINFO.flags = 2` (`CURSOR_SUPPRESSED`) and cursor 0, on both this
  build and the previous executable, so it is not a regression of this
  change. After the owner moved the physical mouse, parity passed in full,
  exit 0 (`parity-20261015-140912-663.png`, inspected). No test processes
  remained after any run (process query from the session; its output was not saved).
- Tested executable SHA-256
  `E4424F4A62809F407B79B1447203B2A3F018D60E6328BC0E4A1985B9A1FEA2B9`.
- Not exercised: an IPC request timing out, `+new-tab` arguments
  (`--command`, `--working-directory`, `--title`) in this run, and grouped
  manual acceptance.

### Handoff

- Every group in the layout table now has its own file. Run the final
  verification pass in roadmap Section 7 before creating `gooztty`.

## 2026-10-15: Window procedure extraction (#12)

- Add `WndProc.zig` for the parent and terminal window procedure and the
  userdata lookup (`getSurface`). The 251 moved lines are identical to
  `HEAD:src/apprt/win32/App.zig` apart from `pub` on `wndProc`.
  `WM_CLOSE_SURFACE` is referenced from `WindowLifecycle`. App registers
  `WndProc.wndProc` through `registerWindowClass` and keeps the wakeup
  window procedure with the message loop.
- Keyboard, Recovery, WindowAppearance and WindowLayout call
  `WndProc.getSurface`; Keyboard no longer imports App.

### Verification

- Debug build: 128/128 steps (`zig-out/logs/wndproc-build.log`). Win32 hook
  tests: 91/91 steps, 179 passed, one skipped (`wndproc-win32-tests.log`).
  A separate hook-enabled build (`zig-out/wndproc-hooks`, 128/128 steps)
  was used only for the recovery checks.
- `test-windows-window-state.ps1 -TestCommandPalette` passed: input, IME
  process keys, initial grid, split click focus, multi-window navigation,
  hide/restore together, individual close and close-all, config reload,
  palette checks, four-monitor layouts, minimize/restore, exit 0 without
  forced termination (`window-state-20261015-134738-527-40d4d135`).
- With the hook build, `-TestGpuRecovery -TestPowerResume` passed: resources
  recreated with the session preserved, suspend/resume notifications, all
  three renderers recovered, duplicate resume suppressed, exit 0
  (`window-state-20261015-134746-296-2c289296`).
- The split/tab command check matched the previous run at every step with
  the window in the foreground (10/10), exit 0
  (`window-commands-wndproc-*.json`). Parity, the four modal-action cases,
  the eight config-diagnostic cases and the context-menu check (blank rows,
  word and existing selections) passed with exit 0 and no forced
  termination. Parity and context-menu captures inspected. No test processes
  remained (process query from the session; its output was not saved).
- Tested executables SHA-256: normal
  `5C7B661CE2EAB6849B31469384F8B2E7FB102CDCDEFDB2984EF8357787F782AE`, hook
  build `B7E8589AB70E7C16C3170D36EE8AF1DDA5E3B462D631817A35F675654CAA7080`.
- Not exercised: file drop (`WM_DROPFILES`) in this run, physical input, and
  grouped manual acceptance.

### Handoff

- `IpcHandler.zig` is still listed in the layout table and not yet split
  (the IPC entry point, UI request ownership and results remain in App).
  After it, run the final verification pass in roadmap Section 7.

## 2026-10-15: Action dispatch extraction (#12)

- Add `Actions.zig` holding the body of `performAction` as `perform`; the
  dispatch switch is moved unchanged, including the small inline `.quit_timer`
  and `.scrollbar` cases. `App.performAction` stays as the apprt entry point
  and forwards in one line. App no longer imports `SearchBar`, which only the
  dispatch used.
- Compared with `HEAD:src/apprt/win32/App.zig`, the dispatch body differs only
  in the function name (`targetSurface` qualified as `App.targetSurface`).

### Verification

- Debug build: 128/128 steps (`zig-out/logs/actions-build.log`). Win32 hook
  tests: 91/91 steps, 179 passed, one skipped (`actions-win32-tests.log`).
- `test-windows-window-state.ps1 -TestCommandPalette` passed (terminal input,
  IME process keys, splits and click focus, multi-window navigation,
  hide/restore together, config reload, close-all, palette), exit 0 without
  forced termination (`window-state-20261015-133913-278-b812ac74`).
- The split/tab command check matched the earlier results at every step, exit
  0 (`window-commands-actions-20261015-133920-183.json`). In this run the test
  window was not the foreground window at any step, unlike the previous
  run (10/10); the focused pane was still resolved at every step, so keys
  reached the intended pane.
- Parity (search, mouse shape/visibility, cwd inheritance) passed, capture
  inspected. The four modal-action cases and all eight config-diagnostic
  cases (startup/reload diagnostics, owner close, palette reload) passed with
  exit 0 and no forced termination. No test processes remained (process query from the session; its output was not saved).
- Tested executable SHA-256
  `709E729C6FD5E936250533D5A267247E2B02EBFD5057B02C33EB2102A723342E`.
- Not exercised: actions without a regression path (`present_terminal`,
  `float_window`, `reset_window_size`, `open_config` editor launch in this
  run), and grouped manual acceptance.

### Handoff

- Continue with `WndProc.zig`, the last planned group, followed by the final
  verification pass listed in roadmap Section 7.

## 2026-10-15: Window-state additions (#12)

- Move the startup show (`showWindow`), `present_terminal` and
  `presentSurface`, `toggle_visibility`, and `transferWindowState` from App
  into `WindowState.zig`, as the layout table assigns them. App action
  dispatch, CommandPalette, WindowCommands, TabBarController and
  WindowLifecycle call the module. `windowStateSurface` stays in App as an
  ownership lookup used across modules.
- A normalized comparison with `HEAD:src/apprt/win32/App.zig` (ignoring
  indentation, blank lines, `App.` qualification and `pub`) matches all 105
  moved lines.

### Verification

- Debug build: 128/128 steps (`zig-out/logs/window-state-additions-build.log`).
  Win32 hook tests: 91/91 steps, 179 passed, one skipped
  (`window-state-additions-win32-tests.log`).
- `test-windows-window-state.ps1 -TestCommandPalette` passed: startup
  placement, maximize, minimize/restore to maximized and restore,
  multi-window `goto_window`, hide/restore together through
  `toggle_visibility` (including across config reload), close/recreate,
  palette checks, and exit 0 without forced termination
  (`window-state-20261015-133145-974-eb430030`).
- The ad-hoc split/tab command check
  (`zig-out/test-fixtures/window-commands-check.ps1`) matched the earlier
  results at every step, including state transfer on `move_tab`, with the
  window in the foreground and exit 0. Parity passed (capture inspected), and
  the four modal-action cases, which transfer state when tabs close, passed
  with exit 0. No test processes remained (process query from the session; its output was not saved).
- Tested executable SHA-256
  `E7DEE3177E62EABCEFA6723745D900A6A1803D22BAB5D992816D60603411A782`.
- Not exercised: `present_terminal` from a key binding, configured
  `maximize`/`fullscreen` at startup, and grouped manual acceptance.

### Handoff

- Continue with `Actions.zig`, then `WndProc.zig`.

## 2026-10-15: Keyboard extraction (#12)

- Add `Keyboard.zig` for modifier state, key translation (scan code,
  virtual key, layout-unshifted codepoint, Win32 key and text metadata), the
  `WM_KEYDOWN`/`WM_SYSKEYDOWN`, `WM_KEYUP`/`WM_SYSKEYUP` and
  `WM_CHAR`/`WM_SYSCHAR` handling, VK_PROCESSKEY rejection, character
  suppression and pending text-key state with its reset on focus loss
  (`handleFocus`), and IME composition-window placement. The ten keyboard
  tests move with the code and are registered in `src/apprt/win32.zig`.
- App's window procedure forwards those messages in one line each, as for
  the earlier layout and recovery extractions, and calls
  `Keyboard.handleFocus`. Mouse and the window procedure's mouse cases use
  `Keyboard.getModifiers`.
- A normalized comparison with `HEAD:src/apprt/win32/App.zig` (ignoring
  indentation, blank lines and the `App.getSurface` qualification) differs
  only in the four new forwarding signatures and their closing braces.

### Verification

- Debug build: 128/128 steps (`zig-out/logs/keyboard-build.log`). Win32 hook
  tests: 91/91 steps, 179 passed, one skipped, unchanged; all ten moved test
  names contain `Win32` and remain within the filter
  (`keyboard-win32-tests.log`).
- `test-windows-window-state.ps1 -TestCommandPalette` passed: text, Enter and
  command execution reached the shell, IME process Enter/Backspace were
  suppressed, the palette suppressed IME process Enter, function-key bindings
  drove splits/windows, and the process exited 0 without forced termination
  (`window-state-20261015-124426-277-75bc4ae9`).
- Parity passed, including search text entry, Unicode matches and input after
  search, exit 0 (`parity-20261015-124432-973.png`, inspected). The four
  modal-action cases, which use key bindings, passed with exit 0 and no forced
  termination (`modal-actions-20261015-124441-149`). No test processes
  remained (process query from the session; its output was not saved).
- Tested executable SHA-256
  `D626AA3A99243A6741C6623B915D26049B12ADB110FE6E36A03E6413B6825B16`.
- The checks above post synthetic messages. The owner then operated the same
  executable with the physical keyboard and the Microsoft Japanese IME in a
  dedicated key recorder (`zig-out/test-fixtures/keyboard-manual/`,
  `keys-25620.jsonl`, `session-20261015-125759.json`). IME conversion and
  commit of `日本語` produced UTF-8 `E697A5E69CACE8AA9E`, and the committing
  Enter did not submit the line. On the US layout, `Hello, World!` and
  `{}[]"@` arrived as typed; the four arrow keys arrived as arrow keys; Ctrl+C
  arrived as `C` with Control (U+0003) without ending the shell. The process
  exited 0 with no crash or leak markers.
- The owner found that committing only part of a composition (`にわにはにわ`,
  committing `庭には`) leaves the remaining `にわ` drawn over the committed
  text; the committed result `庭にはにわ` was correct. The composition window
  is positioned only at composition start, and the moved code is unchanged,
  but the previous executable was not run with the same steps. The cause is
  not yet confirmed. Tracked separately as
  [#48](https://github.com/fukuyori/ghostty/issues/48).
- Grouped manual acceptance has not been exercised. AltGr on the German
  layout was checked later in the final verification pass (see that entry).

### Handoff

- Continue with `Actions.zig`, then `WndProc.zig`. The WindowState additions
  (`showWindow`, `transferWindowState`, `presentSurface`,
  `toggleVisibility`) also remain.

## 2026-10-15: Window commands extraction (#12)

- Add `WindowCommands.zig` for `goto_window`, `goto_tab`, `move_tab`,
  `goto_split`, `resize_split`, `equalize_splits`, `toggle_split_zoom`, and
  tab activation (`activateWindowTab`). App action dispatch calls the module;
  CommandPalette, TabBarController and WindowLifecycle call
  `WindowCommands.activateWindowTab`. Code is moved unchanged apart from App
  helpers (`targetSurface`, `transferWindowState`, `presentSurface`) becoming
  qualified calls.
- `focusSearchPane` stays in App as the SearchBar entry point; the layout
  table assigns it to no module. `presentSurface`, `toggleVisibility`,
  `transferWindowState` and `showWindow` remain for the WindowState step.

### Verification

- Debug build: 128/128 steps (`zig-out/logs/window-commands-build.log`).
  Win32 hook tests: 91/91 steps, 179 passed, one skipped, unchanged
  (`window-commands-win32-tests.log`).
- No tracked script exercises `move_tab`, `goto_split`, `resize_split`,
  `equalize_splits` or `toggle_split_zoom`. An ad-hoc check
  (`zig-out/test-fixtures/window-commands-check.ps1`, untracked) launches a
  dedicated process with its own config and function-key bindings, posts
  key messages to the focused pane, and records visible pane widths, the
  focused pane, foreground state and the tab-bar accessible name after split
  right, `goto_split:left`, `resize_split:right,40`, `equalize_splits`,
  `toggle_split_zoom` twice, `new_tab`, `move_tab:-1` and `goto_tab:2`, then
  quits. Compared with the previous `zig-out/review-fixes-v2/bin/ghostty.exe`,
  two alternating runs of each matched at every step (widths 601/602 →
  641/562 → 601/602, zoom 1204, tab order and active tab), all exit 0
  without forced termination or crash/leak markers. Results:
  `zig-out/logs/window-commands-*-20261015-1230*.json` and `-1231*.json`.
- Retain the first comparison run: the new build recorded no focused pane
  during the split steps, so keys went to the left pane and the final focus
  differed (`window-commands-commands-20261015-123034-308.json`). Foreground
  was not recorded in that run, so its cause is not established; after
  adding foreground recording, all four runs had the window in the
  foreground and matched.
- `test-windows-window-state.ps1` passed, including `goto_window`
  navigation, multi-window close/recreate and split click focus
  (`window-state-20261015-123121-114-fc578e2e`); with `-TestCommandPalette`
  the palette checks passed (`window-state-20261015-123145-786-1c19c122`).
  Parity (including `goto_tab` cwd inheritance) and the four modal-action
  cases passed; all exits 0 without forced termination. Parity and palette
  captures inspected. No test processes remained (process query from the session; its output was not saved).
- Tested executable SHA-256
  `3A6FDC1B53FBBB93ECB60EB1D607A71ED3531DB663E37114669AA482F5F586AE`.
- Not exercised: command palette jump to another tab, physical input, and
  grouped manual acceptance.

### Handoff

- Continue with `Keyboard.zig`. The WindowState additions (`showWindow`,
  `transferWindowState`, `presentSurface`, `toggleVisibility`) also remain.

## 2026-10-15: Window lifecycle extraction (#12)

- Add `WindowLifecycle.zig` for window, tab, and split creation, core
  surface initialization and its rollback, `WM_CLOSE_SURFACE` close requests,
  surface/tab/window/all-window closure and confirmation, tab and window
  removal, and shutdown window teardown (`destroyAll`, called from
  `App.terminate` at the same point as the former inline loop). The close-tab
  mode test moves with `tabSelectedForClose` and is registered in
  `src/apprt/win32.zig`.
- App keeps `requestSurfaceClose` as the apprt entry point used by Surface and
  DeferredActions, and forwards to the module. Action dispatch, IPC request
  processing, the window procedure, ConfigActions (editor window) and
  TabBarController (tab close/new) call the module directly. Code is moved
  unchanged apart from `self.` calls becoming module calls.
- `showWindow` (the startup show), `transferWindowState`, `presentSurface`,
  `toggleVisibility` and `activateWindowTab` stay in App. The layout table
  assigns the first four to `WindowState.zig` and the last to
  `WindowCommands.zig`; they move in those steps.

### Verification

- Debug build: 128/128 steps (`zig-out/logs/window-lifecycle-build.log`,
  written by a rerun with `--summary all` because the first silent build left
  no log; the executable hash was unchanged). Win32
  hook tests: 91/91 steps, 179 passed, one skipped — the same count as before
  the move (`window-lifecycle-win32-tests.log`).
- `test-windows-window-state.ps1 -Executable zig-out\bin\ghostty.exe` passed,
  including multi-window create/close/recreate/close-all, splits, input, IME
  process keys and exit 0 without forced termination
  (`window-state-20261015-122011-569-0ae695bf`). A first run without
  `-Executable` exercised the default `zig-out\release` executable and is not
  evidence for this change.
- `test-windows-modal-actions.ps1`: RenameShellExit, CloseTabIndexShift,
  CloseAllShellExit and QuitShellExit passed, all exit 0 without forced
  termination (`modal-actions-20261015-122022-055`).
- `test-windows-config-diagnostics.ps1`: all eight cases passed, exit 0
  without forced termination.
- `test-windows-parity.ps1 -Executable zig-out\bin\ghostty.exe`: search,
  resize, input, mouse shape and window/tab/split cwd inheritance passed, exit
  0 (`parity-20261015-122100-930.png`).
- IPC `+new-tab` against a dedicated Debug instance, compared with the
  previous `zig-out/review-fixes-v2/bin/ghostty.exe`: both created the tab
  with client exit 0 and reported the fallback window, both logged
  `IPC client failed after response: error.OverlappedIoFailed` on the server,
  and both showed `Close Terminal?` on WM_CLOSE. The behavior is identical; the
  warning predates this change. Both test servers were ended by their own PID
  after the dialog check. Logs: `zig-out/logs/window-lifecycle-ipc-*`.
- No test processes from `zig-out` remained (process query from the session; its output was not saved). Tested executable SHA-256
  `BC13A3462FEC07D1CC87DD366BF095D0874AD3831FE53395E4A2CD0A7E86689A`.
- Not exercised: physical input, injected creation failures (rollback
  paths, tracked as [#49](https://github.com/fukuyori/ghostty/issues/49)),
  and grouped manual acceptance.

### Handoff

- Continue with `WindowCommands.zig` (navigation, reordering,
  resize/equalize/zoom, tab activation).

## 2026-10-14: Review fixes for modal lifetime and accessibility

- Investigate the Claude Code review against the working tree. The old
  terminal child HWND had no accessible name: Computer Use reported the
  focused element as only `ウィンドウ`, while the parent and tab had titles.
  This is a confirmed name omission, not proof of the cause of every Narrator
  announcement. Do not treat the initial review's speech-cause claim as proven.
- Reproduce a separate lifetime failure: open tab rename with F4, then let
  that terminal's probe shell exit through a marker file. The pre-fix binary
  crashed with a segmentation fault and exit 3. The corrected binary exited 0
  on the same native-input sequence. The tracked synthetic regression also
  reproduces baseline exit 3 (`modal-actions-20261014-193012-767.json`).
- Add `DeferredActions.zig`. Close confirmations, rename and file-drop
  dialogs run only from the outer App loop. Requests own text and close
  selections, using core surface IDs instead of retained pointers or tab
  indexes. Resolve live targets again after a modal loop; discard pending
  owned requests at quit. Confirmation-free closure still posts immediately
  so shells and owners can close inside other modal loops.
- Name terminal child HWNDs, synchronize effective shell/tab titles (including
  background panes), and suppress redundant child-name updates. Mouse drag
  reorder now synchronizes accessible names and sends REORDER; new-tab and
  combined reorder/selection notifications put REORDER first.
- Keep the intentional config-diagnostic owner-discard policy unchanged.
  Correct the summary documents to include the owner's failed title-speech
  check separately from earlier recap observations. Clarify the rebranding
  plan's original decision dates versus the 2026-10-13 Gooztty spelling.

### Verification

- Final Debug build: 128/128 steps; Win32 hook tests: 179 passed, one skipped
  (91/91 steps). Logs: `zig-out/logs/review-fixes-build-v2.log` and
  `review-fixes-win32-tests-v2.log`.
- `scripts/test-windows-modal-actions.ps1` covers rename/shell exit,
  close-target identity after an earlier tab exits during confirmation,
  close-all/shell exit and quit/shell exit. All four pass on the corrected
  binary; all exit 0 without forced termination. These are synthetic-message
  checks, separate from the native-input checks below. Final result:
  `zig-out/logs/modal-actions-20261014-193150-681.json`.
- Existing config-diagnostic scenarios: eight passed
  (`config-diagnostics-20261014-192433-593.json`). Normal window-state
  regression passed (`window-state-20261014-192511-025-c48b073f`), including
  input, IME process keys, splits, reload, multi-window and normal exit.
  These monitor observations all reported 96 DPI; they are not a new mixed-DPI
  acceptance result. File-drop fixtures passed PowerShell, cmd and unsupported
  shell cases (`file-drop-20261014-193015-482.json`), including quoting,
  Unicode, target pane, no automatic Enter, and warnings. Captures inspected.
- Native Computer Use key/pointer checks: three tabs, drag active third tab
  into second position, open its close confirmation, exit the first probe
  shell, then accept. Only the originally selected terminal closed; the other
  terminal remained. The reordered accessible name said `Active tab 2` and
  matched visible order. Renaming the survivor updated the tab, parent and
  focused terminal name. Reopening rename and exiting its shell ended with
  code 0. No dedicated Ghostty processes remained after successful runs.
- Name evidence and manual exit records are under
  `zig-out/test-fixtures/review-fixes/`: `baseline-accessibility.json`,
  `fixed-accessibility.json`, `new-tab-name.json`,
  `reorder-accessibility.json`, `close-selection-after-exit.json`,
  `renamed-focus-name.json`, and `selection-fixed-exit.json`.
  Computer Use screenshots were inspected. The tool could not target cached
  dialog element indexes; refreshed screenshot-based clicks worked.
- Retain intermediate failures: the first implementation delayed even
  confirmation-free closure, preventing owner closure inside config dialogs.
  That run was interrupted and corrected; its prefix is
  `config-diagnostics-20261014-192247-726`. The first modal test fixture failed
  its visibility precondition because it launched hidden; explicitly showing
  its dedicated window fixed the fixture (`modal-actions-20261014-192932-153`).
  These are not passing final results.
- The owner confirmed post-fix Narrator title speech: `一番ウインドウ` and
  `読み上げ確認ウインドウ`. When asked whether the final new-tab title was
  announced automatically after F2 without an additional action, the owner
  replied `指示された操作のみで`. Title speech and the automatic new-tab
  final-title announcement are therefore confirmed by owner report. Audio was
  not independently captured, and no separate per-step speech transcript was
  supplied. The fixture and executable identity are recorded in
  `zig-out/test-fixtures/narrator-owner-20261014-195930/session.json`.
  This does not establish tab-role/ordinal speech, broad COM lifetime/threading
  behavior, or full terminal-content accessibility.
- File-drop unsafe confirmation was hardened by target revalidation; the
  normal formatter already rejects the
  control characters that trigger unsafe paste, so that branch was not reproduced.
- Final tested executable: `zig-out/review-fixes-v2/bin/ghostty.exe`, SHA-256
  `E6AC659E43CCF3BBFDF663D0A0E2B16A08B74C01D13398771C5BC3183954EED5`.
  Verification used a dedicated Debug build; no release package was created.

### Handoff

- The changes cover FileDrop, Mouse, TabBarAccessibility, NativeWindow,
  WindowLayout, SplitDivider and TabBarController extraction, plus the modal
  lifetime and accessible-title fixes above. Verification results are recorded
  per stage below; the final build results and owner speech confirmation are
  recorded above.
- Continue with `WindowLifecycle.zig`, followed by `WindowCommands.zig`.
  Preserve deferred modal execution and stable surface-ID target validation
  while moving creation, closure and teardown out of App.

## 2026-10-14: Tab-bar controller extraction (#12)

- Add `TabBarController.zig` for paint preparation, click/double-click,
  pointer hover and tracking, drag reorder, wheel selection, viewport,
  invalidation, and the tab-bar window procedure, including accessibility
  object retrieval and posted selection. Keep drawing/geometry and their
  existing tests in TabBar; Window retains tab and pointer state.
- Update App, WindowLayout, WindowAppearance and TabTitles callers. Register
  the module in App's comptime block and the existing Win32 test imports.
  Expose App's existing newTab, closeTab and transferWindowState helpers for
  the controller; their bodies remain unchanged pending lifecycle extraction.
- Preserve selection/focus on button down, capture release before button-up
  actions, double-click rename, drag thresholds, state transfer after reorder,
  overflow wheel directions, and accessibility dispatch. App is 401 lines
  shorter than the pre-move working tree.

### Verification

- Compare the three moved source blocks after reversing function names,
  qualification and method-call syntax and ignoring indentation. Compare
  the remaining App source after reversing imports, caller qualification and
  helper visibility changes. All comparisons matched:
  `zig-out/logs/tab-bar-controller-extraction-source-comparison.log`.
- Debug build: 128/128 steps succeeded
  (`zig-out/logs/tab-bar-controller-extraction-build.log`). Formatting and
  `git diff --check` passed. No test cases or tracked test scripts were added.
- The initial extraction recorded build-only evidence. On the subsequent
  explicit test request, Win32 tests with hooks passed: 91/91 steps succeeded,
  178 passed and one skipped
  (`zig-out/logs/tab-bar-controller-extraction-win32-tests.log`).
- The unmodified window-state regression passed, including input, synthetic
  IME process keys, split focus, config reload, multiple windows, four-monitor
  layout, maximize/minimize/restore and normal exit. Evidence:
  `zig-out/logs/tab-bar-controller-extraction-window-state.json`, prefix
  `window-state-20261014-174436-192-61cae162`. All monitors used 96 DPI.
- The existing title fixture passed OSC title/override/clear, double-click
  rename with Japanese text, cancel, and title restoration across tabs.
  Dialog and renamed-window captures were inspected. Evidence:
  `zig-out/logs/tab-bar-controller-extraction-titles.json`, capture/log prefix
  `tab-titles-20261014-174447`.
- A temporary controller fixture passed 11 synthetic-message checks: plus
  creation, selection/focus, ignoring wheel input without overflow,
  mismatched close-button release, drag reorder and release, native capture
  transfer to the terminal cancelling a pending reorder, closing the intended
  tab, both overflow wheel directions, previous/next buttons, posted
  accessibility selection with invalid-index guards, and resize/viewport
  restoration. Reordered and overflow captures were inspected. Evidence:
  `zig-out/logs/tab-bar-controller-extraction-interaction.json`, prefix
  `tab-controller-20261014-174648`; fixture:
  `zig-out/test-fixtures/tab-bar-controller-extraction/check-interaction.ps1`.
- The first controller-fixture run stopped at a premature visible-child
  assertion during second-tab creation. The native child is created before
  core initialization and layout. Update the fixture to wait for the expected
  child count, one visible terminal, and synchronized accessible tab count.
  The subsequent full run passed without product-code changes. Retain the
  first failure and stderr under `tab-controller-20261014-174613`.
- Successful GUI runs exited 0 without forced termination; no dedicated test
  processes remained. Human-operated physical devices, mixed-DPI
  transitions and screen-reader/COM client behavior remain unverified. The
  posted selection check is not COM-provider or WinEvent delivery evidence.
  Grouped manual acceptance remains due.
- After reconnecting Computer Use, native SendInput checks passed for plus
  creation, tab drag reorder/selection, split-divider dragging and click focus.
  Screenshots showed the divider move from x=502 to x=645 and the active-pane
  title change. These are injected pointer/key checks, not human-device evidence.
- IME checks used individual romaji key presses, not Unicode text injection.
  Both the rename dialog and terminal showed composition and the Japanese
  candidate list. Enter committed `日本語`; in the dialog it did not submit
  the form. Clicking OK applied the Japanese tab title. The terminal recorder
  captured exactly `日本語`, UTF-8 `E697A5E69CACE8AA9E`:
  `zig-out/test-fixtures/tab-bar-controller-manual/input-15416.jsonl`.
  Screenshots were inspected in the Computer Use transcript. Run summary:
  `zig-out/logs/tab-controller-native-20261014-180554-result.json`.
- In the first native-input run, mixed-DPI movement was not attempted: SystemSettings ran but was absent
  from the tool's targetable windows; no display setting was changed. Narrator
  started, then exposed an update window and reported higher-integrity
  accessibility restrictions. Audio was not captured, so screen-reader
  acceptance was initially pending. The user subsequently confirmed audible
  reading (「読み上げされた」). Record speech output as user-confirmed;
  the spoken content, target element and per-action announcements were not
  specified, so detailed screen-reader acceptance remains open.
  A close-button attempt while Narrator was active
  did not close the tab; this is inconclusive, not a controller failure verdict.
  Narrator cleanup was denied access and its normal exit chord did not stop it;
  manual exit is required. The dedicated Ghostty exited normally with code 0
  and no remaining recorder processes (`zig-out/logs/tab-controller-native-exit.json`).
- A subsequent run used the owner's existing display 1 (100%, 2560x1440)
  and display 2 (125%, 1920x1080), with no display-setting changes. Computer
  Use title-bar drags moved the same dedicated Ghostty to display 2 and back.
  Read-only `GetDpiForWindow` observations measured 120 DPI on display 2 and
  96 DPI after return. At 125%, divider dragging, pane focus, direct `1`/Enter
  input and plus-button tab creation passed. After return, the two tabs,
  adjusted split ratio and recorded input remained visible. Screenshots were
  inspected; intermediate cross-monitor captures were clipped by the tool.
  Evidence: `zig-out/logs/dpi-reader-observations.jsonl`,
  `zig-out/test-fixtures/tab-bar-controller-manual/input-23740.jsonl`, and
  `zig-out/logs/dpi-reader-20261014-182336-result.json`.
  A separate `type_text` attempt recorded `v` instead of the requested string;
  it is not counted as a passing text-entry test. Direct key input passed.
- With Narrator running, exercise rename to `1`, Tab navigation through
  OK/Cancel/edit, selection of `Ghostty input check 12820`, addition of
  `Ghostty input check 25820` and closure back to `Ghostty input check 12820`.
  Visual and accessibility-tree state matched these operations; the close
  button worked in this run. Spoken content initially awaited speech-recap review.
  Both Caps Lock+Alt+X and Insert+Alt+X through Computer Use failed to open
  recap; the first sent `x` to the recorder. The dedicated window and Narrator
  were left open for the user's physical recap shortcut and subsequent review.
- After the user opened speech recap, replay and compare actual Narrator
  history with the dedicated application's visible state. Selecting tab `1`
  produced `1 ウィンドウ`. The rename dialog announced `Change Tab Title`,
  the edit label and value `1`; Tab navigation announced `OK, ボタン`,
  `Cancel, ボタン`, and the edit value `2`. Commit produced `2 ウィンドウ`.
  Closing the newly added tab returned to the existing tab and announced
  `Ghostty input check 12820 ウィンドウ`. These scoped checks passed.
- New-tab announcement has a finding: creation announced `Ghostty ウィンドウ`,
  but after the shell changed its title to `Ghostty input check 39848`, that
  updated title was absent from speech recap, including a later observation.
  Record this as an observed missing automatic updated-title announcement;
  its cause and required behavior are not established. Tab selection/rename
  were announced as window titles; tab role, ordinal and explicit selected
  state were not confirmed in speech. This is not blanket screen-reader or
  COM/WinEvent acceptance. No product fix was made in this test task.
  Speech-recap screenshots were inspected in the tool transcript, and the
  observed phrases are in `zig-out/logs/dpi-reader-20261014-182336-result.json`.
  The dedicated Ghostty exited 0 without forced termination
  (`zig-out/logs/dpi-reader-exit.json`).
- In the subsequent owner-operated new-tab check, the user reported only
  `ウインドウ` being spoken. The owner did not hear the title. Keep this
  separate from the earlier automated recap observation (`Ghostty ウィンドウ`):
  both runs lacked an announcement of the final new-tab title. The requested
  owner check is complete with a failed title-announcement result; the cause
  remains uninvestigated and no product fix has been made. Dedicated process
  28584 was launched for this check; evidence is in
  `zig-out/test-fixtures/tab-bar-controller-manual/owner-session.json` and
  `zig-out/logs/reader-owner-check-20261014-185519-result.json`.
- Built `zig-out/bin/ghostty.exe`, working tree based on `61010d533`, SHA-256:
  `CA55637745D3C2F924F4C47213550EB2D8EFEF85AE05FEF4B302E0B3B9660B9E`.
  Earlier extractions remain in the working tree; pre-move snapshots are
  under `zig-out/test-fixtures/tab-bar-controller-extraction/`.

## 2026-10-14: Split divider extraction (#12)

- Add `SplitDivider.zig` for divider placement, gap sizing, painting/colors,
  invalidation, hit testing, drag/capture, cursor, and the divider window
  procedure. Window retains geometry and drag state. Update App,
  WindowLayout and WindowAppearance callers; move the existing DPI and
  high-contrast thickness test and register the module in Win32 tests.
- Preserve divider handling before terminal mouse input, minimum pane size,
  capture reset before tab switches and pane teardown, and layout order.
  Six extracted source blocks, including the existing test, compare equal
  after helper naming/visibility normalization:
  `zig-out/logs/split-divider-extraction-source-comparison.log`.

### Verification

- Debug build: 128/128 steps succeeded
  (`zig-out/logs/split-divider-extraction-build.log`). Win32 tests with hooks:
  91/91 steps succeeded, 178 passed and one skipped
  (`zig-out/logs/split-divider-extraction-win32-tests.log`).
- Unmodified window-state regression passed: initial divider placement,
  split click-to-focus, four-monitor layout, maximize/minimize/restore,
  config reload, multiple windows, and clean exit. Evidence:
  `zig-out/logs/split-divider-extraction-window-state.json`, log prefix
  `window-state-20261014-161131-712-9fe0c34b`.
- Reuse the temporary visible-window fixture from the layout extraction,
  including its explicit show/raise of the separate history window. Overlay
  search/wheel tracking, pane independence, resize, scrollbar drag, pane
  close during scrollbar drag, and history-boundary checks passed. Evidence:
  `zig-out/logs/split-divider-extraction-overlay-scrollbar.json`, prefix
  `window-state-20261014-161156-696-c8a053a2`. The split capture was inspected;
  the divider and both panes were visible. These drag checks exercise the
  scrollbar, not the split divider.
- Main/history exits were 0 without forced termination; no dedicated test
  processes remained. Formatting and `git diff --check` passed. All four
  monitor layouts used 96 DPI. Physical divider dragging, divider capture
  loss, mixed-DPI transitions, and grouped manual acceptance remain due.
  No tracked test scripts or test cases were added.
- Tested `zig-out/bin/ghostty.exe`, working tree based on `61010d533`, SHA-256:
  `D94799905377405559251316B9CFFF6E4434C9D46552F16A0BCAC0B74AF7BB78`.
  Earlier extractions remain in the working tree; pre-move snapshots are
  under `zig-out/test-fixtures/split-divider-extraction/`.

## 2026-10-14: Window layout extraction (#12)

- Add `WindowLayout.zig` for tab-bar, search, pane and scrollbar placement,
  tab-bar visibility policy, content bounds, DPI lookup/decoding, and native
  size/move/DPI handlers. Move the two existing visibility/DPI tests and
  register the module in Win32 tests and App's comptime block. Update App,
  ConfigActions, SearchBar, WindowAppearance and WindowState callers.
- Divider layout/gap and tab-bar viewport helpers remain in App, exposed for
  this module until their controllers are split. Preserve child visibility,
  search-space reservation, scrollbar placement, inactive-pane hiding,
  divider layout last, per-surface DPI callback order, and suggested-rectangle
  application. Source comparison confirms the moved functions, tests, and
  three message-handler bodies are unchanged after qualification/indentation:
  `zig-out/logs/window-layout-extraction-source-comparison.log`.

### Verification

- Debug build: 128/128 steps succeeded
  (`zig-out/logs/window-layout-extraction-build.log`). Win32 tests with hooks:
  91/91 steps succeeded, 178 passed and one skipped
  (`zig-out/logs/window-layout-extraction-win32-tests.log`).
- Unmodified window-state regression passed with exit 0 and no forced
  termination (`zig-out/logs/window-layout-extraction-window-state.json`).
  The four monitored layouts all used 96 DPI; this is not mixed-DPI evidence.
- Two initial parity runs stopped at `typing hides pointer`. The first
  diagnostic recorded the pointer over `MozillaWindowClass`; the second
  recorded it over the expected surface with visibility flag 1. Their logs
  and captures use prefixes `parity-20261014-155805-009` and
  `parity-20261014-155854-681`. Earlier search, eight resize cycles, and exact
  input-after-search checks had completed, but later pane/cwd checks had not.
- Compare against the cached pre-layout executable (SHA-256
  `BE1C8DA7DAA722BF940972F3673D24FE5EE9C16E7780879A32D2D4017260EEB8`),
  copied beside the same runtime dependencies as `ghostty-layout-baseline.exe`.
  The unchanged full parity script subsequently passed both baseline and
  current binaries, exit 0, with cwd inheritance enabled. Evidence:
  `zig-out/logs/window-layout-extraction-parity-baseline.log` and
  `zig-out/logs/window-layout-extraction-parity-final.log`; current result:
  `zig-out/logs/parity-20261014-160246-677.json`. Its search capture was
  inspected. The two earlier cursor failures are not treated as root-caused
  or fixed by this extraction.
- The existing visible-window overlay fixture initially failed to locate the
  reached-history-limit thumb in its separate history window (log prefix
  `window-state-20261014-160107-088-b8ce3eee`). A temporary copy also explicitly
  shows and raises that dedicated history window. The complete rerun passed
  search/wheel position tracking, pane independence, resize, drag, pane close
  during drag, and history-boundary checks. Main/history exits were 0 without
  forced termination; the split capture was inspected. Evidence:
  `zig-out/logs/window-layout-extraction-overlay-scrollbar-final.json`, prefix
  `window-state-20261014-160402-070-5e25ad72`; temporary fixture:
  `zig-out/test-fixtures/window-layout-extraction/window-state-visible.ps1`.
- Observed initial failure diagnostics are retained in
  `zig-out/logs/window-layout-extraction-initial-failures.json`. Tracked test
  scripts are unchanged. No dedicated processes remained; formatting and
  `git diff --check` passed. Physical input, mixed-DPI monitor transitions,
  and grouped manual acceptance remain due.
- Tested `zig-out/bin/ghostty.exe`, working tree based on `61010d533`, SHA-256:
  `A4379F34F8EDAD8EA13DDC9185C8661E0DC2246EDEA14F79F5C7BFB6B5D0FA3F`.
  Previous extractions remain in the working tree; pre-move snapshots are
  under `zig-out/test-fixtures/window-layout-extraction/`.

## 2026-10-14: Native window extraction (#12)

- Add `NativeWindow.zig` for the four class registrations, large/small icon
  loading and fallback, creation styles, and parent/surface/tab-bar/divider/
  message-only HWND creation. App passes its existing window procedures
  through a `Procedures` value; the new module does not import App.
- App retains userdata assignment, Window/Surface initialization and ownership,
  optional tab-bar/wakeup fallbacks, and cleanup ordering. Its existing native
  fullscreen/rendering integration test calls the new creation helper. Move
  the existing D3D11 extended-style and icon-resource fallback tests into the
  new module and register it in the Win32 test imports and App's comptime block.
- Source comparison against the pre-move working tree confirms unchanged
  registration, icon, style, HWND creation, and test bodies after naming,
  visibility, and explicit procedure-parameter normalization. The message-only
  creation body is unchanged, with userdata still attached immediately by App.
  Evidence: `zig-out/logs/native-window-extraction-source-comparison.log`;
  baseline: `zig-out/test-fixtures/native-window-extraction/App.before.zig`.

### Verification

- Debug build: 128/128 steps succeeded
  (`zig-out/logs/native-window-extraction-build.log`). Win32 tests with hooks:
  91/91 steps succeeded, 178 passed and one skipped
  (`zig-out/logs/native-window-extraction-win32-tests.log`).
- Unmodified window-state regression passed: class icons, native styles,
  initial grid and input, split focus, tab-bar/divider layout on four monitors,
  multiple windows, config reload, maximize/minimize/restore and clean exit.
  Evidence: `zig-out/logs/native-window-extraction-window-state.json`.
- Existing title fixture passed unchanged, including double-click rename,
  Japanese text, override/clear/cancel, and tab switching; the renamed-window
  capture was inspected. Evidence: `zig-out/logs/native-window-extraction-titles.json`,
  with capture/log prefix `tab-titles-20261014-155050`.
- All eight configuration-diagnostic lifecycle cases passed, including queued
  requests, owner/shell closure, another surviving window, and reload from a
  palette. The palette-reload diagnostic capture was inspected. Evidence:
  `zig-out/logs/native-window-extraction-config-diagnostics.json`, with
  capture/log prefix `config-diagnostics-20261014-155111-004`.
- All successful GUI processes exited 0 without forced termination; no
  dedicated test processes remained. Formatting and `git diff --check` passed.
  These are D3D11 Debug checks with synthetic input. OpenGL runtime, injected
  HWND/class-registration failures, physical shell/input behavior, and grouped
  manual acceptance were not exercised.
- Tested `zig-out/bin/ghostty.exe`, working tree based on `61010d533`, SHA-256:
  `BE1C8DA7DAA722BF940972F3673D24FE5EE9C16E7780879A32D2D4017260EEB8`.
  FileDrop, Mouse, and TabBarAccessibility extractions remain in the working tree.

## 2026-10-14: Tab accessibility extraction (#12)

- Move six App-side helpers into `TabBarAccessibility.zig`: accessible-name
  formatting and synchronization, list/child WinEvent notification, provider
  lookup, and window detachment. Move the name-format test and shared event
  identifiers too. App and TabTitles call the module directly; register it
  in the Win32 test imports and App's comptime block.
- Keep provider creation at the window-creation call site and `WM_GETOBJECT`
  and posted selection dispatch in App. Existing COM methods are unchanged.
  Name/selection/reorder notification order, child IDs, title fallback,
  allocator cleanup, and detachment before window/surface destruction are
  preserved. Source comparison against the saved pre-move working tree
  confirms the six functions and moved test are unchanged after naming,
  type qualification, and visibility normalization:
  `zig-out/logs/tab-accessibility-extraction-source-comparison.log`.

### Verification

- Debug build: 128/128 steps succeeded
  (`zig-out/logs/tab-accessibility-extraction-build.log`). Win32 tests with
  hooks: 91/91 steps succeeded, 178 passed and one skipped
  (`zig-out/logs/tab-accessibility-extraction-win32-tests.log`).
- Unmodified window-state regression passed, including input, synthetic IME
  process keys, split focus, monitor/layout checks and window lifecycle:
  `zig-out/logs/tab-accessibility-extraction-window-state.json`.
- The existing `zig-out/test-fixtures/tab-titles-split/check.ps1` passed
  unchanged: OSC title updates, setting/clearing overrides, override retention,
  Japanese rename, cancel, and tab switching. It checks the window title and
  tab-bar HWND text used as the accessible name. The dialog and renamed-window
  captures were inspected. Evidence:
  `zig-out/logs/tab-accessibility-extraction-titles.json`, with capture/log
  prefix `tab-titles-20261014-154213`.
- Both GUI runs exited 0 without forced termination and left no dedicated
  test processes. Formatting and `git diff --check` passed. This run does
  not establish screen-reader acceptance, WinEvent delivery to a client,
  or retained COM-reference behavior after window closure; those were not
  exercised. Grouped manual and screen-reader checks remain due.
- Tested `zig-out/bin/ghostty.exe`, working tree based on `61010d533`, SHA-256:
  `DC84CA5431160C6EA61130C77FCA238AB62F543283928F306307BC4D8729DB1B`.
  The preceding FileDrop and Mouse extractions remain in the working tree;
  pre-move snapshots are under `zig-out/test-fixtures/tab-accessibility-extraction/`.

## 2026-10-14: Terminal mouse extraction (#12)

- Move terminal button decoding and delivery, coordinate helpers, mouse-leave
  tracking, cursor-position callbacks, capture release, and vertical/horizontal
  wheel handling into the existing `Mouse.zig`. Move cursor shape/visibility
  actions and the three existing unit tests too; register Mouse in the Win32
  test imports and App's comptime block.
- App retains window-procedure dispatch and divider arbitration in their
  existing order. Shared keyboard/mouse modifier collection stays in App as
  `pub fn getModifiers`. The focus-before-capture sequence, button bitmask,
  right-release menu, no surface access after the modal menu, fractional
  vertical scrolling, and accumulated horizontal ticks are unchanged.
- Source comparison against the saved pre-move working tree confirms the
  moved bodies and action bodies are unchanged after module qualification
  and visibility changes. Evidence: `zig-out/logs/mouse-extraction-source-comparison.log`;
  baseline: `zig-out/test-fixtures/mouse-extraction/App.before.zig`. The preceding
  FileDrop extraction remains in the same working tree.

### Verification

- Debug build: 128/128 steps succeeded (`zig-out/logs/mouse-extraction-build.log`).
  Win32 tests with hooks: 91/91 steps succeeded, 178 passed and one skipped
  (`zig-out/logs/mouse-extraction-win32-tests.log`).
- Unmodified window-state regression passed, including input, synthetic IME
  process keys, split click-to-focus, monitor/layout and lifecycle checks:
  `zig-out/logs/mouse-extraction-window-state.json`. Exit 0, no forced termination.
- Unmodified parity regression passed with cwd inheritance enabled, including
  cursor shape/visibility and input after search; its search capture was
  inspected. Evidence: `zig-out/logs/mouse-extraction-parity.json` and
  `zig-out/logs/parity-20261014-153132-567.png`.
- The first context-menu run stopped before clicking because another window
  obscured the target; the failure capture confirms the obstruction
  (`zig-out/logs/blank-context-20261014-153145-501-failure.png`). A temporary
  copy raises only the dedicated test window. All blank-row, word-selection,
  drag-selection, and selection-preservation checks then passed through
  SendInput; the existing-selection/menu capture was inspected. Evidence:
  `zig-out/logs/mouse-extraction-context-menu-visible.json`, with screenshot
  prefix `blank-context-20261014-153216-127`.
- A temporary window-state copy explicitly shows and raises its dedicated
  window for the overlay-scrollbar pixel checks. Vertical wheel position,
  reveal/hide, reload, drag, pane independence, and pane closure during a
  scrollbar drag passed. The split capture was inspected. Evidence:
  `zig-out/logs/mouse-extraction-overlay-scrollbar.json`, with log/capture
  prefix `window-state-20261014-153245-501-ab99cd1a`.
- Temporary copies are under `zig-out/test-fixtures/mouse-extraction/`;
  tracked test scripts are unchanged. Successful GUI runs exited 0, with
  no dedicated test processes remaining. Formatting and `git diff --check`
  passed. Horizontal partial ticks and extra-button decoding are unit-test
  evidence; physical mouse/IME, terminal capture-loss acceptance, and grouped
  manual checks remain due.
- Tested `zig-out/bin/ghostty.exe`, working tree based on `61010d533`, SHA-256:
  `47FF4712AB5CE1394700A3735BAF7D42FCB632129136D30942F0109D6D6FACD7`.

## 2026-10-14: Native file-drop extraction (#12)

- Move `handleFileDrop` and `showFileDropWarning` from App into the existing
  `FileDrop.zig` as `handleDrop` and `showWarning`. App's window procedure
  retains the target-HWND guard, error logging/message selection, and the
  deferred `DragFinish`. Startup shell classification stays at its existing
  call site. Register FileDrop in the Win32 test imports and App's comptime
  block; its existing quoting and shell-classification tests are unchanged.
- Source comparison against `61010d533` confirms both function bodies are
  unchanged after module qualification and whitespace normalization. The
  arena, UTF-16 conversion, formatting, paste safety check, confirmation,
  warning text allocation, and cleanup ordering are preserved.

### Verification

- Debug build: 128/128 steps succeeded
  (`zig-out/logs/file-drop-extraction-build.log`). Win32 tests with hooks:
  91/91 steps succeeded, 178 passed and one skipped
  (`zig-out/logs/file-drop-extraction-win32-tests.log`). The `file drop`
  filtered run passed 78/78 tests
  (`zig-out/logs/file-drop-extraction-unit-tests.log`).
- The unmodified window-state regression passed with exit 0 and no forced
  termination (`zig-out/logs/file-drop-extraction-window-state.json`), with
  underlying logs prefixed `window-state-20261014-152346-801-4d48c359`.
- A dedicated native-message fixture posts UTF-16 `HDROP` payloads to child
  panes, transferring ownership only after a successful post. PowerShell
  and cmd startup configurations produced exact quoted text for multiple
  paths containing Japanese, spaces, apostrophes, ampersands, and parentheses.
  The two panes received only their own payloads, with no automatic Enter.
  Rejected control characters produced no input; cmd `%` and `!` paths and
  an unsupported startup executable displayed their expected warnings.
- The receiver records `Console.ReadLine` text; cmd mode starts that recorder
  through cmd. This verifies the shell-classified formatting and delivered
  text, not a fresh shell argument-parsing acceptance test. The fixture uses
  synthetic drops, not Explorer or a physical pointer. Unsafe-paste
  confirmation and closing an owner while a warning is open were not exercised.
- Initial native checks passed but their hidden main-window captures showed
  the desktop. The fixture now explicitly shows the dedicated main window
  and raises it for capture. The final run passed all three startup modes,
  each exiting 0 without forced termination:
  `zig-out/logs/file-drop-20261014-152441-862.json`. PowerShell/cmd pane
  captures and rejection-dialog captures were inspected. Earlier run:
  `zig-out/logs/file-drop-20261014-152357-055.json`.
- Fixture: `zig-out/test-fixtures/file-drop-extraction/run.ps1`, with its
  native helper and reader beside it. No dedicated Ghostty processes remained.
  Formatting and `git diff --check` passed. Grouped manual Explorer/drop and
  release acceptance remain due.
- Tested `zig-out/bin/ghostty.exe`, working tree based on `61010d533`, SHA-256:
  `0904002394CCF9E576529982E6AD70C6DD69648BC50EEE6F67A2E9CB251FA1C5`.

## 2026-10-14: Command-palette App-side extraction (#12)

- Move the toggle action's posted request and `showCommandPalette` into
  `CommandPalette.requestShow` and `CommandPalette.showForSurface`.
  The module owns the unchanged `WM_USER + 5` message constant; App's
  window procedure forwards that message to it. App retains the palette
  owner field and the surface/window models.
- Preserve the single-palette guard, action/title snapshots, source ownership
  and core ID checks after the modal loop, focus restoration, and the jump
  ownership/ID check before activation. Make App's existing tab-activation
  and surface-presentation helpers public for the moved code. Source
  comparison against `2471c0c19` confirms both extracted bodies are unchanged
  after qualification, parameter naming, and whitespace normalization.
- Register the existing palette module/test in the Win32 test imports and
  App's comptime block. No shared-core or dialog-control behavior changes.

### Verification

- Debug build: 128/128 steps succeeded
  (`zig-out/logs/palette-extraction-build.log`). Win32 tests with hooks:
  91/91 steps succeeded, 178 passed and one skipped
  (`zig-out/logs/palette-extraction-win32-tests.log`). The `palette query`
  filtered run succeeded with 77/77 tests
  (`zig-out/logs/palette-extraction-query-tests.log`).
- The unmodified window-state script with `-TestCommandPalette` passed:
  76 entries, arrow selection, dismissal/focus restoration, synthetic IME
  process-Enter suppression, snapshot retention during config reload, and
  owner closure with another surviving window. Exit 0, no forced termination.
  Summary: `zig-out/logs/palette-extraction-window-state.json`; underlying
  logs use `window-state-20261014-151604-398-d7db11c0`. Its palette capture
  was partly obscured by another window; use the unobscured capture below.
- The `PaletteReloadClose` diagnostic regression passed with exit 0 and no
  forced termination (`zig-out/logs/palette-extraction-diagnostics.json`),
  retaining deferred diagnostics when reload happens inside the modal loop.
- A dedicated action check passed duplicate-open suppression, filtered
  command execution creating a tab, a jump back to the original tab,
  ignoring a snapshot jump after its target closed, reopening the palette,
  and a selected close-source action. Exit 0, no forced termination.
  Summary and inspected capture:
  `zig-out/logs/palette-actions-20261014-151709-225.json` and `.png`.
  The retained fixture is `zig-out/test-fixtures/palette-extraction/actions.ps1`.
- Earlier fixture attempts assumed labels omitted shortcut suffixes and
  split panes had distinct palette labels. The existing UI includes the
  shortcut and uses the tab title for each split. The check now accepts the
  shortcut suffix and creates separate tabs for distinct jump labels. Those
  fixture failures exited 0 during cleanup; no product fix was required.
- No dedicated Ghostty process remained. Formatting and `git diff --check`
  passed. These are controlled Debug checks using synthetic input; physical
  keyboard/IME and grouped manual checks remain due.
- Tested `zig-out/bin/ghostty.exe`, working tree based on `2471c0c19`, SHA-256:
  `60F731360CC5B819C06B6FE670A4C3E58B0F6E126F460F2F1D3BEDFCCF0E9E96`.

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
