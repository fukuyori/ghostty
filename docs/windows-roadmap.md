# Ghostty Windows Production-Readiness Roadmap

- Last updated: 2026-09-15
- Target branch: `windows`
- Baseline commit: `132a5d078` (`docs: add Windows implementation roadmap`)
- Phase breakdown basis: the six phases agreed in the conversation as of 2026-09-14

## 1. Purpose

Bring the native Windows build of Ghostty up to the stability and usability
needed for daily use. Full implementation parity with the macOS/Linux builds
is not required; instead, bring the main features and user experience close
to them using approaches suited to the Windows API and desktop environment.

On this branch, implementation proceeds without waiting for the mattn build
to be merged upstream. Even if features later overlap with upstream or the
mattn build, production readiness takes priority, and differences will be
reconciled at merge time.

## 2. Repository Operation

| Remote | Purpose | push |
|---|---|---|
| `origin` (`fukuyori/ghostty`) | Development and publishing of the Windows build | Enabled |
| `upstream` (`ghostty-org/ghostty`) | Source for continuous merges from the official build | Disabled |
| `mattn` (`mattn/ghostty`) | Reference for the earlier Windows implementation | Disabled |

- The default development branch is `windows`.
- Upstream updates are merged explicitly from `upstream`.
- The mattn build is kept as a reference for history and implementation.
- Keep the settings that prevent accidental pushes to upstream/mattn.
- Commits, tags, pushes, and package creation are done only when explicitly
  requested.

## 3. Definition of Done

For the Windows build to be judged "production ready", all of the following
conditions must be met.

1. No crashes or leftover processes on normal exit, on closing a window, or
   on closing multiple windows.
2. `%LOCALAPPDATA%\ghostty\config.ghostty` is loaded and config reload works.
3. Keyboard, IME, mouse, selection, clipboard, and URL handling are usable.
4. D3D11/DirectComposition rendering is stable and transparency settings are
   applied.
5. The main operations for multiple windows, split panes, and tabs work both
   via the GUI and via key bindings.
6. Layout does not break on DPI changes, multiple monitors, maximize,
   minimize, or restore.
7. Release builds can be produced with a reproducible script.
8. The real-hardware test items for Windows 10/11 are satisfied and known
   limitations are documented.

## 4. Status Notation

- `Done`: the completion criteria are met and the build and relevant tests
  pass.
- `Partially done`: deliverables exist, but verification required for the
  release decision remains.
- `In progress`: the basic implementation exists, but unimplemented items or
  real-hardware verification remain.
- `Not started`: design or implementation has not begun.
- `On hold`: not currently enabled due to technical constraints or quality
  judgment.

Progress percentages are rough estimates of work volume, not test pass
rates. When completion criteria change, update the percentages and remaining
work in this document at the same time.

## 5. Overall Progress

| Phase | Content | Status | Estimate |
|---|---|---|---:|
| 1 | Basic runtime | Done | 100% |
| 2 | Rendering foundation | Done | 100% |
| 3 | Window features | Done | 100% |
| 4 | Split panes | Done | 100% |
| 5 | Windows GUI polish | In progress | approx. 98% |
| 6 | Release quality | Partially done | approx. 97% |

Overall progress is estimated at approximately 98%. On 2026-09-15 the first
preview build `1.3.2-windows.1` (tag `v1.3.2-windows.1`) was finalized after
passing Release verification, and `1.3.2-windows.2` (tag
`v1.3.2-windows.2`) followed as a bug-fix preview that resolves every known
issue of the first one. What remains is the per-environment GUI
verification in Phase 5, and the real-hardware tests and distribution format
decision in Phase 6. Release history is recorded in
`docs/windows-release-notes.md`.
Phase 5 covers not only tabs but also the title bar, mouse operation of split
dividers, GUI state display, appearance, DPI, and accessibility.

At the baseline `5ec0d2b05`, overall progress was about 70% and Phase 5 about
25%. Since then, the tab ownership foundation, tab operations, the tab bar,
click handling, drag reordering, mouse resizing of split dividers, split zoom
state display, and overflow handling for many tabs were implemented, and
custom tab renaming via existing actions and the GUI was added, so Phase 5
was updated to about 85%. Dedicated split divider rendering, DPI tracking,
and high contrast support were then added, raising it to about 88%.
Per-DPI tab bar fonts and repositioning verification across four monitors
were completed, raising it to about 90%. The default tab key bindings were
verified in the executable binary, and accessible names and state change
notifications for the tab bar were added, raising it to about 93%. Individual
tabs were then exposed as MSAA child elements, and selection and the default
action were verified, raising it to about 96%. Dedicated high contrast
handling was then added to the tab bar and title bar, raising it to about
97%. Finally, DPI and rectangle tracking of the tab bar and split dividers
across four monitors mixing 96 DPI and 120 DPI was verified with the Release
executable, raising it to about 98%.

## 6. Phase-by-Phase Plan

### Phase 1: Basic Runtime

Status: **Done**

Implemented:

- Win32 native application runtime
- Keyboard input and character input
- Clipboard
- Mouse input
- DPI, title, and focus handling
- IME composition window following the cursor position
- Safe rendering updates on the renderer thread
- Window close and process exit handling

Key commits:

- `667a1ed03` `win32: add minimal native application runtime`
- `b003769f3` `win32: add keyboard input handling`
- `e1144ab45` `win32: add clipboard integration`
- `62941c5f5` `win32: add mouse input handling`
- `1802c4d6b` `win32: add DPI, title, and focus handling`
- `d8bbd2aa0` `win32: position IME window at cursor`
- `fb451d5ea` `win32: keep buffer swaps on renderer thread`

Completion criteria:

- No dropped input, hangs, or crashes during basic terminal operation.
- Japanese IME conversion candidates appear near the input position.
- Copy, paste, and mouse selection work.

### Phase 2: Rendering Foundation

Status: **Done**

Implemented:

- OpenGL-compatible build and viewport synchronization
- DirectComposition rendering foundation
- Terminal shaders for D3D11
- D3D11 renderer
- Background transparency via `background-opacity`
- Experimental implementation of Windows backdrop and Gaussian blur
- Transparency and backdrop updates on config changes
- Image rendering for the Kitty graphics protocol, which needed both the
  OpenConsole ConPTY host (the one in `kernel32.dll` discards the APC
  sequences the protocol travels in) and a fix to the D3D11 image vertex
  shader, which passed a z that `ortho2d` turned into clip `z = -1` so
  every quad was clipped away

Known quality issues after phase completion:

- Images were not drawn at all until `1.3.2-windows.4`, and neither fault
  logged anything. This phase was marked done on text rendering alone.
- Background transparency is usable.
- Blur has an implementation path, but on some environments it produces an
  incomplete blur and does not meet the quality bar. The currently
  recommended state is blur disabled.
- Reliably mapping the `background-blur` value to the appearance on Windows
  is incomplete and is tracked as a Phase 6 quality issue.

Completion criteria:

