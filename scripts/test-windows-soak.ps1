<#
.SYNOPSIS
Repeatedly runs the Windows Release regression test.

.DESCRIPTION
Runs test-windows-window-state.ps1 in separate Ghostty processes and records
the result of every iteration. This exercises startup, terminal input, config
reload, split layout, monitor and DPI movement, multiple windows, visibility,
and graceful shutdown repeatedly without modifying the user's configuration.

The default mode runs a fixed number of iterations. When DurationMinutes is
greater than zero, the script keeps starting complete iterations until the
duration has elapsed; Iterations is ignored in that mode. A JSON checkpoint is
rewritten after every iteration so partial results survive an interrupted run.

.PARAMETER Executable
Ghostty executable to test. Relative paths are resolved by the underlying
window-state test from the repository root.

.PARAMETER Iterations
Number of complete regression iterations. The default is 20. Ignored when
DurationMinutes is greater than zero.

.PARAMETER DurationMinutes
Run complete iterations until this duration has elapsed. The default is zero,
which selects the fixed iteration mode.

.PARAMETER DelaySeconds
Delay between iterations. The default is one second.

.PARAMETER TimeoutSeconds
Maximum time the window-state test waits for each state transition.

.PARAMETER TestGpuRecovery
Run controlled D3D11 resource recovery during every regression iteration.

.PARAMETER GpuRecoveryIterations
Number of consecutive controlled GPU recoveries in each process. This requires
TestGpuRecovery. The default is 1.

.PARAMETER GpuRecoveryFailures
Number of controlled failures to inject for each newly created surface before
recovery can succeed. This requires TestGpuRecovery. The default is zero.

.PARAMETER TestPowerResume
Run the controlled Windows suspend and resume notification checks during every
regression iteration. This does not suspend the computer.

.PARAMETER SummaryPath
JSON checkpoint path. Relative paths are resolved from the repository root.
The default is a timestamped file under zig-out/logs.

.EXAMPLE
./scripts/test-windows-soak.ps1 -Iterations 20

.EXAMPLE
./scripts/test-windows-soak.ps1 -DurationMinutes 60

