# N12: Real GPU Fault Procedure and Feasibility (2026-11-01)

N12 organizes how a real GPU fault could be caused for [#10](https://github.com/fukuyori/ghostty/issues/10)
and whether N13 can run. No fault was triggered while writing this record. #10 stays open.

## What is already verified

- Detection, diagnostics, automatic GPU resource re-creation, and the controlled regression with
  injected failures are implemented and pass (`-TestHooks` build, `-TestGpuRecovery`). They do not
  establish recovery from a real device loss.
- `src/apprt/win32/DirectComposition.zig` creates the device with `D3D11CreateDevice(null, .HARDWARE, ...)`
  and falls back to WARP. A null adapter means the default DXGI adapter; which physical GPU that is
  on a multi-GPU machine is not recorded by the application.
- On a failed `Present`, the runtime logs
  `IDXGISwapChain.Present detected device loss: hresult=0x... removed_reason=0x...`. The renderer
  logs `graphics device lost during frame preparation`, `recreating renderer GPU resources` and
  `renderer GPU resources recovered`; the Win32 runtime logs `D3D11 renderer recovered`.

## Machine state (read-only checks, 2026-11-01)

| Item | Value |
|---|---|
| OS | Windows 11 Pro 10.0.26300 |
| Adapters | AMD Radeon(TM) Graphics (driver 32.0.21036.18) and NVIDIA GeForce RTX 5070 (driver 32.0.16.1088), both status OK |
| Graphics tools | `C:\Windows\system32\DXCap.exe` and `d3dconfig.exe` present; `dxcap /?` lists `-forcetdr` |
| TDR registry values | None set under `HKLM\System\CurrentControlSet\Control\GraphicsDrivers`, so the documented defaults apply |
| Agent session | Not elevated. The Graphics Tools capability query needs elevation and was not run |

Which adapter drives each of the four monitors, and which adapter Gooztty's default device uses,
were not determined.

## Documented ways to cause a fault

| Method | Documented behavior | Fit for N13 |
|---|---|---|
| `dxcap -forcetdr` | Microsoft's device-removed guide: run while the app is running to force a GPU Timeout Detection and Recovery event, triggering `DXGI_ERROR_DEVICE_REMOVED`. `dxcap /?`: "Don't capture or replay, but simply force a GPU Timeout Detection and Recovery event, then exit." | **Primary.** Closest to a real driver timeout, repeatable, no registry change |
| `pnputil /restart-device <instance ID>` | Restarts devices; Windows 10 2004 or later; run from an elevated prompt | Secondary. A driver restart is a different path from a TDR. That it reaches the app as device removed is expected from the guide's "turned off" case but not verified |
| `pnputil /disable-device` then `/enable-device` | Disables and re-enables devices; `/force` exists for devices providing critical functionality | Not recommended on this machine. Disabling a display adapter can remove displays until it is re-enabled |
| TDR registry values (`TdrLevel`, `TdrDelay`, ...) | Microsoft: for driver development only; "End users shouldn't manipulate these registry keys" | Not used. `-forcetdr` does not need them |
| Driver update or reinstall | Listed by Microsoft as a cause of device removal | Not repeatable; record only if it happens during normal use |
| WHLK `SimulatePreemption TDR` | Requires the Windows Hardware Lab Kit | Out of scope |

Documented limits that bound a run: the default TDR limit is 5 TDRs within 60 seconds
(`TdrLimitCount`, `TdrLimitTime`); exceeding it crashes the computer. `TdrDdiDelay` defaults to
5 seconds before a `VIDEO_TDR_FAILURE` (0x116) bug check.

## Risks on this machine

- A TDR resets the GPU for every application using it, not only the test process. The owner's
  installed Gooztty, browsers and other work are affected. This is the owner's working machine, not
  a dedicated environment.
- Two adapters are present. Whether `-forcetdr` resets one adapter or both, and which one, is not
  documented in the sources read; the run must record it.
- `dxcap -forcetdr` and `pnputil` may require elevation. The agent cannot elevate; the owner runs
  them. The `dxcap` help places "Must be run with administrator credentials" next to `-usage`;
  whether `-forcetdr` itself needs elevation is unverified.
- Never run it during the N11 soak, as the plan already states.

## Proposed N13 procedure (not run)

1. Owner saves work and closes or accepts the effect on running GPU applications. Note the time.
2. Start a dedicated normal Release (not the owner's installed copy) with stderr captured, using
   `scripts/run-windows-diagnostics.ps1` or an equivalent that records its PID.
3. Open a window with text, a split and a tab so several surfaces exist.
4. From an elevated prompt run `dxcap -forcetdr` once. Wait at least 60 seconds before any repeat;
   at most three events in one session.
5. Check: the window repaints, typing and resize work, the stderr log contains the device-loss and
   recovery lines above with the `removed_reason`, a capture of the recovered window, a clean exit
   with code 0, and no leftover process started by the run.
6. Record the System event log entries for the display driver around the event time, the adapter
   that was reset, and the Windows and driver versions.
7. Optional second method: `pnputil /enum-devices /class Display` to read instance IDs, then
   `pnputil /restart-device <instance ID>` for the adapter Gooztty uses, with the same checks.

A failed recovery is recorded as a #10 defect, not retried until it passes.

## Owner decisions for N13

1. Whether N13 may run on this machine with running applications closed, or must wait for a
   dedicated environment. If allowed here, N13 can move into November, after N11 and not alongside it.
2. Whether the secondary `pnputil /restart-device` method should be included.

## Sources

- [Handle device removed scenarios in Direct3D 11](https://learn.microsoft.com/en-us/windows/uwp/gaming/handling-device-lost-scenarios) (Testing Device Removed Handling, `-forcetdr`)
- [Testing and Debugging TDR During Driver Development](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/tdr-registry-keys) (TDR registry values and defaults)
- [PnPUtil Command Syntax](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax)
- Local `dxcap /?` output on the machine above
