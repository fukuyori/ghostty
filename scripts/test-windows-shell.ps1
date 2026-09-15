<#
.SYNOPSIS
Records the manual Windows shell acceptance test for Ghostty.

.DESCRIPTION
Starts a dedicated Ghostty process with a repository-local temporary config,
guides the tester through Alt+Tab, taskbar, and Snap operations, and writes a
JSON checkpoint after every answer. Existing Ghostty windows and the user's
configuration are not modified.

This test intentionally requires visual confirmation because window styles
and ownership alone do not prove the behavior of the Windows shell UI.

.PARAMETER Executable
Ghostty executable to test. Relative paths are resolved from the repository
root. The default is zig-out/release/bin/ghostty.exe.

.PARAMETER ResultsPath
JSON result path. Relative paths are resolved from the repository root. The
default is a timestamped file under zig-out/logs.

.PARAMETER TimeoutSeconds
Maximum time to wait for startup, shutdown, or cleanup. The default is 10.

.PARAMETER CheckId
Run only the selected checklist items. By default, all items are included.

.PARAMETER ListOnly
Print the acceptance checklist without starting Ghostty or prompting.

.EXAMPLE
./scripts/test-windows-shell.ps1 -ListOnly

.EXAMPLE
./scripts/test-windows-shell.ps1

.EXAMPLE
./scripts/test-windows-shell.ps1 `
    -Executable zig-out/window-state-release/bin/ghostty.exe `
    -CheckId alt-tab
#>
[CmdletBinding()]
param(
    [string]$Executable = "",
    [string]$ResultsPath = "",
    [ValidateRange(1, 60)]
    [int]$TimeoutSeconds = 10,
    [ValidateSet(
        "alt-tab",
        "taskbar-activation",
        "keyboard-snap",
        "snap-layout",
        "multi-window-shell",
        "taskbar-close"
    )]
    [string[]]$CheckId = @(),
    [switch]$ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "This script tests the native Windows Ghostty executable."
}

$checks = @(
    [pscustomobject][ordered]@{
        Id = "alt-tab"
        Action = "Press Alt+Tab, locate Ghostty, and select it."
        PassCriteria = "The test window appears with its title and icon, and selecting it focuses the terminal."
    },
    [pscustomobject][ordered]@{
        Id = "taskbar-activation"
        Action = "Use the Ghostty taskbar button to minimize, restore, and focus the test window."
        PassCriteria = "The button is present and each click produces the expected window state without a stale preview."
    },
    [pscustomobject][ordered]@{
        Id = "keyboard-snap"
        Action = "Press Win+Left, Win+Right, and then restore the test window."
        PassCriteria = "The window snaps to each side, restores correctly, and its tab bar and terminal remain usable."
    },
    [pscustomobject][ordered]@{
        Id = "snap-layout"
        Action = "Open the Windows Snap Layout UI with Win+Z or the maximize button and choose a region."
        PassCriteria = "The layout UI includes Ghostty, the selected region is applied, and the terminal content is laid out correctly."
    },
    [pscustomobject][ordered]@{
        Id = "multi-window-shell"
        Action = "Press Ctrl+Shift+N, then inspect Alt+Tab and the Ghostty taskbar group."
        PassCriteria = "Both windows are individually selectable in Alt+Tab and both taskbar previews activate the matching window."
    },
    [pscustomobject][ordered]@{
        Id = "taskbar-close"
        Action = "Close one window from its taskbar preview, confirm the other remains, then close the remaining preview."
        PassCriteria = "The first close affects only its window and the final close removes Ghostty from Alt+Tab and the taskbar."
    }
)
$selectedChecks = @(
    if ($CheckId.Count -eq 0) {
        $checks
    } else {
        $checks | Where-Object Id -in $CheckId
    }
)

if ($ListOnly) {
    $selectedChecks
    return
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($Executable)) {
    $executablePath = Join-Path $repositoryRoot "zig-out\release\bin\ghostty.exe"
} elseif ([System.IO.Path]::IsPathRooted($Executable)) {
    $executablePath = [System.IO.Path]::GetFullPath($Executable)
} else {
    $executablePath = [System.IO.Path]::GetFullPath(
        (Join-Path $repositoryRoot $Executable)
    )
}
if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "Ghostty executable not found: $executablePath"
}

$diagnosticScript = Join-Path $PSScriptRoot "run-windows-diagnostics.ps1"
if (-not (Test-Path -LiteralPath $diagnosticScript -PathType Leaf)) {
    throw "Diagnostic launcher not found: $diagnosticScript"
}