- The terminal can be rendered with D3D11/DirectComposition.
- `background-opacity` is reflected on screen.
- A program using the Kitty graphics protocol can display an image.
- The OpenGL-compatible configuration can be built.

### Phase 3: Window Features

Status: **Done**

Implemented:

- Multiple windows
- Surface and window close lifecycle
- Loading and reloading the config file
- Opening the config file
- Opening URLs in the default application
- Maximize, fullscreen, decoration toggle, initial size, size reset
- Window title and focus synchronization

Quality issues after phase completion:

- Clean up Windows default shell detection and the `cmd.exe` fallback
  display.
- Creating multiple windows, closing them individually and all at once,
  moving focus between windows, and hiding and restoring all at once are
  verified by automated regression.
- Synchronization of a `window-show-tab-bar` config reload across multiple
  windows is verified by automated regression. Other GUI and surface settings
  are verified item by item.

Completion criteria:

- Changes to `%LOCALAPPDATA%\ghostty\config.ghostty` are correctly applied
  on restart or reload.
- Multiple windows can be closed safely, individually and all at once.
- Maximize, fullscreen, decorations, title, and focus can be operated.

### Phase 4: Split Panes

Status: **Done**

Implemented:

- Horizontal and vertical splits
- Moving focus to a split target
- Resizing splits via key bindings
- Equalizing split sizes
- Split zoom
- Closing a split surface and transferring focus
- Independent split tree per tab

GUI issues after phase completion:

- Mouse dragging and hover display of dividers are handled in Phase 5, as
  originally categorized.
- Tests combining complex split trees with tab switching are handled in
  Phase 6.

Completion criteria:

- Create, move, resize, and close do not break in nested configurations of
  2 to 6 panes.
- The original split ratio and focus are restored after unzooming.
- Pane operations do not affect the split state of other tabs.

### Phase 5: Windows GUI Polish

Status: **In progress (approx. 98%)**

Phase breakdown:

| Item | Progress | Status |
|---|---:|---|
| Native title bar | 90% | Native DPI tracking, dark mode, colors, sync with tab name, and high contrast implemented |
| Tab management foundation | 100% | Ownership structure and lifecycle implemented |
| Tab bar display | 100% | Basic rendering, state display, and overflow for many tabs supported |
| Tab operations | 100% | Select, close, add, rename, key/wheel navigation, and drag implemented |
| Split divider GUI | 95% | Dedicated rendering, hover, DPI and high contrast, drag, and minimum size constraints implemented |
| GUI state display | 80% | Focus, custom tab name, title, and split zoom state supported |
| Appearance and usability tuning | 90% | Divider display, tab bar DPI, system colors, and MSAA exposure of individual tabs implemented |

Implemented:

- `Window -> Tab -> Surface/SplitTree` ownership structure
- New tab, close tab, and moving to the previous/next/numbered/last tab
- Tab reorder action
- Per-tab split tree with focus retention
- Layout that shows only the active tab
- Tab title updates
- Native tab bar with tab names, close buttons, and a new tab button
- Deactivated owned-window approach that coexists with DirectComposition
- `auto`, `always`, and `never` for `window-show-tab-bar`
- Tab bar tracking of DPI, parent window movement, size, and visibility
- Adding, selecting, and closing tabs in the executable binary
- Tab reordering using the Windows drag threshold and mouse capture
- Retention of the active tab, focus, and split state during a drag
- Split divider hit testing that identifies the target in nested layouts
- DPI-tracking divider hit areas and horizontal/vertical resize cursors
- Drag resizing of split dividers using mouse capture
- Minimum pane size constraints based on cell dimensions and padding
- `ZOOM` indicator at the right end of the tab bar showing the active tab's
  split zoom state
- Even with `window-show-tab-bar=auto`, the tab bar is shown while zoomed
  to display the state
- Visible range and left/right scroll buttons for many tabs that keep a
  practical minimum width
- Automatic tracking that always keeps the selected tab within the visible
  range
- Previous/next navigation via the mouse wheel over the tab bar
- Tab drag reordering that can continue over the overflow scroll buttons
- Custom tab renaming via the existing `set_tab_title` and
  `prompt_tab_title` actions
- Native edit dialog opened by double-clicking a tab
- Priority rule that keeps a custom tab name for the tab's lifetime and
  reverts to the terminal title when left blank
- Synchronization of the active tab's custom name with the top-level window
  title
- Dedicated split divider window layered over DirectComposition that does not
  block the mouse
- Normal and hover divider colors blended from theme colors, with physical
  pixel width according to DPI
- System colors and a 2 logical px width under Windows high contrast
- Tab bar that uses the Windows window, text, and selection colors under
  high contrast
- Handling that removes the custom DWM title bar color when high contrast
  starts and returns it to system management
- Re-reading the high contrast state and reapplying the title bar on system
  color and theme changes
- Divider repositioning and redraw on system color and theme setting changes
- DPI tracking of tab bar height, padding, buttons, decorations, and the
  Segoe UI font
- Tab bar repositioning and redraw using the Per-Monitor V2 parent window
  DPI
- Exposure of the tab count, selected position, and selected title as the
  tab bar's accessible name
- Win32 accessibility event notifications on tab name, selection, and
  reorder changes
- Exposure of the tab list and individual tabs as MSAA page tab list and
  page tab elements
- Exposure of each tab's name, description, selection state, screen
  position, hit testing, and default action
- Connection of MSAA select and default action to the normal tab operation
  path for tab switching

Recent verification:

- 2026-09-14: Executed new tab, select first tab, and close first tab in
  sequence.
- Verified the native surface count changes `1 -> 2 -> 1`.
- Verified the displayed surface switches to the selected target after tab
  selection.
- 2026-09-14: In a 3-tab layout, dragged the first tab to the end and
  verified it remains active after reordering.
- Selected the first tab after reordering and verified the former second tab
  is displayed.
- 2026-09-14: Created a right split in the executable binary and dragged the
  divider 80px; verified the left pane width changes `601 -> 681px`.
- 2026-09-14: Enabled split zoom in a 1-tab layout and verified `ZOOM` appears
  at the right end of the tab bar without overlapping the tab name, close
  button, or add button.
- 2026-09-14: Triggered overflow display with a 14-tab layout and verified
  the left/right scroll buttons, the selected tab, and the add button do not
  overlap.
- Verified the active surface switches to the next target with the left
  scroll button and with the mouse wheel, respectively.
- 2026-09-14: Double-clicked a tab to set the custom name `Windows tab` and
  verified the tab's effective name and the top-level window title are
  synchronized.
- Confirmed with an empty edit field and verified the custom name is cleared
  and the terminal title reverts to `Ghostty`.
- 2026-09-14: Verified with the 96 DPI executable binary that a 1px split
  divider is created and changes from the normal color `0x4C4C4C` to the
  hover color `0xA5A5A5`.
- Dragged the same divider 60px and verified the divider window and the pane
  boundary move 60px.
- 2026-09-15: Moved the Release executable window across four monitors
  mixing 96 DPI and 120 DPI and verified with the automated regression
  script that the tab bar height switches between 32px and 40px, that the
  DPI of the parent matches that of the tab bar and split dividers, and that
  the split dividers track the content area.
