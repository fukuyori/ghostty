# Gooztty Handoff

- Written: 2026-10-25, after `1.3.2-windows.17`
- Updated: 2026-11-01, at the N17 candidate `1.4.1-windows.1`
- Audience: whoever continues this work, people or coding agents
- Read with: [`AGENTS.md`](../AGENTS.md) (rules and commands), the
  [roadmap](windows-roadmap.md) (status and open work), the
  [port log](windows-port-log.md) (decisions and evidence), and the
  [rebranding plan](windows-rebranding-plan.md) (naming decisions and branch
  rules)

This document summarizes where the project stands, how the work is done, and
what tripped us up. It records the state on the date above; check the
repository and GitHub before relying on any of it.

## 1. Current State

| Item | State on 2026-11-01 |
|---|---|
| Product | Gooztty, a native Windows terminal built from Ghostty. `1.3.2-windows.17` is the first version under this name; `1.3.2-windows.16` and earlier used the name Ghostty |
| Default branch | `gooztty` |
| `windows` | Windows port in step with upstream; merged into `gooztty` after every change |
| `main` | Mirror of upstream `ghostty-org/ghostty`, synchronized through `fbed180a5`, stage C of the November plan |
| Toolchain | Zig 0.17.0 (`minimum_zig_version` in `build.zig.zon`). The migration, #50, closed on 2026-10-31 |
| Version | `dist/windows/version.txt` holds `1.4.1-windows.1` on `gooztty`; `windows` keeps the value it had at the cutover |
| Artifacts | `gooztty-<version>-x64-setup.exe` (Inno Setup) and `gooztty-<version>-x64-portable.zip`, both signed by the owner |
| Rename | Complete; #31 is closed. `windows..gooztty` differs in code only in `src/brand.zig` |

Publication status lives in GitHub Releases, not in these documents.

## 2. How the Work Is Organized

- **Branches.** Changes flow upstream → `main` → `windows` → `gooztty` and
  never back. Port fixes and Windows support for upstream features go to
  `windows` first, even when found on `gooztty`; the rename and
  Gooztty-only features go to `gooztty`. Classify by purpose, not by file.
  `AGENTS.md` differs per branch; keep the `gooztty` text on merge conflicts.
- **Names.** Every product name comes from `src/brand.zig` (and `brand.json`
  for the PowerShell scripts). On `windows` the values are the Ghostty
  names; `gooztty` changes only the values. Do not spell product names in
  code; route new ones through `brand.zig`. Approved exceptions that keep
  `ghostty`: source identifiers shared with upstream, `window-theme =
  ghostty`, upstream URLs and attribution, version history, `libghostty-vt`
  and `ghostty.ico`/`ghostty.rc`/`ghostty.iss` file names.
- **Documentation.** `gooztty` maintains the README and `docs/windows*.md`;
  `windows` edits only `docs/windows-port-log.md`. After a `windows` merge,
  reflect new port-log entries in the roadmap.
- **No pull requests.** Commit directly to the owning branch.
- **Owner decisions.** Commits, pushes, tags and releases happen only when
  the owner asks. Installers and archives are built and signed by the owner,
  never by an agent. Never post issues or pull requests to
  `ghostty-org/ghostty`; use `gh -R fukuyori/ghostty`.

## 3. Build, Verify, Distribute

All commands run from the repository root in PowerShell.

| Task | Command |
|---|---|
| Debug build | `zig build` → `zig-out\bin\gooztty.exe` |
| Full Zig tests | `zig build test` (about 8 minutes) |
| Win32 tests with hooks | `zig build test -Dtest-filter=Win32 -Dwin32-test-hooks=true` |
| Window regression | `.\scripts\test-windows-window-state.ps1 -Executable <exe>` |
| Release tree | `.\scripts\build-release.ps1` → `zig-out\release` |
| Installer (owner) | `.\scripts\build-installer.ps1 -Sign` → `zig-out\installer` |
| Portable ZIP (owner) | `.\scripts\build-zip.ps1 -Sign` → `zig-out\zip` |