.EXAMPLE
./scripts/test-windows-soak.ps1 `
    -Executable zig-out/window-state-release/bin/ghostty.exe `
    -Iterations 3 `
    -DelaySeconds 0

.EXAMPLE
./scripts/test-windows-soak.ps1 `
    -Iterations 20 `
    -DelaySeconds 0 `
    -TestGpuRecovery `
    -GpuRecoveryIterations 1 `
    -GpuRecoveryFailures 2 `
    -TestPowerResume
#>
[CmdletBinding()]
param(
    [string]$Executable = "",
    [ValidateRange(1, 10000)]
    [int]$Iterations = 20,
    [ValidateRange(0, 10080)]
    [double]$DurationMinutes = 0,
    [ValidateRange(0, 3600)]
    [int]$DelaySeconds = 1,
    [ValidateRange(1, 60)]
    [int]$TimeoutSeconds = 10,
    [switch]$TestGpuRecovery,
    [ValidateRange(1, 100)]
    [int]$GpuRecoveryIterations = 1,
    [ValidateRange(0, 10)]
    [int]$GpuRecoveryFailures = 0,
    [switch]$TestPowerResume,
    [string]$SummaryPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "This script tests the native Windows Ghostty executable."
}
if (-not $TestGpuRecovery -and $PSBoundParameters.ContainsKey("GpuRecoveryIterations")) {
    throw "GpuRecoveryIterations requires TestGpuRecovery."
}
if (-not $TestGpuRecovery -and $PSBoundParameters.ContainsKey("GpuRecoveryFailures")) {
    throw "GpuRecoveryFailures requires TestGpuRecovery."
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$windowStateScript = Join-Path $PSScriptRoot "test-windows-window-state.ps1"
if (-not (Test-Path -LiteralPath $windowStateScript -PathType Leaf)) {
    throw "Window-state regression script not found: $windowStateScript"
}

$logDirectory = Join-Path $repositoryRoot "zig-out\logs"
[System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
    $summaryFile = Join-Path $logDirectory (
        "windows-soak-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff")
    )
} elseif ([System.IO.Path]::IsPathRooted($SummaryPath)) {
    $summaryFile = [System.IO.Path]::GetFullPath($SummaryPath)
} else {
    $summaryFile = [System.IO.Path]::GetFullPath(
        (Join-Path $repositoryRoot $SummaryPath)
    )
}
[System.IO.Directory]::CreateDirectory(
    [System.IO.Path]::GetDirectoryName($summaryFile)
) | Out-Null

$startedAt = Get-Date
$deadline = if ($DurationMinutes -gt 0) {
    $startedAt.AddMinutes($DurationMinutes)
} else {
    $null
}
$records = [System.Collections.Generic.List[object]]::new()
$problemPattern = [regex]::new(
    "Configuration Error|error waiting|error interrupting|" +
    "unexpected read thread|abrupt io thread|" +
    "failed to (schedule renderer recovery|recover renderer GPU resources)",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
$testStateRoot = Join-Path $repositoryRoot "zig-out\test-state"

function Write-SoakSummary {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [datetime]$StartTime,
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]]$Results,
        [Parameter(Mandatory)]
        [bool]$Complete
    )

    $finishedAt = Get-Date
    $failed = @($Results | Where-Object { -not $_.Success }).Count
    $summary = [ordered]@{
        StartedAt = $StartTime.ToString("o")
        UpdatedAt = $finishedAt.ToString("o")
        ElapsedSeconds = [Math]::Round(
            ($finishedAt - $StartTime).TotalSeconds,
            3
        )
        Mode = if ($DurationMinutes -gt 0) { "duration" } else { "iterations" }
        RequestedIterations = if ($DurationMinutes -gt 0) { $null } else { $Iterations }
        RequestedDurationMinutes = if ($DurationMinutes -gt 0) {
            $DurationMinutes
        } else {
            $null
        }
        ControlledGpuRecovery = [ordered]@{
            Enabled = [bool]$TestGpuRecovery
            IterationsPerRun = if ($TestGpuRecovery) {
                $GpuRecoveryIterations
            } else {
                0
            }
            FailuresPerSurface = if ($TestGpuRecovery) {
                $GpuRecoveryFailures
            } else {
                0
            }
        }
        ControlledPowerResume = [bool]$TestPowerResume
        Completed = $Complete
        TotalRuns = $Results.Count
        PassedRuns = $Results.Count - $failed
        FailedRuns = $failed
        Results = $Results
    }
    $json = $summary | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText(
        $Path,
        $json + [System.Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

$run = 0
$complete = $false
try {
    while ($true) {
        if ($DurationMinutes -gt 0) {
            if ($run -gt 0 -and (Get-Date) -ge $deadline) {
                break
            }
        } elseif ($run -ge $Iterations) {
            break
        }

        $run++
        $runStartedAt = Get-Date
        Write-Host "[$run] Starting Windows Release regression."
        try {
            $arguments = @{
                TimeoutSeconds = $TimeoutSeconds
            }
            if (-not [string]::IsNullOrWhiteSpace($Executable)) {
                $arguments.Executable = $Executable
            }
            if ($TestGpuRecovery) {
                $arguments.TestGpuRecovery = $true
                $arguments.GpuRecoveryIterations = $GpuRecoveryIterations
                $arguments.GpuRecoveryFailures = $GpuRecoveryFailures
            }
            if ($TestPowerResume) {
                $arguments.TestPowerResume = $true
            }
            $result = & $windowStateScript @arguments
            if ($result.ExitCode -ne 0 -or $result.ForcedTermination) {
                throw (
                    "Regression returned ExitCode={0}, ForcedTermination={1}." -f
                    $result.ExitCode,
                    $result.ForcedTermination
                )
            }

            $stderr = [System.IO.File]::ReadAllText($result.StderrLog)
            $problem = $problemPattern.Match($stderr)
            if ($problem.Success) {
                throw "Regression log contains '$($problem.Value)'."
            }

            $temporaryEntries = if (Test-Path -LiteralPath $testStateRoot) {
                @(Get-ChildItem -LiteralPath $testStateRoot -Force).Count
            } else {
                0
            }
            if ($temporaryEntries -ne 0) {
                throw "Regression left $temporaryEntries temporary test-state entries."
            }

            $records.Add([pscustomobject][ordered]@{
                Run = $run
                Success = $true
                StartedAt = $runStartedAt.ToString("o")
                ElapsedSeconds = [Math]::Round(
                    ((Get-Date) - $runStartedAt).TotalSeconds,
                    3
                )
                ProcessId = $result.ProcessId
                MonitorCount = @($result.MonitorLayouts).Count
                ConfigReload = [bool](
                    $result.MultiWindow.ConfigReloadHidden -and
                    $result.MultiWindow.ConfigReloadRestored
                )
                WindowNavigation = [bool]$result.MultiWindow.Navigation
                VisibilityToggle = [bool](
                    $result.MultiWindow.HiddenTogether -and
                    $result.MultiWindow.RestoredTogether
                )
                GpuRecovery = if ($TestGpuRecovery) {
                    [bool](
                        $result.GpuRecovery.IterationsCompleted -eq
                            $GpuRecoveryIterations -and
                        $result.GpuRecovery.TerminalSessionPreserved
                    )
                } else {
                    $null
                }
                GpuRecoveryIterations = if ($TestGpuRecovery) {
                    $result.GpuRecovery.IterationsCompleted
                } else {
                    0
                }
                GpuRecoveryFailuresPerSurface = if ($TestGpuRecovery) {
                    $result.GpuRecovery.FailuresInjected
                } else {
                    0
                }
                PowerResume = if ($TestPowerResume) {
                    [bool](
                        $result.PowerResume.RendererRecovered -and
                        $result.PowerResume.TerminalSessionPreserved -and
                        $result.PowerResume.AllRenderersRecovered -and
                        $result.PowerResume.DuplicateResumeSuppressed
                    )
                } else {
                    $null
                }
                PowerResumeSurfaceCount = if ($TestPowerResume) {
                    $result.PowerResume.AllSurfaceCount
                } else {
                    0
                }
                GracefulExit = [bool](
                    $result.MultiWindow.CloseAll -and
                    $result.ExitCode -eq 0 -and
                    -not $result.ForcedTermination
                )
                StdoutLog = $result.StdoutLog
                StderrLog = $result.StderrLog
                Error = $null
            })
            Write-Host "[$run] Passed."
        } catch {
            $records.Add([pscustomobject][ordered]@{
                Run = $run
                Success = $false
                StartedAt = $runStartedAt.ToString("o")
                ElapsedSeconds = [Math]::Round(
                    ((Get-Date) - $runStartedAt).TotalSeconds,
                    3
                )
                ProcessId = $null
                MonitorCount = $null
                ConfigReload = $false
                WindowNavigation = $false
                VisibilityToggle = $false
                GpuRecovery = if ($TestGpuRecovery) { $false } else { $null }
                GpuRecoveryIterations = 0
                GpuRecoveryFailuresPerSurface = 0
                PowerResume = if ($TestPowerResume) { $false } else { $null }
                PowerResumeSurfaceCount = 0
                GracefulExit = $false
                StdoutLog = $null
                StderrLog = $null
                Error = $_.Exception.Message
            })
            Write-SoakSummary `
                -Path $summaryFile `
                -StartTime $startedAt `
                -Results $records `
                -Complete $false
            throw
        }

        Write-SoakSummary `
            -Path $summaryFile `
            -StartTime $startedAt `
            -Results $records `
            -Complete $false

        $hasAnotherRun = if ($DurationMinutes -gt 0) {
            (Get-Date) -lt $deadline
        } else {
            $run -lt $Iterations
        }
        if ($hasAnotherRun -and $DelaySeconds -gt 0) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    $complete = $true
} finally {
    Write-SoakSummary `
        -Path $summaryFile `
        -StartTime $startedAt `
        -Results $records `
        -Complete $complete
}

$finishedAt = Get-Date
[pscustomobject]@{
    SummaryPath = $summaryFile
    Mode = if ($DurationMinutes -gt 0) { "duration" } else { "iterations" }
    TotalRuns = $records.Count
    PassedRuns = @($records | Where-Object Success).Count
    FailedRuns = @($records | Where-Object { -not $_.Success }).Count
    ElapsedSeconds = [Math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
    Completed = $complete
}