- Verified by unit test that at 120, 144, and 192 DPI the tab bar height is
  40, 48, and 64px and the font height is 15, 18, and 24px.
- 2026-09-14: Verified in the executable binary's default key binding list
  that shortcuts for adding, closing, navigating, and reordering tabs are
  registered.
- Executed each action from temporary F5 to F9 bindings and verified the tab
  count, selected position, and reordered position are reflected in the
  accessible name in order.
- Verified in the executable binary that a name of the form
  `Ghostty tabs. 1 tab. Active tab 1: ...` can be obtained from MSAA
  `OBJID_CLIENT`.
- 2026-09-14: Retrieved a 2-tab layout as MSAA child count 2, list role 60,
  and tab role 37, and verified the individual names, the `selectable` and
  `selected` states, and selection value 2.
- Executed the MSAA default action on the first tab and verified the
  selection value changes `2 -> 1`.
- Retrieved individual tab information through both the IAccessible vtable
  path and the IDispatch path.
- Added MSAA regression tests that verify child ID ranges, selected and
  offscreen states, and first/last/previous/next navigation using pure
  functions shared with the implementation.
- Verified by unit test that the high contrast tab bar palette uses only
  system colors and no configured colors, and that the title bar reverts to
  the DWM default color.

Key commits:

- `59f3ff822` `win32: prepare native split windowing`
- `571e4d2c4` `win32: enable native terminal splits`
- `5ec0d2b05` `win32: complete split controls and backdrop effects`
- `7f698b54b` `win32: add native tab management and tab bar`

Remaining work (in order):

1. Add a right-click menu if needed.
2. Verify the dividers, tab bar, and title bar in an environment with high
   contrast actually enabled.
3. Verify the title bar, tab bar, and split dividers on real hardware at
   144 DPI and 192 DPI.
4. Verify individual tab names, selection state, and state change
   notifications with Narrator or NVDA on real hardware.
5. Verify GUI tracking on resume after actually putting the PC to sleep. The
   six Windows shell manual operations and controlled power resume via power
   notifications are verified.

Completion criteria:

- Tabs can be created, selected, moved, and closed via both key bindings and
  GUI operations.
- The pane layout within a tab is retained after switching tabs.
- The close button and the active tab remain reachable with many tabs.
- Split dividers can be identified with the mouse and dragged to resize.
- Main GUI states such as split zoom can be identified on screen.
- The tab bar does not linger, disappear, or shift position on window
  movement or state changes.
- A tab bar failure does not make Ghostty itself unable to start.

### Phase 6: Release Quality

Status: **Partially done (approx. 98%, preview build `1.3.2-windows.4` published)**

Implemented:

- Release build script for PowerShell `scripts/build-release.ps1`
- Basic Debug/Release build paths
- Windows production-readiness roadmap and verification matrix
- Windows build features, build instructions, and six-phase overview at the
  top of the README
- User guide summarizing the Windows build's build steps, config path,
  default keys, and known limitations
- Diagnostic launch script that saves standard output, standard error, and
  the exit code even under the GUI subsystem
- Window state regression script that, in a dedicated process with a
  temporary config, checks character input and command execution, config
  reload, creation/movement/hide-all/restore/individual close/close-all of
  multiple windows, config reload synchronization across multiple windows,
  Windows shell eligibility, mixed DPI monitor movement, tab bar and split
  divider tracking, maximize, minimize, restore, and clean exit
- Soak test script that runs the window state regression repeatedly by
  iteration count or duration, optionally adds consecutive GPU recreation
  and controlled power resume to each iteration, and incrementally saves
  results and log paths to JSON
- Manual acceptance test script that guides the user through Alt+Tab,
  taskbar, snap, and multi-window Windows shell manual operations, and
  through real-hardware sleep resume only when explicitly selected, and
  incrementally saves pass/fail, environment, and logs to JSON. Sleep resume
  also automatically cross-checks the power notifications and renderer
  recovery counts in the diagnostic log
- Handling that loads the multi-resolution Ghostty icon embedded in the
  executable at the system large and small sizes and sets it on the
  top-level window class. If the resource is missing, a warning is logged
  and startup continues with the Windows default icon
- Verification of the Release artifact's PE format, CPU architecture, GUI
  subsystem, embedded icon, and required resources
- Consistency check of the Release artifact's CLI version, Windows file
  version, product version, and Debug flag
- Handling that, on a D3D11 present failure, distinguishes DXGI device
  removed, hung, reset, and driver internal error, and records the present
  HRESULT and the result of `GetDeviceRemovedReason` in the diagnostic log
- Handling that, after device lost detection, recreates the D3D11 device,
  DirectComposition, shaders, swap chain, and image resources on the
  renderer thread and resumes rendering while keeping the existing terminal
  session
- Power resume handling that records a Windows suspend and, on the first
  resume notification, recreates the D3D11 renderers of all windows, all
  tabs, and all panes exactly once
- Controlled regression test that triggers the above resource recreation
  without causing a physical GPU failure and checks recovery completion and
  command execution in the same terminal session, once or a specified
  number of consecutive times
- Finite retry handling that, when GPU resource reinitialization fails,
  retries up to 6 times per cycle with renderer thread timer waits of 100ms,
  250ms, 1 second, 2 seconds, and 5 seconds, notifies the app when all
  attempts fail, and restarts for up to 3 cycles. After the final failure it
  stays in a rendering-stopped state, leaves a diagnostic log, and resumes
  on power resume
- Detection handling that, when frame preparation other than `Present`
  (buffer writes, texture uploads, target creation) fails, also queries the
  device removed reason and starts recovery if the device is lost
- Path that posts core wakeups to a message-only window so core mailbox
  processing does not stall during modal loops
- Close handling that suppresses duplicate close requests for the same
  surface and checks that a posted pointer is still alive before
  dereferencing it
- Fallback that continues window creation and runs without a tab bar even
  if tab bar creation fails
- Handling that keeps the active tab and focus when a split in a background
  tab is closed
- Handling that shows the same confirmation dialog as `close_all_windows`
  once for the `quit` action when there are running processes
- Handling that launches the regression and acceptance scripts with
  `--config-default-files=false` to isolate them from the user's config
- Compilation of the terminfo database on Windows with `tic` when it is
  available, installed next to the terminfo source so that programs reading
  terminfo can resolve `xterm-ghostty`
- Layout-independent key input handling that determines the physical key
  from the scan code and the core's key code table and obtains the
  unmodified character of the current layout with `ToUnicodeEx`. Only
  messages without a scan code fall back to the virtual key table.
  Keyboard messages carrying `VK_PROCESSKEY` are handed to the IME instead
  of the terminal, so keys consumed while composing do not reach the shell
- Handling that restricts test hooks (`GHOSTTY_TEST_DEVICE_RECOVERY`,
  `WM_USER+3/+4`, controlled failure injection) to builds with
  `-Dwin32-test-hooks=true`, with regression scripts querying hook
  availability right after startup