Raising the version follows [`version-update-checklist.md`](version-update-checklist.md):
edit `dist/windows/version.txt`, then the changelog, release notes and
roadmap. Pass `-Executable` to the regression scripts; without it some of
them run an old build (see #69).

## 4. Pitfalls Found During the Rename

- **Stale release prefix.** `zig build` adds to an existing prefix. A
  `zig-out\release` once built under the Ghostty name kept `ghostty.exe`,
  `share\ghostty` and the `xterm-ghostty` terminfo files, and the first
  Gooztty installer shipped the terminfo files. `build-release.ps1` now
  empties a prefix it built before and refuses other non-empty directories.
- **Embedded resources not rebuilt.** The resource compiler's cache did not
  follow `ghostty.ico` and `ghostty.manifest`, so an uncommitted icon change
  left the old icon in the executable. The generated version header now
  carries their hash. Check the icon with `ExtractAssociatedIcon` when in
  doubt.
- **Inherited variables in tests.** A shell inside Ghostty passes
  `GHOSTTY_RESOURCES_DIR` and friends to anything it starts; a test build
  then finds the installed resources instead of its own. Remove
  `GHOSTTY_*`/`GOOZTTY_*` from the child environment in checks, and isolate
  `LOCALAPPDATA`, `XDG_CONFIG_HOME` and `USERPROFILE` when testing
  configuration or terminfo so the owner's files are not touched. A renamed
  build removes the old terminal variables itself (#67).
- **win32-input-mode and IME.** PowerShell asks ConPTY for DEC mode 9001.
  Sending the releases of keys the IME took, or committed IME text as
  press-only key records, made PSReadLine repeat doubled characters. IME text
  is sent as plain UTF-8 now; cmd, Windows Terminal and WezTerm were the
  comparison points.
- **SSH.** OpenSSH for Windows cannot set up a ControlMaster, so the
  `+ssh` terminfo install uses a plain connection on Windows (#71). `+ssh`
  run from a shell opens a new console window (#72).
- **Window icons and DPI.** Class icons are sized for the system DPI; windows
  now load their own icons for their DPI (#70).
- **Build cache flakiness.** `ghostty-build-helpers-test` occasionally times
  out ("test runner failed to respond"); a rerun passed each time. The cause
  is unknown.
- **Running the installer.** Do not run an installer to inspect it; it
  installs. Inspect files and signatures instead. ISCC's `/O-` still deletes
  an installer of the same name in the output directory.
- **Killing processes.** Stop only processes you started, by PID. The owner
  usually runs Ghostty or Gooztty while working.

## 5. Open Work

The [November 2026 plan, revision 3](windows-plan-2026-11.md) provides the
seven-phase calendar and acceptance criteria: staged upstream integration
through `fbed180a5`, Gooztty integration at each stage, final audit and
acceptance. After the 2026-11-01 revision, eighteen work items are tracked
under `Gooztty > 2026-11` in tque; one deferred item (N13) remains under
`2026-12以降・候補`.
It takes precedence over the suggested order below. The historical state
in this handoff does not establish completion of any November work.

N01 and N03 completed on 2026-10-31. The
[preflight record](windows-november-preflight.md) fixes the toolchain,
dependency/license scope, Windows patch inventory and isolated-cache
procedure. Upstream A/B/C have not been merged into the Windows port.

N04's [Zig 0.16 baseline](windows-november-baseline.md) records the automated
comparison on both products. Config diagnostics failed the owner-close case
on both; GUI/parity results include failures and foreground/capture limits.
Additional Gooztty captures were inspected, with a scrollbar timeout retained for N19.
The owner accepted physical IME partial commit and focus resume on both products; both sessions exited cleanly. The owner also accepted IME placement during asynchronous output. Both asynchronous-output sessions exited 0 with their probes stopped. N04 is complete as a baseline record and N05 dependencies are satisfied. Config and scrollbar failures remain tracked by N02/N19.

N05 is complete; see the [fixed-A migration record](windows-november-a-migration.md).
main is at fixed A; Windows merged it at c6669ed65 and Gooztty integrated Windows at f2b98c662.
Windows D3D11 stage checks passed except the baseline config owner-close failure;
The Gooztty snapshot passed the same checks, with the same known config failure. OpenGL GUI checks passed; supplemental default builds match the tested binary hashes. Both merge commits are recorded in the migration ledger. Additional builds, Win32 tests, and resource checks at both committed SHAs passed. Claude Code found no defect requiring a fix; its notes and evidence timing corrections are recorded in
[windows-november-a-review-response.md](windows-november-a-review-response.md).

P0 investigation is complete; see [the investigation record](windows-november-p0-investigation.md). The #66 test closed a non-owner window; closing the actual owner passed on both products. The owner reported that taskbar close redirected to the dialog rather than closing the parent. The manual run timed out and remains a failed closure test. The test correction is still pending. N19 passed eight fixed-A runs without reproducing #69; the issue remains open.

N07 was also part of P0 and has been completed as an options review, not a selected implementation; see [the SSH options review](windows-november-ssh-options.md). P0's six children and their parent are done. N15 is complete at Windows `33709d14e` and Gooztty `d9cbeef`. N16 is complete at Windows `06d12a298` and Gooztty `281c300ae`; see the [B migration record](windows-november-b-migration.md) and [C migration record](windows-november-c-migration.md) for stage results and known config failures. The config owner assertion and the validate-config stdout-pipe FileTooBig issue remain open; #72's separate-console behavior also remains unresolved. N17 fixed candidate SHA `0a7cba0cbdaa4fc20988ed637e7b0b1582836332` at version `1.4.1-windows.1` passed normal/hook Release build and identity/resource checks in a clean worktree; see [the candidate ledger](windows-november-final-candidate.json) and Section 7. N06 was accepted on that candidate on owner reports (Section 7). On 2026-11-01 the owner decided to bring N08 (option 3), N09, N10, N12 and N18 into November and to rebuild the candidate, so N17 and N06 are repeated on the new candidate before N11 and N18. Do not start N08 without an owner decision.

Suggested order; details are in the issues and in roadmap Section 7.

1. **#72** `+ssh` opens a new console window. For November the owner chose
   to document plain `ssh` (N08, option 3); attaching to the parent console
   or a console helper executable remain options for a later fix.
2. **#69** Intermittent parity pointer-hide and scrollbar timeouts remain
   (N19). N01 completed on 2026-10-31: the old default executable was
   removed; fresh-build parity passed in both cwd modes on Windows and
   Gooztty. See the [preflight record](windows-november-preflight.md).
3. **#51-#65** Configuration options not implemented on Windows (see
   [configuration support](windows-config-support.md)).
4. **#9, #10** Several-hour soak and real GPU device loss.
5. **#66** Configuration diagnostic dialog outlives its owner in the
   regression test.
6. Other limitations and design questions: #11, #13, #14, #18, #25-#30, #44.

## 6. Where Things Are

| Path | Contents |
|---|---|
| `src/brand.zig` | Product names |
| `src/brand_env.zig`, `src/brand_text.zig` | Old-variable removal; compile-time message rewriting |
| `src/build/brand_rewrite*.zig`, `src/build/BrandRewriteStep.zig` | Build-time rewriting of installed files and help strings |
| `src/apprt/win32` | Win32 application runtime (fork-only) |
| `src/renderer/D3D11.zig`, `src/renderer/d3d11` | D3D11 renderer |
| `dist/windows` | Icon, manifest, resource script, Inno Setup script, `version.txt`, icon script |
| `scripts/*.ps1` | Release, installer, ZIP, diagnostics and regression scripts |
| `docs/windows-port-log.md` | Dated evidence, newest first |

## 7. Handoff update (2026-11-01)

### Current candidate and worktree boundaries

- Final candidate: detached worktree `.worktrees/n17-candidate-0a7cba0`, source SHA `0a7cba0cbdaa4fc20988ed637e7b0b1582836332`, version `1.4.1-windows.1`. Paths in this section are relative to that worktree. Candidate ledger: [`windows-november-final-candidate.json`](windows-november-final-candidate.json).
  - Normal Release executable: `zig-out/n17-candidate-normal-ledger/bin/gooztty.exe`, SHA-256 `57B87BF2CB9265037AE3C3BE7E48E71DC7E318D523F8D8056C643B208D156573`.
  - Hook Release executable: `zig-out/n17-candidate-hooks-ledger/bin/gooztty.exe`, SHA-256 `C16A94BC10B34C5DCBC609DC6B82FEB6551C38E7D0A4C5C0652AEDABEF4FC8B5`. Never distribute it.
- The candidate worktree was clean after verification. The primary `gooztty` worktree has owner changes in several documents and generated review/progress records. Preserve them; do not reset or clean either worktree. The owner's installed Gooztty process is separate from the candidate and must not be closed.

### N06 acceptance evidence

- Debug build and full Zig tests passed (4,259 passed, 67 skipped); normal and hook Win32 suites passed (197 and 196 respectively, one skipped each). Normal GUI/window-state, lifecycle (37/37 with four inspected captures), controlled GPU recovery and power notification checks passed. See candidate worktree `zig-out/logs` and `zig-out/test-fixtures` for the dated evidence.
- `verify-windows-ime.ps1` passed all seven steps. Physical Japanese IME partial commit, focus departure/return, and composition placement during asynchronous output were exercised on the fixed normal Release. The partial-commit and focus sessions exited 0. The focus probe's trailing full-width space was inserted by the test probe after focus returned. The asynchronous-output view was visually inspected but no screenshot file was saved.
- Owner confirmed the candidate's `mouse-hide-while-typing = true` behavior had no problem: typing hid the pointer and pointer movement restored it. The dedicated setting is in `zig-out/test-fixtures/mouse-hide-user-check/config`.
- The owner confirmed mixed-DPI behavior on the candidate with four monitors at 100% (main), 125% (second), 150% (third) and 100% (fourth); the check used the first three monitors and ended normally. An earlier machine query found all four monitors at 96 DPI; that query predates the scale change and is not the mixed-DPI evidence.
- The owner reported no problem after the #66 confirmation instructions. The #66 command's final JSON/result was not provided.
- Cwd-inheritance-disabled parity was attempted three times and stopped at `typing hides pointer`. Evidence: `zig-out/logs/parity-20261031-203609-071.json`, `parity-20261031-203649-316.json`, and `parity-20261031-203715-666.json`. Retain these as the failed automated attempts. The script synthesizes text with `WM_CHAR` plus key-up messages; the owner's physical pointer check passed. Treat the pointer timeout as an automation/manual discrepancy, not a confirmed product regression.
- The owner reported that the remainder of the disabled-cwd parity checks after `typing hides pointer` (pointer restore, OSC 22/OSC 7, new tab, split and new window cwd, per-pane search, clean exit; `scripts/test-windows-parity.ps1` lines 275-317) was tested and completed. How it was run, the executable used, and any result file were not recorded; no passing `parity-*.json` for the disabled mode is in the candidate's `zig-out/logs`. This gap is closed by the rebuilt candidate `dfe142a76`: its disabled-cwd parity run passed end to end (`zig-out/logs/parity-20261101-094652-754.json` in that worktree).
- Config diagnostics reported 7/8 with `OwnerCloseWithOtherWindow` failing `Stale diagnostic survived its owner` (`zig-out/logs/config-diagnostics-20261031-203751-125.json`). The P0 investigation recorded that this fixture closes a non-owner; closing the actual owner passed on both products. The owner separately reported no problem in the instructed #66 check. Keep the automated failure and owner report distinct; do not present it as a newly confirmed product defect or close #66 based only on the fixture result.
- N06 was accepted on candidate `0a7cba0` on the owner's reports above. Keep each claim within its evidence scope: the mixed-DPI and parity-remainder results are owner-reported, and the automated parity failures remain on record. Because the candidate is being rebuilt (see "Plan revision" below), N06 is reopened and must be repeated on the new candidate.

### N11 soak attempt and restart point

- The 180-minute run was attempted on the fixed normal Release with `-DurationMinutes 180`. It stopped in the first iteration after the window-state driver returned, when `scripts/test-windows-soak.ps1` passed an empty `$baselineTestStateEntries` value to `Compare-Object` (`ReferenceObject` null, line 269). Checkpoint: `zig-out/logs/n11-20261031-2117.json`. It records `Completed=false`, one failed attempt and zero passed runs. This is not soak acceptance evidence; retain it as the failed attempt.
- At the time, the candidate's `zig-out/test-state` directory existed but was empty. A PowerShell `if` statement unrolls an empty array to `$null`, so the baseline became `$null`. Do not overwrite the failed checkpoint; use a new summary path.
- The script is fixed in the `windows` worktree (`.worktrees/windows-nov`), not yet committed: both the baseline and the per-run entry lists now wrap the whole `if` in `@(...)`. The fix was checked for a missing, empty, grown and shrunk directory, and one `-Iterations 1` soak against the `0a7cba0` normal executable completed with one passed run, no failures and no leftover process. That single iteration is not soak acceptance evidence.
- The 180-minute run is to be made on the rebuilt candidate: `scripts/test-windows-soak.ps1 -Executable <absolute new candidate exe> -DurationMinutes 180`. Any failed iteration or incomplete duration means N11 remains open. The script runs dedicated test processes; it must not target the owner's installed Gooztty process.

### Plan revision (2026-11-01)

The owner decided to bring the December candidates that fit into November; see Section 10 of the [November plan](windows-plan-2026-11.md).

- New phase P3A (tque #247): N12 (#10 real GPU fault procedure), N09 (#52 light/dark theme following), N10 (#57 font size inheritance) and N08 (#72, option 3: document `+ssh`'s separate console as a known limitation and describe plain `ssh`). N18 moved to P5. N13 stays in the December candidates.
- N09/N10 are Win32 code changes on `windows`. To include them and the soak fix, the candidate is rebuilt: P4 (#238), N17 (#244) and N06 (#225) are reopened, and N17 now depends on N08/N09/N10. The `0a7cba0` records stay as the earlier candidate.

### Immediate continuation

1. N12 is done: see the [GPU fault procedure record](windows-november-gpu-fault-plan.md). Whether N13 may run on this machine is an owner decision.
2. N09 (#52), N10 (#57) and the soak fix are on `windows` (`0b28d0a3a`, `728dd9924`, `c47f092d4`) with owner display checks, and merged into `gooztty` at `90f286428`.
3. N08 is done: the `+ssh` limitation and plain `ssh` use are in `docs/windows.md`.
4. N17 is repeated: the new candidate is `dfe142a76` in `.worktrees/n17-candidate-dfe142a`, normal Release SHA-256 `73EC1252059675A13703E88AEEEF5B8172991F66435DC299CB436E18B4B45940`, hook Release `0CA27F117690BB297406409D894A40BF7C4053F867C61F3C566BEE9B848B9803`; see [its ledger](windows-november-final-candidate-dfe142a.json). `build-release.ps1` takes `zig` from `PATH`, so remove other Zig versions from `PATH` in the build process. N06 on this candidate (2026-11-01): full Zig tests 4,262 passed with 67 skipped; hook Win32 tests 200 with one skipped; normal window-state, controlled GPU recovery (three iterations, two injected failures) and power resume, and both parity modes passed, including `typing hides pointer`; config diagnostics 7/8 with only the known `OwnerCloseWithOtherWindow`; lifecycle 37/37 with HooksDisabled and four inspected captures; IME verification seven of seven. Evidence is under `zig-out/logs/n06-dfe142a` in the candidate worktree. `verify-windows-lifecycle.ps1` and `verify-windows-ime.ps1` take `pwsh` from `PATH` and fail when several are found; run them with one. The owner checked Japanese IME partial commit and focus departure (the IME commits the composition on leaving; input continues after return) on this candidate. Mixed-DPI, pointer hiding, N09 and N10 were owner-checked on `0a7cba0` or the `windows` Debug builds; the code for them is unchanged in this candidate, and the automated runs above cover the pointer and multi-monitor moves. The first 180-minute N11 attempt on this candidate (`zig-out/logs/n11-dfe142a-20261101-1017.json`, started 10:17) stopped at run 30 after 29 passes: the IME process-key check found an empty marker (`expected 'CD'`), the signature of an Enter reaching the shell early. Only run 30's log shows a Japanese glyph lookup (U+306F), which the test never types; the owner was typing at that time while the test window took the foreground, so outside input is the likely cause, but this is not proven. All 30 runs logged `IPC service unavailable: error.PipeAlreadyOwned` because the owner's manually started copy of the candidate held the pipe; that warning did not stop runs 1-29. Retain the failed attempt. Rerun only while nobody types on the machine, since every iteration takes the foreground. Next: rerun N11 for 180 minutes, then N18 with owner-signed artifacts.
5. Tracked follow-ups (2026-11-01): P3B (tque #248) holds two `windows` script fixes that do not change the candidate executable: N20 (#249) corrects the #66 config diagnostic test to close the real owner, and N21 (#250) makes `build-release.ps1`, `verify-windows-lifecycle.ps1` and `verify-windows-ime.ps1` cope with several `zig` or `pwsh` on `PATH`. December candidates: N22 (#251, issue #73, `validate-config` FileTooBig on a stdout pipe) and N23 (#252, #72 same-pane `+ssh`, starting with the option 2 prototype). The N08 terminfo command in `docs/windows.md` was run as written from PowerShell against `fuk@192.168.12.12` (public key, `BatchMode=yes`) on 2026-11-01: exit 0 with only `tic`'s description-field warning, `~/.terminfo/x/xterm-gooztty` rewritten at 10:29, and `infocmp -x xterm-gooztty` read the entry. The owner decided on 2026-11-01 to run N13 on this machine after N11 passes: one `dxcap -forcetdr` from an elevated prompt run by the owner, with running work closed, following the [N12 record](windows-november-gpu-fault-plan.md); N13 moved to P5 (tque #232). #52 and #57 were closed on 2026-11-01 with the fixing commits and checks. Open owner decision: when to rerun N11.
6. Do not commit, push, or change a candidate without an explicit request.