$logDirectory = Join-Path $repositoryRoot "zig-out\logs"
[System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
$sessionName = "windows-shell-{0}-{1}" -f `
    (Get-Date -Format "yyyyMMdd-HHmmss-fff"), `
    ([System.Guid]::NewGuid().ToString("N").Substring(0, 8))
if ([string]::IsNullOrWhiteSpace($ResultsPath)) {
    $resultsFile = Join-Path $logDirectory "$sessionName.json"
} elseif ([System.IO.Path]::IsPathRooted($ResultsPath)) {
    $resultsFile = [System.IO.Path]::GetFullPath($ResultsPath)
} else {
    $resultsFile = [System.IO.Path]::GetFullPath(
        (Join-Path $repositoryRoot $ResultsPath)
    )
}
[System.IO.Directory]::CreateDirectory(
    [System.IO.Path]::GetDirectoryName($resultsFile)
) | Out-Null

$testStateRoot = Join-Path $repositoryRoot "zig-out\test-state"
$sessionDirectory = Join-Path $testStateRoot $sessionName
$configPath = Join-Path $sessionDirectory "config.ghostty"
[System.IO.Directory]::CreateDirectory($sessionDirectory) | Out-Null
$config = @(
    "command = direct:cmd.exe /D /Q"
    "window-show-tab-bar = always"
    "background-opacity = 1"
    "background-blur = false"
) -join [System.Environment]::NewLine
[System.IO.File]::WriteAllText(
    $configPath,
    $config + [System.Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)

$startedAt = Get-Date
$records = [System.Collections.Generic.List[object]]::new()
$process = $null
$launch = $null
$windowHandle = [IntPtr]::Zero
$completed = $false
$forcedCleanup = $false
$runError = $null

function Write-ShellAcceptanceResult {
    param(
        [Parameter(Mandatory)]
        [bool]$Complete
    )

    $updatedAt = Get-Date
    $passed = @($records | Where-Object Status -eq "pass").Count
    $failed = @($records | Where-Object Status -eq "fail").Count
    $skipped = @($records | Where-Object Status -eq "skip").Count
    $document = [ordered]@{
        StartedAt = $startedAt.ToString("o")
        UpdatedAt = $updatedAt.ToString("o")
        Completed = $Complete
        OverallPassed = [bool](
            $Complete -and
            $records.Count -eq $selectedChecks.Count -and
            $passed -eq $selectedChecks.Count
        )
        Executable = $executablePath
        ExecutableVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo(
            $executablePath
        ).FileVersion
        ExecutableSha256 = (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash
        Environment = [ordered]@{
            MachineName = [System.Environment]::MachineName
            UserInteractive = [System.Environment]::UserInteractive
            OSVersion = [System.Environment]::OSVersion.VersionString
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        }
        ProcessId = if ($process) { $process.Id } else { $null }
        WindowHandle = $windowHandle.ToInt64()
        StdoutLog = if ($launch) { $launch.StdoutLog } else { $null }
        StderrLog = if ($launch) { $launch.StderrLog } else { $null }
        Passed = $passed
        Failed = $failed
        Skipped = $skipped
        ForcedCleanup = $forcedCleanup
        Error = $runError
        SelectedChecks = @($selectedChecks.Id)
        Results = $records
    }
    $json = $document | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText(
        $resultsFile,
        $json + [System.Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

try {
    $launch = & $diagnosticScript `
        -Executable $executablePath `
        -AdditionalArguments @(
            "--title=Ghostty-shell-acceptance-test"
            "--config-file=`"$configPath`""
            "--confirm-close-surface=false"
            "--quit-after-last-window-closed=true"
        )
    $process = Get-Process -Id $launch.ProcessId -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) {
            throw "Ghostty exited before the shell acceptance test started."
        }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            $windowHandle = $process.MainWindowHandle
            break
        }
        Start-Sleep -Milliseconds 50
    }
    if ($windowHandle -eq [IntPtr]::Zero) {
        throw "Timed out waiting for the Ghostty test window."
    }

    Write-Host "Ghostty shell acceptance test"
    Write-Host "Test window process: $($process.Id)"
    Write-Host "Answer p=pass, f=fail, s=skip, or q=cancel."

    foreach ($check in $selectedChecks) {
        Write-Host ""
        Write-Host "[$($check.Id)] $($check.Action)"
        Write-Host "Pass: $($check.PassCriteria)"
        do {
            $answer = (Read-Host "Result [p/f/s/q]").Trim().ToLowerInvariant()
        } while ($answer -notin @("p", "pass", "f", "fail", "s", "skip", "q", "quit"))

        if ($answer -in @("q", "quit")) {
            throw "Shell acceptance test canceled by the tester."
        }
        $status = switch ($answer) {
            { $_ -in @("p", "pass") } { "pass"; break }
            { $_ -in @("f", "fail") } { "fail"; break }
            default { "skip" }
        }
        $notes = if ($status -eq "fail") {
            Read-Host "Failure notes"
        } else {
            ""
        }
        $records.Add([pscustomobject][ordered]@{
            Id = $check.Id
            Status = $status
            Action = $check.Action
            PassCriteria = $check.PassCriteria
            Notes = $notes
            RecordedAt = (Get-Date).ToString("o")
        })
        Write-ShellAcceptanceResult -Complete $false
    }

    if ($records[-1].Id -eq "taskbar-close" -and
        $records[-1].Status -eq "pass") {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "Ghostty remained running after the taskbar-close check passed."
        }
    }
    $completed = $true
} catch {
    $runError = $_.Exception.Message
    throw
} finally {
    try {
        if ($process) {
            $process.Refresh()
            if (-not $process.HasExited) {
                $null = $process.CloseMainWindow()
                if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                    Stop-Process `
                        -Id $process.Id `
                        -Force `
                        -ErrorAction SilentlyContinue
                    $forcedCleanup = $true
                }
            }
        }
    } finally {
        try {
            Write-ShellAcceptanceResult -Complete $completed
        } finally {
            if (Test-Path -LiteralPath $configPath -PathType Leaf) {
                Remove-Item -LiteralPath $configPath -Force
            }
            if (Test-Path -LiteralPath $sessionDirectory -PathType Container) {
                Remove-Item -LiteralPath $sessionDirectory -Force
            }
        }
    }
}

$passed = @($records | Where-Object Status -eq "pass").Count
$failed = @($records | Where-Object Status -eq "fail").Count
$skipped = @($records | Where-Object Status -eq "skip").Count
[pscustomobject]@{
    ResultsPath = $resultsFile
    Completed = $completed
    OverallPassed = [bool]($passed -eq $selectedChecks.Count)
    Passed = $passed
    Failed = $failed
    Skipped = $skipped
    ForcedCleanup = $forcedCleanup
    StdoutLog = $launch.StdoutLog
    StderrLog = $launch.StderrLog
}