- In-process cache of compiled HLSL bytecode. Eliminates recompilation on
  device recovery
- Removal of the redundant `Flush` before `Present`
- Inclusion of the `src/build/WindowsVersionResource.zig` unit tests in
  `zig build test`
- Version numbering rule `X.Y.Z-windows.N` for Windows previews, with the
  sequence number `N` reflected in the fourth element of the Windows numeric
  version. The Release script checks consistency between the numeric and
  string versions
- Inno Setup script `dist/windows/ghostty.iss` and creation script
  `scripts/build-installer.ps1`. Copies the Release tree, checks the
  version, and offers per-user or all-users installation, a Start menu
  entry, an optional desktop icon and `PATH` addition, and English and
  Japanese wizards. `-Sign` applies SHA-256 Authenticode signatures and
  timestamps to the executable, installer, and uninstaller
- `docs/version-update-checklist.md`, which separates the version
  information paths and update conditions for Ghostty itself, libghostty-vt,
  and the source tarball
- Windows resource handling that generates the Windows numeric version,
  `FileVersion`, `ProductVersion`, and Debug flag from Ghostty's Semantic
  Version

Recent verification:

- Executed a nonexistent CLI action and obtained exit code 1 and the
  pre-initialization error message from the standard error log.
- Executed `+list-keybinds --default` and obtained exit code 0, the CLI
  output, and the `GHOSTTY_LOG` startup information from the standard output
  and standard error logs, respectively.
- 2026-09-14: All 109 build steps of the ReleaseFast, baseline CPU build
  succeeded.
- Verified the Release executable as `PE32+`, `x64`, and `WindowsGui`, and
  confirmed 7 shell integration files, 607 theme files, and a size of
  26341376 bytes.
- The Release executable's `--version` and `+list-keybinds --default`
  completed with exit code 0. The Authenticode signature is `NotSigned`.
- Verified that in the Debug build the CLI, `FileVersion`, and
  `ProductVersion` are `1.3.2-windows-+4a8fa7933`, the numeric version is
  `1.3.2.0`, and `IsDebug` is True.
- Verified that in a ReleaseFast build with `-Dversion-string=1.3.2`, the
  CLI and Windows string versions are `1.3.2`, the numeric version is
  `1.3.2.0`, and `IsDebug` is False.
- 2026-09-15: In a dedicated Release process, verified in sequence the
  normal state `1220x955`, maximized `2528x1456`, minimized, return to the
  previous maximized state, and restore to the normal state `1220x955`. The
  exit code after `WM_CLOSE` was 0 and no forced termination was needed.
- In the same dedicated process, verified top-level style `0x16CF0000`,
  extended style `0x00200100`, no owner window, root match, and DWM not
  cloaked. Structural eligibility for snap, Alt+Tab, and the taskbar was
  True in every case.
- 2026-09-15: Automatically moved a dedicated Release window across four
  monitors. The tab bar height was 32px on the three 96 DPI screens and
  40px on the one 120 DPI screen; verified the DPI match between the parent
  and the tab bar and split dividers, the ownership relation, width and
  origin, and tracking of the content area. The initial rectangle was
  restored after the test.
- Fixed a PTY read stop race detected in the exit test with split panes and
  verified exit code 0 with no forced termination across 3 iterations of
  the Debug build and in the ReleaseFast build.
- 2026-09-15: Had the Release executable load a temporary config created
  inside the repository, changed `window-show-tab-bar` through
  `always -> never -> always`, and ran a config reload each time. Verified
  the tab bar hides and reappears, and the subsequent mixed DPI, split, and
  exit tests succeeded across 3 iterations. The temporary config was
  deleted after each test.
- 2026-09-15: Sent a string and Enter to the Release executable's dedicated
  `cmd.exe` terminal and verified that a temporary marker inside the
  repository is created with the expected content. This exercised the path
  from terminal input through ConPTY to command execution in the shell; the
  temporary marker was deleted after the test.
- 2026-09-15: Created a second top-level window in the same Release process
  and verified shell eligibility. After closing only the second window with
  `WM_CLOSE`, the original window and the process survived, and after
  recreating it, `close_all_windows` terminated all windows and the process
  with exit code 0.
- 2026-09-15: Verified that `goto_window:next` moves from the original
  window to the second and the next operation cycles back to the original.
  Also verified that `toggle_visibility` hides both windows at once and
  running it again restores both.
- 2026-09-15: With two windows open, reloaded `window-show-tab-bar` through
  `always -> never -> always` and verified both tab bars hide and reappear
  in sync, and verified the ownership relation, position, and DPI after
  restoration.
- 2026-09-15: Ran the soak test script in fixed-count mode for 2 iterations
  and in duration mode for 1 iteration; config synchronization, window
  movement, visibility toggling, and clean exit succeeded in all 3 runs.
  Also verified that each iteration's results and log paths can be reloaded
  from the JSON. In an isolated test specifying a nonexistent executable,
  verified the failure count, error details, and incomplete state are saved
  to JSON.
- 2026-09-15: Ran the iterative soak baseline test of the Release executable
  20 times without waits, and all 20 independent processes completed with
  exit code 0. All records for config synchronization, window movement,
  visibility toggling, and clean exit succeeded, the 40 individual logs
  contained no known anomaly terms, and there were no leftover temporary
  files. Elapsed time was 40.054 seconds.
- 2026-09-15: Checked the list display and interactive recording path of the
  Windows shell manual acceptance test. In a control flow test with all 6
  items skipped, verified the distinction between completed and failed,
  JSON recording, the diagnostic log, normal exit, and temporary config
  deletion. When aborting at the first item, also verified the incomplete
  state and reason are saved, the process exits, and the temporary config is
  deleted. These are not pass confirmations of the shell manual operations.
- 2026-09-15: In manual operation on Windows 11, minimize/restore/focus from
  the taskbar, left/right snap, snap layouts, Alt+Tab and taskbar selection
  with 2 windows, and individual/all close from the taskbar preview passed.
  In Alt+Tab the window was shown and selectable, but the icon was not the
  Ghostty-specific one, so the overall result was recorded as 5 items passed
  and 1 item failed. There was no forced termination, log anomaly, or
  leftover temporary file.
- 2026-09-15: Fixed the issue where the large and small icons of the
  top-level window class were not set. The 110-item ReleaseFast build, the
  full window regression including the class icons, and a standalone visual
  retest of Alt+Tab succeeded. The manual acceptance test now also supports
  specifying items. In the first 3-iteration run, the existing window cycle
  wait timed out once, but the subsequent standalone run and a second
  3-iteration run all succeeded, so it was included in subsequent iterative
  verification.
- 2026-09-15: Ran a further 20 iterations on the icon-fixed Release, and all
  20 independent processes succeeded in 37.661 seconds. The window cycle
  timeout did not recur, and there were no problems with the records of all
  features, the 40 logs, exit handling, or temporary file deletion.
