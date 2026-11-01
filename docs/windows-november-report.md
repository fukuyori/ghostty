# November 2026 Report (N14)

Report for the [November work plan](windows-plan-2026-11.md), task N14
(tque #233). Written on 2026-11-01, when every technical task had finished
ahead of its planned date; the plan scheduled this report for 11/30. If
later November work changes anything below, this report is updated rather
than replaced.

## Outcome

- `1.4.1-windows.1` was released on 2026-11-01 from tag `v1.4.1-windows.1`
  (`a993a4ef8`). It is based on upstream 1.4.1 (`1.4.1-dev`, fixed commit
  `fbed180a5`) and built with Zig 0.17.0.
- The release candidate `dfe142a76` passed GUI, input and IME acceptance
  (N06), a 180-minute soak (N11), recovery from a real GPU timeout (N13) and
  signed artifact acceptance (N18). Evidence is in the
  [release notes](windows-release-notes.md#141-windows1), the
  [candidate ledger](windows-november-final-candidate-dfe142a.json) and the
  [N18 ledger](windows-november-n18-artifacts.json).
- The original technical target (N05, N15, N16, N17, N06, N11) was met. Work
  brought forward from December by the 2026-11-01 revision (N08, N09, N10,
  N12, N13, N18) was also completed.

## Tasks

| ID | Task | Result |
|---|---|---|
| N01 | #69 parity target and both products | Done |
| N02 | #66 config diagnostic owner | Investigated; the test correction was done in N20 |
| N03 | Fixed points, versions, direct build, dependencies and licenses | Done |
| N04 | Zig 0.16 baseline and real IME check | Done |
| N05 | Zig 0.17 migration (A) | Done |
| N06 | Acceptance of the candidate | Done on `dfe142a76` |
| N07 | #72 options review | Done; option 3 chosen for November (N08) |
| N08 | #72 documentation (option 3) | Done |
| N09 | #52 light/dark mode following | Done, owner-checked |
| N10 | #57 font size inheritance | Done, owner-checked |
| N11 | 180-minute soak | Passed 1803/1803 on the fourth attempt |
| N12 | #10 real GPU fault procedure | Done |
| N13 | #10 real GPU fault | Recovery passed; delayed redraw found (#74) |
| N14 | This report | Done |
| N15 | `v1.4.0` synchronization (B) | Done |
| N16 | Fixed C synchronization | Done |
| N17 | Candidate fixed | Done; rebuilt as `dfe142a76` after the revision |
| N18 | Signed artifact acceptance | Done |
| N19 | #69 bounded investigation | Not reproduced; #69 stays open |
| N20 | #66 config diagnostic test correction | Done (`14b911e80`) |
| N21 | Several `zig`/`pwsh` on `PATH` in scripts | Done (`bf90fbe7f`) |
| N24 | Split pane enumeration in the window-state check | Done (`c851ab1a9`); not the N11 cause |
| N25 | Child surface wait in the window-state check | Done (`fcffb9a38`); the N11 cause |

## Failures and Corrections During the Month

- N11 stopped three times before passing. The first stop is attributed to
  outside keyboard input during the run (likely, not proven); the second and
  third were a race in `test-windows-window-state.ps1`, first misattributed
  to split pane enumeration (N24) and then located by a traced loop and fixed
  (N25). The executable was not changed.
- The first N13 launch closed before the fault and was not counted.
- The first N18 release build differed from the candidate in the line
  endings of one share file, because the main checkout held its source with
  LF; it was restored and rebuilt.

## Issues

Closed in November: #9, #10, #50, #52 and #57.

Open and deferred to December candidates:

| Issue | Task | Note |
|---|---|---|
| #73 `validate-config` `FileTooBig` on a pipe | N22 | Known since fixed B |
| #72 `+ssh` opens a new console window | N23 | Documented as a known limitation (N08) |
| #74 Transparent window after real TDR recovery | N26 | Found by N13 |

Open without a November task: #66 (owner-reported taskbar close redirects
to the dialog; the test itself is corrected) and #69 (not reproduced).
Other open issues are listed in the [roadmap](windows-roadmap.md), Section 7.

## Documentation Consistency

Checked and corrected for this report:

- The user guide's Known Limitations now records the 1.4.1 verification, #73
  and #74, the feature gaps tracked as open issues (#14, #18, #25-#29, #44,
  #51, #53-#65) and the two deliberate differences (local file links, shell
  integration shells), as #30 asked.
- The configuration support table lacked `gtk-tabs-inverted`, added upstream
  in 1.4.0; it now has 213 options (◎43 ○95 △7 ✕23 -45), compared against
  `+show-config --default` of `1.4.1-windows.1`, and the README counts follow.
  `link` and `quick-terminal-size` are in the table but not in that output:
  `link` cannot be set and formats nothing, and `quick-terminal-size` prints
  nothing without a value.
- The release notes, changelog, roadmap and handoff record the release
  (`238f0887d`, `33baf9cc3`).

- The two stale source comments #30 pointed at (`src/config/Config.zig`
  calling Windows "not a real supported target" and `src/os/locale.zig`
  saying there is no official Windows version) were corrected on `windows`
  (`eca64ac2a`) by owner decision and merged into `gooztty` (`e6b63bda6`).
  Comments only; the released `1.4.1-windows.1` is unaffected. With this,
  every item of #30 is addressed.

## Not Verified

- Password and keyboard-interactive prompts through `+ssh`, and terminfo
  transfer during authentication.
- Mixed DPI, pointer hiding, N09 and N10 were owner-checked on earlier builds
  of the same code, not on the candidate executable itself.
