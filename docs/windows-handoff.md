# Gooztty Handoff

- Written: 2026-10-25, after `1.3.2-windows.17`
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

| Item | State on 2026-10-25 |
|---|---|
| Product | Gooztty, a native Windows terminal built from Ghostty. `1.3.2-windows.17` is the first version under this name; `1.3.2-windows.16` and earlier used the name Ghostty |
| Default branch | `gooztty` |
| `windows` | Windows port in step with upstream; merged into `gooztty` after every change |
| `main` | Mirror of upstream `ghostty-org/ghostty`, synchronized through `b58ef1d67`, the last upstream commit that builds with Zig 0.16 |
| Toolchain | Zig 0.16.0. Upstream moved to Zig 0.17 in `3d07ef9e2`; the migration is #50 |
| Version | `dist/windows/version.txt` holds `1.3.2-windows.17` on `gooztty`; `windows` keeps the value it had at the cutover |
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
acceptance. Thirteen work items are tracked under `Gooztty > 2026-11` in tque;
six deferred items are under `2026-12以降・候補`.
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
The Gooztty snapshot passed the same checks, with the same known config failure. OpenGL GUI checks passed; supplemental default builds match the tested binary hashes. Both merge commits are recorded in the migration ledger. Additional builds, Win32 tests, and resource checks at both committed SHAs passed. Claude Code found no defect requiring a fix; its notes and evidence timing corrections are recorded in windows-november-a-review-response.md. No push has been made.

Suggested order; details are in the issues and in roadmap Section 7.

1. **#72** `+ssh` opens a new console window. Options: attach to the parent
   console, a console helper executable for CLI actions, or document plain
   `ssh`.
2. **#69** Intermittent parity pointer-hide and scrollbar timeouts remain
   (N19). N01 completed on 2026-10-31: the old default executable was
   removed; fresh-build parity passed in both cwd modes on Windows and
   Gooztty. See the [preflight record](windows-november-preflight.md).
3. **#50** Zig 0.17 migration and the upstream commits after `b58ef1d67`,
   on `windows`, then merged into `gooztty`.
4. **#51-#65** Configuration options not implemented on Windows (see
   [configuration support](windows-config-support.md)).
5. **#9, #10** Several-hour soak and real GPU device loss.
6. **#66** Configuration diagnostic dialog outlives its owner in the
   regression test.
7. Other limitations and design questions: #11, #13, #14, #18, #25-#30, #44.

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




P0 investigation is complete; see [the investigation record](windows-november-p0-investigation.md). The #66 test closed a non-owner window; closing the actual owner passed on both products. The owner reported that taskbar close redirected to the dialog rather than closing the parent. The manual run timed out and remains a failed closure test. The test correction is still pending. N19 passed eight fixed-A runs without reproducing #69; the issue remains open. N15 resumes after this bounded investigation.


N07 was also part of P0 and has now been completed as an options review, not a selected implementation. See windows-november-ssh-options.md. P0's six children and its parent are done. N15 is complete at Windows 33709d14e and Gooztty d9cbeef; both snapshot stage checks are complete except the known config assertion (7/8 on each). Both lifecycle runs passed 37 cases with four inspected captures and no leftovers. The actual merges and committed build/Win32/version checks passed. N16 is now eligible but has not started. The preview version is aligned to 1.4.0-windows.1; final acceptance remains later work. See windows-november-b-migration.md and windows-november-b-results.json. Do not start N08 without an owner decision.




N16 is merged at Windows `06d12a298` and Gooztty `281c300ae`. Both lifecycle suites passed 37 cases with four inspected images. The config owner assertion and validate-config stdout-pipe FileTooBig issue remain open. See windows-november-c-migration.md.