- 2026-09-15: Added embedded icon verification to the Release build script.
  The 110 ReleaseFast build steps succeeded, and 1 icon group and
  extractable large and small icons were confirmed in the artifact.
- 2026-09-15: Extended the D3D11 `Present` error diagnostics so that DXGI
  device lost HRESULTs and the device removed reason are distinguished and
  recorded. Completed unit tests for the error classification.
- 2026-09-15: Implemented automatic recreation of D3D11, DirectComposition,
  and renderer-owned GPU resources. Ran controlled recovery 20 consecutive
  times in the same terminal session of a dedicated Release process and
  verified 20 starts, 20 completions, 0 failures, and 0 known log anomalies.
  Also verified command execution after each recovery, the subsequent full
  window regression, exit code 0, and no forced termination. The normal
  regression with test hooks disabled also succeeded. Recovery from an actual
  GPU device lost or driver failure has not yet been verified.
- 2026-09-15: Implemented a path that handles `WM_POWERBROADCAST` suspend and
  resume notifications and recreates all D3D11 renderers on resume. Sent
  controlled notifications to a dedicated Release process; after recovering
  a single surface, all 3 surfaces of a split window and a separate window
  were recovered simultaneously. Re-execution due to duplicate resume
  notifications was suppressed; in total, verified 2 suspend detections, 2
  resume detections, 4 GPU recreation starts and 4 completions, 0 failures,
  terminal session retention, the full window regression, and clean exit.
  The OpenGL-compatible ReleaseFast build and the normal GUI regression also
  succeeded. A test that actually puts the PC to sleep has not yet been
  done.
- 2026-09-15: Added an explicitly selectable `power-resume` to the manual
  acceptance test. It is not included in the normal 6 items; after
  execution, the suspend/resume notifications, planned recovery count,
  completion count, and failure count are automatically cross-checked from
  the diagnostic log and saved to JSON. It is verified that the item list and
  the default 6 items are unchanged, but a pass/fail record from real
  hardware sleep has not been made.
- 2026-09-15: Made it possible to enable a GPU recreation count and
  controlled power resume from the soak test. Ran 20 independent processes
  on the Release build: all 20 succeeded, 0 failed processes, 0 invalid JSON
  records, 0 leftover temporary files. All 100 GPU resource recreations (5
  per process) completed, with 0 recovery failures, in 59.004 seconds.
- 2026-09-15: Fixed the issue where window class registration failed in the
  unit test executable, which has no icon resource. Icon loading is now a
  warning rather than a fatal error and continues with the default icon.
  Added a unit test for the fallback.
- 2026-09-15: On the current tree after the icon fix, passed the 138 Win32
  unit tests, the Debug build, and diff check, and ran the regression once
  with the Debug executable through 2 GPU recreations with 1 controlled
  failure, controlled power resume for a single surface and all 3 surfaces,
  4-monitor movement, multiple windows, and clean exit. Exit code 0, no
  forced termination, no leftover temporary files.
- 2026-09-16: Found and fixed why splitting a pane emptied it, and prepared
  `1.3.2-windows.5`. On `1.3.2-windows.4`, a split followed by a click back
  into the original pane showed nothing but the cursor, while the in-box host
  kept the text. Recording the bytes each host sent showed the OpenConsole
  host clearing lines with literal spaces (62 runs up to the full 140 columns,
  no erase sequences) and sending nothing at all on resize. Logging the resize
  showed the cause in Ghostty: narrowing from 140 to 69 columns took the
  screen from 30 rows to 90 and the cursor to row 0, because reflow kept the
  spaces as content and wrapped each row into three. Ruled out along the way:
  the `CreatePseudoConsole` flags (0x0, 0x1, 0x2, and 0x7 all emptied the
  pane), prompt clearing on resize (it ran but cleared nothing, as the shell
  emits no OSC 133 marks), and an intermediate tiny size (there was none).
  After the fix a split keeps the command and its output, a regression test
  fails without it, and the unit tests passed 3837 of 3899 with 62 skipped and
  0 failures. The right-aligned prompt still wraps its last character onto a
  new row when the pane narrows, on either host: it is real content out to the
  old right edge, and the shell does not redraw it.
- 2026-09-16: Found and fixed why programs could not draw images, and
  prepared `1.3.2-windows.4`. Two unrelated faults hid each other. Driving
  `CreatePseudoConsole` directly on Windows 11 26200 showed the ConPTY in
  `kernel32.dll` passing text and OSC but discarding APC, at flags 0, and
  the OpenConsole host passing all three, at flags 0, 0x7, and 0xF: it is
  the host, not the flags, and `PSEUDOCONSOLE_PASSTHROUGH_MODE` is in no
  Windows SDK header and changed nothing. With the OpenConsole host loaded
  from beside the executable, DA1 came back as Ghostty's `ESC [ ?62;22;52 c`
  rather than the in-box host's `ESC [ ?61;...c`, `ESC [ 16 t` reported the
  cell size, and the Kitty graphics query was answered. Images still did
  not appear: the D3D11 image vertex shader passed `z = 1.0` to a
  projection that negates z, so every quad sat at clip `z = -1` and was
  clipped away, with the placement built, the texture ready, and the draw
  call issued every frame and nothing logged. After both fixes,
  `terminal-browser` rendered a page in a ReleaseFast build.
  `scripts/build-release.ps1` and `scripts/build-installer.ps1` both
  succeeded, and the installer payload contained `bin\conpty.dll`,
  `bin\OpenConsole.exe`, and `THIRD-PARTY-NOTICES.md`. The window-state
  regression passed on the distribution build, and on the test-hook build
  with 2 controlled GPU recovery failures and power resume. A 20-iteration
  soak run completed 20 of 20 in 141.9 seconds with no failures. The unit
  tests passed 3835 of 3897 with 62 skipped and 0 failures across 77 build
  steps. `--version` and `+list-keybinds --default` returned exit code 0.
- 2026-09-16: Released the preview build `1.3.2-windows.3`. Built the
  distribution and `-TestHooks` ReleaseFast binaries with
  `-Dversion-string=1.3.2-windows.3` and confirmed `FileVersion`
  `1.3.2-windows.3`, numeric version `1.3.2.3`, `IsDebug` False, and a
  compiled terminfo database in both. The distribution build passed the full
  window-state regression including the IME, split focus, and startup grid
  phases, and `--version` and `+list-keybinds --default` returned exit code 0.
  The test-hook build passed the same regression plus 2 controlled GPU
  recovery failures and power resume across 3 surfaces, and a 20-iteration
  soak run completed 20 of 20 in 115.0 seconds with no failures and no
  leftover temporary files. The Win32, D3D11, and build helper unit tests
  passed.
- 2026-09-16: Investigated the reported imbalance between Latin and Japanese
  text and found the font size adjustment working as designed. Instrumented
  the fallback load path and measured, at `font-size = 12`: the primary face
  reports 1 em = 16.00 px and a cell width of 9.000 px; it has no ideograph,
  so `ic_width` is null and the estimator `min(asciiHeight, 2 x cell_width)`
  yields 18.000 px; the fallback face reports a real `ic_width` of 16.00 px,
  giving a factor of 1.1250, after which the face is 13.5 pt with an
  ideograph width of 18.00 px, exactly two cells. The instrumentation was
  removed after the measurement. Three separate problems were found instead:
  the configured `font-family` was `Moralerspace Neon Regular`, which is a
  style name rather than a family name and therefore matched nothing, and
  Ghostty silently used a different face without a warning in the diagnostic
  log; the automatic fallback on Windows takes the first font file in
  `%SYSTEMROOT%\Fonts` and then `%LOCALAPPDATA%\Microsoft\Windows\Fonts`
  that contains the codepoint, with no regard for monospacing, language, or
  pairing, because there is no equivalent of the CoreText
  `CTFontCreateForString` path used on macOS; and the size adjustment applies
  to automatic fallbacks but never to a face named in `font-family`
  (`src/font/SharedGridSet.zig`), with no setting to change either side. The
  asymmetry is upstream behavior and is left as is. The findings are
  documented in the "Fonts" section of `docs/windows.md` and tracked as
  issues 1 (silent substitution), 2 (first-match fallback), and 3 (the size
  adjustment asymmetry).
- 2026-09-15: Fixed keyboard focus not following a click into another split
  pane. Surfaces are `WS_CHILD` windows, which never take focus on their own,
  and `handleMouseButton` passed the event to the core without calling
  `SetFocus`. With a single pane the top-level `WM_SETFOCUS` handler always
  routed focus to the only surface, so the omission stayed hidden; after a
  split, the pane the split did not focus ignored every keystroke and looked
  unresponsive, while `goto_split` still worked. A press now focuses the
  surface under the cursor, and the existing `WM_SETFOCUS` handler updates the
  active tab and focused surface from there. Verified by measuring the focused
  window with `GetGUIThreadInfo`: before the fix a click on the other pane left
  focus on the split pane and typed text ran there; after it, focus and the
  typed command follow the click. Added a regression phase that clicks each
  pane in turn and requires focus to follow; it passed 3 consecutive runs and
  fails against the released 1.3.2-windows.2 build.
- 2026-09-15: Fixed `'xterm-ghostty': unknown terminal type.` reported by
  programs that read a terminfo database. Ghostty sets `TERM=xterm-ghostty`
  and points `TERMINFO` at the install tree, but the build skipped compiling
  the database on Windows (`if (os_tag == .windows) break :terminfo;` in
  `src/build/GhosttyResources.zig`), so only the source file was installed.
  Native Windows console programs ignore terminfo and were unaffected, which
  is why this went unnoticed. The build now compiles the database with `tic`
  when it can be found, searching the Git for Windows, MSYS2, and Cygwin
  locations in addition to `PATH`, and warns when it cannot. Verified that a
  clean build installs `67/ghostty` and `78/xterm-ghostty` next to the source,
  and that the compiled entry resolves. Separately, the ncurses build used by
  MSYS2 and Git Bash does not accept the Windows-style path Ghostty puts in
  `TERMINFO`; it does fall through to `~/.terminfo`, so a one-time
  `tic -x -o ~/.terminfo` there resolves the entry with `TERM` untouched,
  which was verified with a scratch home directory (`tput longname` reported
  `Ghostty` and `tput colors` reported 256). That step, and the equivalents
  for WSL and SSH, are documented in `docs/windows.md`. The Release build
  script now reports whether the compiled database is present and warns when
  it is missing.
- 2026-09-15: Finalized the preview build `1.3.2-windows.2` as a bug-fix
  release for `1.3.2-windows.1`. Built two ReleaseFast, baseline CPU binaries
  with `-Dversion-string=1.3.2-windows.2`, one for distribution and one with
  `-TestHooks`, and confirmed `FileVersion` `1.3.2-windows.2`, numeric version
  `1.3.2.2`, and `IsDebug` False. The distribution build passed the full
  window-state regression including the new IME and startup grid phases, and
  `--version` and `+list-keybinds --default` returned exit code 0. The
  test-hook build passed the same regression plus 2 controlled GPU recovery
  failures and power resume across 3 surfaces, and a 20-iteration soak run
  with GPU recreation and controlled power resume completed 20 of 20 in 110.7
  seconds with no failures and no leftover temporary files. The Win32, D3D11,
  and build helper unit tests passed. While running the soak, a pre-existing
  race in the regression script surfaced: the marker files are read while
  cmd.exe still holds them open, which raised a sharing violation. The marker
  waits now share a helper that treats that as "not ready yet".
- 2026-09-15: Fixed a bug where keys consumed by an IME also reached the
  terminal, so that during Japanese composition Enter inserted a newline and
  Backspace deleted already committed characters. Windows substitutes
  `VK_PROCESSKEY` for the virtual key of every keystroke an active IME
  consumes while leaving the physical scan code intact; because keys are
  resolved from the scan code, those messages produced real `.enter` and
  `.backspace` presses, and `shouldDispatchKeyPress` did not stop them
  because `VK_PROCESSKEY` is not a text virtual key. Printable keys produced
  no output because the apprt does not set `utf8`, so only control keys
  (Enter, Backspace, Tab, arrows, Escape) were visible. This was a
  regression from the scan code change in `eab11dfd5`: before it,
  `mapVirtualKey` returned `.unidentified` for `VK_PROCESSKEY` and the
  message was dropped. `WM_KEYDOWN`/`WM_KEYUP` now reject `VK_PROCESSKEY`
  and pass it to `DefWindowProc`. Verified by posting `VK_PROCESSKEY` with
  the real scan codes to a dedicated process: before the fix the Enter ran
  the pending command line and the Backspace turned `AB` into `A`; after the
  fix neither reaches the shell. Added a unit test and a regression phase
  that types a command, sends composition Enter and Backspace, and requires
  the shell output to be unchanged. The Release 1.3.2-windows.1 build fails
  that phase, and the fixed build passed it on 3 consecutive runs.
- 2026-09-15: Fixed a bug where the terminal grid and ConPTY remained at the
  default 800x600 equivalent right after startup. When `window-width` and
  `window-height` are set, the resize via `initial_size` during core
  initialization generates a `WM_SIZE` for the child window, but at that
  point `core_surface` is not yet set so `sizeCallback` is not called, and
  the relayout after initialization completes produces no notification
  because the rectangle is the same. Added a fix that synchronizes the size
  once right after the core is set, and verified that the reproduction steps
  that gave 26 rows before resize and 45 after on Release 1.3.2-windows.1
  now match in the fixed build. Added a phase to the regression script that
  launches a dedicated process with the tab bar hidden and `window-width`
  and `window-height` specified, and checks that the `mode con` row count
  right after startup matches the configured value 45 and does not change
  after a 1px resize. Verified 3 consecutive successes with the fixed Debug
  build and a failure with "26 rows" on the unfixed Release 1.3.2-windows.1.
  Because the bug is hidden by repositioning while the tab bar is shown, the
  check is performed with the tab bar hidden. Note that within roughly the
  first 100ms after startup, ConPTY has just been created at a provisional
  size and is changed to the configured size after the IO thread's coalescing
  timer. Additionally, fixed the issue where `zig build` without
  `-Dversion-string` failed on a checkout of tag `vX.Y.Z-<pre>`, so that the
  version is determined from the tag (verified that `--version` on a tagged
  checkout is `1.3.2-windows.1`).
- 2026-09-15: Added the installer creation script using Inno Setup. Created
  `ghostty-1.3.2-windows.1-x64-setup.exe` unsigned (about 17MB,
  `ProductVersion` and numeric version matching the executable), and
  verified with `-Sign` using a temporary self-signed certificate and no
  timestamp that SHA-256 signatures are applied to all three of the
  executable, uninstaller, and installer. The certificate and output were
  deleted after verification. Running the installer (installation, `PATH`
  addition, uninstallation) is not verified.
- 2026-09-15: Finalized the preview build `1.3.2-windows.1`. Built two
  ReleaseFast binaries with `-Dversion-string=1.3.2-windows.1`, one for
  distribution (no hooks) and one for regression (`-TestHooks`), and verified
  numeric version `1.3.2.1`, `IsDebug` False, and a match between the CLI
  version and the file properties. With the regression build, ran the full
  window regression including GPU recreation with 2 controlled failures and
  power resume of 3 surfaces, and the 20-iteration soak test (20 successes,
  0 failures, 51 seconds); with the distribution build, verified the normal
  regression and exit code 0 for `--version` and
  `+list-keybinds --default`. Added the release notes
  `docs/windows-release-notes.md` and recorded the version number and
  reproduction steps in the README and the user guide.
- 2026-09-15: Set the version numbering rule for Windows previews to
  `X.Y.Z-windows.N`, with the sequence number reflected in the fourth
  element of the numeric version. Added the rule, tag name, and verification
  procedure to `docs/version-update-checklist.md`. Verified file properties
  `1.3.2.4` and the correct `IsDebug` value both in the version resource
  unit tests and in a Debug build and the Release script (ReleaseFast, with
  a consistency check between the numeric and string versions added) with
  `-Dversion-string=1.3.2-windows.4`. When passing directly from PowerShell,
  the argument must be quoted.
- 2026-09-15: Fixed medium-severity item 9 and the low-severity code review items.
  Layout-independent key identification via scan codes and the unmodified
  character via `ToUnicodeEx`, restriction of test hooks to
  `-Dwin32-test-hooks` with pre-checks in the scripts, HLSL bytecode
  caching, removal of the `Flush` before `Present`, and inclusion of the
  version resource generation unit tests. Passed the Win32, D3D11, and build
  helpers tests, Debug builds with and without hooks, and diff check, and
  ran the regression with the hook-enabled Debug executable through 2
  controlled failures, power resume, 4 monitors, multiple windows, and clean
  exit. Verified that with the hook-less executable the script stops with a
  clear error instead of waiting. Real-hardware verification with other
  keyboard layouts has not been done. Splitting App.zig and direct back
  buffer rendering were deferred (see "Deferred items" below).
- 2026-09-15: Fixed the 4 medium severity code review items. Non-fatal tab
  bar creation failure, focus retention when closing a split in a background
  tab, the confirmation dialog for `quit`, and isolation of the regression
  and acceptance scripts from the user's config. Passed the Win32 unit tests,
  Debug build, and diff check, and ran the regression with a Debug executable
  that does not load the user's config through 2 controlled failures, power
  resume, 4 monitors, multiple windows, and clean exit.
- 2026-09-15: Fixed the 5 high severity code review items. Prevention of
  double-posted close requests and freed pointer dereferences, moving
  wakeups to a message-only window, timer-based retries for GPU recovery
  with failure notification and a cycle limit, detection of device lost
  occurring outside `Present`, and unzooming when a sibling of a zoomed pane
  is closed. Passed the Win32 unit tests, Debug build, and diff check, and
  ran regressions with the Debug executable for 2 controlled failures
  (recovered on the 3rd attempt) and 7 controlled failures (recovered on the
  2nd attempt of the 2nd cycle after 6 failures in the 1st cycle, about 21
  seconds), through power resume, 4 monitors, multiple windows, and clean
  exit. The stop path when all 3 cycles fail has not been verified in
  isolation.
- 2026-09-15: Added finite retries, up to 3 times, to GPU recreation. With 2
  controlled failures, recovery occurred on the 3rd attempt after 100ms and
  250ms waits, and the terminal session and the full GUI regression
  succeeded. With 3 controlled failures, verified 2 retry waits, 1 final
  failure, 0 fourth attempts, and 0 leftover temporary files. The D3D11 and
  OpenGL-compatible ReleaseFast builds also succeeded.

Remaining work:

- Continue using the diagnostic launch log for actual initialization failure
  and rendering recovery investigations and add items as needed.
- Test 144 DPI and 192 DPI, and resume after actually putting the PC to
  sleep. The DPI calculation unit tests, controlled power resume via power
  notifications, the iteration and duration scripts for long runs, and the
  20-iteration baseline results are verified; obtain results from runs of
  several hours.
- Establish a test method that safely causes an actual GPU device lost or
  driver failure and verify automatic recovery from a real failure.
  Detection, diagnostics, automatic GPU resource recreation, and the
  controlled regression are implemented and verified.
- Either quality-assure variable blur or finalize it as a limitation of the
  Windows build.
- Update the user guide according to the results of the remaining
  real-hardware tests and the release decision.
- The distribution formats are a portable executable and an Inno Setup
  installer, with signing done via the installer creation script's `-Sign`.
  From `1.3.2-windows.4` the signed installer is published as a release
  asset. Real-hardware verification of install, uninstall, and update
  through it remains.

Deferred items (raised in the 2026-09-15 code review, deferred by user
decision):

- Splitting the responsibilities of `src/apprt/win32/App.zig`. About 5000
  lines hold input, tab bar operations, split dividers, URL policy, and
  window state together, and a split like the GTK build's `class/*.zig` is
  desirable. It is a behavior-preserving refactoring, but the diff is large
  and re-running all regression scripts is a prerequisite. Start it before
  doing a batch of feature additions (right-click menu, settings GUI, etc.).
- Direct back buffer rendering when custom shaders are not in use. Currently
  every frame does a full-screen `CopyResource` from an offscreen target,
  and with linear blending the setup of drawing to an sRGB view and copying
  to a UNORM back buffer matches the Metal build. Switching to direct
  rendering would require redesigning this path and could change how colors
  appear. Start it if frame time or GPU usage measurements show a problem.

Completion criteria:

- The test table below is satisfied.
- The Release build starts in a clean environment.
- Known limitations and configuration methods can be found in the user
  documentation.
- When creating packages, verify the artifacts after an explicit request.

## 7. Next Steps

The automatable regression tests are all in place. `1.3.2-windows.3` is released
with the split focus, terminfo, and installer fixes, `1.3.2-windows.4` with the
image fixes, and `1.3.2-windows.5` is prepared with the split pane fix and
awaits its verification run. What remains is
verification that depends on real environments and real-hardware operation,
the font handling questions raised during the 1.3.2-windows.3 cycle, and the
distribution policy decision.

1. Verify individual tab names, selection state, and state change
   notifications with Narrator or NVDA. The automated regression tests and
   MSAA API checks are complete; screen reader acceptance verification
   remains.
2. Verify the split dividers, tab bar, and title bar in a high contrast
   environment.
3. Automated regression verification of the tab bar and split dividers on
   four monitors mixing 96 DPI and 120 DPI is complete. Perform the same
   verification on real hardware at 144 DPI and 192 DPI.
4. Actually put the PC to sleep with
   `scripts/test-windows-shell.ps1 -CheckId power-resume` and record
   rendering and input after resume together with the automatic diagnostic
   log cross-check.
5. Obtain soak results on the scale of several hours with
   `scripts/test-windows-soak.ps1 -DurationMinutes`. The 20-iteration
   baseline results are verified.
6. Decide how far to take font handling: whether to warn when a configured
   `font-family` matches nothing (issue 1), and whether to replace the
   first-match fallback scan with DirectWrite's font fallback (issue 2). The
   size adjustment asymmetry (issue 3) is upstream behavior and is left as is
   for now.
7. Decide on the handling of variable blur and reflect the decision in the
   user guide. The distribution format and signing are settled: a portable
   release tree plus a signed Inno Setup installer, published as a release
   asset from `1.3.2-windows.4`.

Items 1 to 5 require a real-hardware environment and operator time, so they
are performed in the user's environment. Items 6 and 7 are policy decisions;
the documents and scripts are updated once they are made.

## 8. Verification Matrix

`Not verified` means that real-hardware verification is not complete even if
the code exists.

| Category | Test item | Current |
|---|---|---|
| Startup | Debug build startup | Verified |
| Startup | Release build startup | PE, resources, CLI, and a dedicated GUI process verified |
| Release | `1.3.2-windows.1` | Regression, 20-iteration soak, and CLI verified with the distribution and regression Release builds. Signing at distribution time |
| Release | `1.3.2-windows.2` | Bug-fix preview. Regression including the IME and startup grid phases, 20-iteration soak, and CLI verified with the distribution and regression Release builds |
| Release | `1.3.2-windows.3` | Bug-fix preview. Regression including the split focus phase, 20-iteration soak, and CLI verified with both Release builds. Compiled terminfo shipped |
| Fonts | Family matching and fallback | Measured: a configured family that matches nothing is replaced silently, and the automatic fallback takes the first file containing the codepoint. Tracked as issues 1, 2, and 3 |
| Distribution | Inno Setup installer | Creation, signing, and publication verified; the published asset carries a valid Authenticode signature. Installation behavior not verified |
| Version info | CLI version display | Verified with the Release build |
| Version info | Windows file properties | String version, numeric version, and Debug flag verified for Debug and Release |
| Startup | Diagnostic log and exit code capture | Verified for both normal and failing CLI |
| Config | Config loading from LocalAppData | Verified |
| Config | Config reload | Tab bar hide/reshow via a temporary config and synchronization across multiple windows automatically verified with the Release build |
| Input | Keyboard and IME | Character input and Enter automatically verified with the Release build, IME basically verified |
| Input | Mouse and clipboard | Basic implementation done, regression verification needed |
| Rendering | D3D11 display | Verified |
| Rendering | GPU resource recreation | 100 consecutive controlled recreations and finite retries automatically verified with the Release build, real failure not verified |
| Rendering | Background transparency | Verified |
| Rendering | Variable blur | On hold |
| Window | Multiple windows | Create, move, cycle, hide-all/restore, individual close, and close-all automatically verified with the Release build |
| Pane | Create, move, resize, close | Basically verified |
| Pane | Mouse drag of dividers | Verified in the executable binary |
| Pane | Normal and hover rendering of dividers | Verified in the 96 DPI executable binary |
| GUI | High contrast rendering | Implemented for dividers, tab bar, and title bar, real environment verification needed |
| GUI state | Split zoom state display | Verified in the executable binary |
| Tab | Key operations | Default bindings verified, regression verification of actual operation needed |
| Tab | Accessibility | Individual tabs checked via MSAA and regression tested, screen reader not verified |
| Tab | Tab bar rendering | Verified |
| Tab | All tab bar click operations | Verified |
| Tab | Drag reordering | Verified |
| Tab | Overflow operations with 14 tabs | Verified |
| Tab | Setting a custom name and clearing it by leaving it blank | Verified in the executable binary |
| DPI | 96 DPI | DPI and rectangles of parent, tab bar, and split dividers automatically verified on 3 monitors |
| DPI | 120 DPI | 40px tab bar and split divider tracking automatically verified on real hardware |
| DPI | 144 and 192 DPI | Dimension and font generation tested, not verified on real hardware |
| DPI | Monitor movement between different DPIs | Automatically verified across 4 monitors at 96 DPI and 120 DPI |
| Window | Maximize, minimize, restore | Automatically regression verified in a dedicated Release process |
| Windows shell | Snap, Alt+Tab, taskbar eligibility | All 6 manual operation items verified with the fixed Release |
| Resume | Sleep | Recovery of all renderers via power notifications automatically verified with the Release build, real hardware sleep not verified |
| OS | Windows 11 | Basically verified in the development environment |
| OS | Windows 10 | Not verified |

## 9. Verification for Each Change

Depending on the scope of the change, run at least the following.

```powershell
zig fmt src/apprt/win32
zig build test -Dtest-filter=Win32
zig build
git diff --check
```

- GUI changes are not considered done on a successful build alone. Check the
  actual display or captured images.
- Input changes are verified by real-hardware key, mouse, and IME operation.
- Window lifecycle changes are verified for leftover processes and exit
  codes.
- Release artifacts are created only for script verification or on explicit
  request.

## 10. Known Risks

### Growing divergence from upstream

Because the Windows implementation moves ahead, conflicts are possible when
merging upstream. Keep commits per feature and run the Win32 tests before
and after merging.

### Duplicate implementation with the mattn build

The implementation may overlap with one that later lands upstream. At this
stage, do not wait; keep the reference available and check API boundaries
and licensing at integration time.

### Mixing DirectComposition with Win32 GUI

Ordinary GDI child windows may not render when combined with
`WS_EX_NOREDIRECTIONBITMAP`. Because the tab bar uses the owned-window
approach, focus testing on Z-order, DPI, monitor movement, and visibility.

### Environment differences in the Windows backdrop API

The presence and quality of blur vary with DWM/Windows.UI.Composition
support. Keep a fallback that does not lose startup or transparency on
failure.

## 11. Rules for Updating the Plan

When each step is completed, update the following in the same change or in
an immediately following documentation change.

1. Phase status and estimated percentage
2. Implemented items and remaining work
3. Verification matrix
4. Supporting commits
5. Newly discovered limitations and risks

When adding or removing steps, also review the completion criteria and
overall progress at the same time.
