<#
.SYNOPSIS
Checks native IME placement following asynchronous terminal output (#48).
.DESCRIPTION
Requires a build with -Dwin32-test-hooks=true. Uses synthetic composition
messages and delayed output from a dedicated probe, then reads opt-in IMM
diagnostics. This does not replace physical Japanese IME acceptance.
#>
[CmdletBinding()]
param(
    [string]$Executable = 'zig-out/ime-diagnostics/bin/ghostty.exe',
    [switch]$Probe,
    [string]$Directory
)
$ErrorActionPreference = 'Stop'
if ($Probe) {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $escape = [string][char]27
    [Console]::Write("${escape}[2J${escape}[5;8H")
    Set-Content -LiteralPath (Join-Path $Directory 'ready') -Value 'ready'
    $last = 0
    while ($true) {
        $command = Join-Path $Directory 'command'
        if (Test-Path -LiteralPath $command) {
            $value = (Get-Content -LiteralPath $command -Raw).Trim()
            if ($value -match '^\d+$' -and [int]$value -gt $last) {
                $last = [int]$value
                # Output arrives well after the synchronous IME notification.
                Start-Sleep -Milliseconds 200
                $row = 5 + $last
                $column = 8 + 3 * $last
                [Console]::Write("${escape}[$row;${column}H")
                Set-Content -LiteralPath (Join-Path $Directory "ack-$last") -Value $last
            }
        }
        Start-Sleep -Milliseconds 20
    }
}

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class GhosttyImePositionNative {
    private delegate bool EnumProc(IntPtr hwnd, IntPtr param);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr param);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassNameW(IntPtr hwnd, StringBuilder name, int capacity);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint msg, UIntPtr wp, IntPtr lp, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint msg, UIntPtr wp, IntPtr lp);
    public static bool IsTerminal(IntPtr hwnd) {
        var name = new StringBuilder(256);
        GetClassNameW(hwnd, name, name.Capacity);
        return name.ToString() == "GhosttyWindow";
    }
    public static IntPtr Find(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hwnd, param) => {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            if (owner == pid && IsTerminal(hwnd)) { found = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

function Wait-Check([scriptblock]$Condition, [string]$Description) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 10) {
        if (& $Condition) { return }
        if ($process.HasExited) { throw "Test process exited during: $Description" }
        Start-Sleep -Milliseconds 30
    }
    throw "Timed out: $Description"
}
function Send-Check([uint32]$Message, [uint64]$WParam = 0, [long]$LParam = 0) {
    $reply = [UIntPtr]::Zero
    if ([GhosttyImePositionNative]::SendMessageTimeoutW($script:surface, $Message,
        [UIntPtr]$WParam, [IntPtr]$LParam, 2, 2000, [ref]$reply) -eq [IntPtr]::Zero) {
        throw "SendMessageTimeout failed: $Message"
    }
}
function Read-Snapshot {
    $script:queryId++
    Send-Check 1137 $script:queryId # WM_USER + 113, opt-in diagnostic query
    $id = $script:queryId.ToString('x')
    $line = @(Get-Content -LiteralPath $stderr | Where-Object { $_ -match "event=query flags=0x$id " }) | Select-Object -Last 1
    if ($line -match 'cursor=(\d+),(\d+) point=(\d+),(\d+) form_valid=(true|false) style=0x(\w+) form=(-?\d+),(-?\d+).* tracking=(true|false)') {
        return [pscustomobject]@{
            Column = [int]$Matches[1]; Row = [int]$Matches[2]
            X = [int]$Matches[3]; Y = [int]$Matches[4]
            Valid = $Matches[5] -eq 'true'; Style = $Matches[6]
            FormX = [int]$Matches[7]; FormY = [int]$Matches[8]
            Tracking = $Matches[9] -eq 'true'
        }
    }
    return $null
}
function Move-Probe([int]$Sequence) {
    Set-Content -LiteralPath (Join-Path $directory 'command') -Value $Sequence
    Wait-Check { Test-Path -LiteralPath (Join-Path $directory "ack-$Sequence") } "probe output $Sequence"
    Wait-Check {
        $script:snapshot = Read-Snapshot
        $script:snapshot -and $script:snapshot.Column -eq (7 + 3 * $Sequence) -and $script:snapshot.Row -eq (4 + $Sequence)
    } "terminal cursor $Sequence"
}
function Assert-Aligned {
    Wait-Check {
        $script:snapshot = Read-Snapshot
        $script:snapshot -and $script:snapshot.Tracking -and $script:snapshot.Valid -and
            $script:snapshot.Style -eq '2' -and $script:snapshot.X -eq $script:snapshot.FormX -and
            $script:snapshot.Y -eq $script:snapshot.FormY
    } 'IME form follows terminal cursor'
}

$root = Split-Path $PSScriptRoot -Parent
$exe = if ([IO.Path]::IsPathRooted($Executable)) { $Executable } else { Join-Path $root $Executable }
$exe = (Resolve-Path -LiteralPath $exe).Path
$directory = Join-Path $root ('zig-out/test-fixtures/ime-position-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$null = New-Item -ItemType Directory -Path $directory -Force
$probeCommand = "& '$($PSCommandPath.Replace("'", "''"))' -Probe -Directory '$($directory.Replace("'", "''"))'"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeCommand))
$config = Join-Path $directory 'config'
@"
command = pwsh.exe -NoLogo -NoProfile -EncodedCommand $encoded
shell-integration = none
confirm-close-surface = false
quit-after-last-window-closed = true
window-width = 100
window-height = 24
"@ | Set-Content -LiteralPath $config -Encoding utf8
$stderr = Join-Path $directory 'stderr.log'
$stdout = Join-Path $directory 'stdout.log'
$previousTrace = $env:GHOSTTY_TEST_IME_TRACE
$process = $null
$failure = $null
$checks = [Collections.Generic.List[string]]::new()
$script:queryId = 0
try {
    try {
        $env:GHOSTTY_TEST_IME_TRACE = '1'
        $process = Start-Process -FilePath $exe -WorkingDirectory $root -ArgumentList @(
            '--config-default-files=false', "--config-file=`"$config`""
        ) -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    } finally { $env:GHOSTTY_TEST_IME_TRACE = $previousTrace }
    Wait-Check {
        $script:parent = [GhosttyImePositionNative]::Find($process.Id)
        $script:parent -ne [IntPtr]::Zero
    } 'test window'
    $script:surface = [GhosttyImePositionNative]::GetWindow($script:parent, 5)
    while ($script:surface -ne [IntPtr]::Zero -and -not [GhosttyImePositionNative]::IsTerminal($script:surface)) {
        $script:surface = [GhosttyImePositionNative]::GetWindow($script:surface, 2)
    }
    if ($script:surface -eq [IntPtr]::Zero) { throw 'Terminal child not found.' }
    Wait-Check { Test-Path -LiteralPath (Join-Path $directory 'ready') } 'probe ready'
    Send-Check 269 # WM_IME_STARTCOMPOSITION
    Assert-Aligned
    $checks.Add('Initial composition placement')
    Move-Probe 1
    Assert-Aligned
    Move-Probe 2
    Assert-Aligned
    $checks.Add('Two delayed PTY cursor moves during one composition')

    $lastFormX = $script:snapshot.FormX
    $lastFormY = $script:snapshot.FormY
    Send-Check 270 # WM_IME_ENDCOMPOSITION
    Move-Probe 3
    Send-Check 275 4803910 # queued WM_TIMER for the stopped position timer (0x494D46)
    $script:snapshot = Read-Snapshot
    if ($script:snapshot.Tracking -or $script:snapshot.FormX -ne $lastFormX -or $script:snapshot.FormY -ne $lastFormY) {
        throw 'Composition end did not stop tracking.'
    }
    $checks.Add('End and stale timer leave the composition position unchanged')

    Send-Check 269
    Assert-Aligned
    $checks.Add('New composition resets placement')
    $lastFormX = $script:snapshot.FormX
    $lastFormY = $script:snapshot.FormY
    Send-Check 8 # WM_KILLFOCUS
    Move-Probe 4
    Send-Check 275 4803910
    $script:snapshot = Read-Snapshot
    if ($script:snapshot.Tracking -or $script:snapshot.FormX -ne $lastFormX -or $script:snapshot.FormY -ne $lastFormY) {
        throw 'Focus loss did not stop tracking.'
    }
    $checks.Add('Focus loss and stale timer stop tracking')
    Send-Check 269
    Assert-Aligned
    $checks.Add('Close with active composition')
} catch { $failure = $_.ToString() }
finally {
    if ($process -and -not $process.HasExited) {
        $window = [GhosttyImePositionNative]::Find($process.Id)
        if ($window -ne [IntPtr]::Zero) {
            $null = [GhosttyImePositionNative]::PostMessageW($window, 16, [UIntPtr]::Zero, [IntPtr]::Zero)
        }
        if (-not $process.WaitForExit(10000)) {
            $failure = "$failure Test process did not close; PID $($process.Id) was left running."
        }
    }
}
$result = [ordered]@{
    Executable = $exe; Sha256 = (Get-FileHash -LiteralPath $exe).Hash
    Pid = if ($process) { $process.Id } else { $null }
    ExitCode = if ($process -and $process.HasExited) { $process.ExitCode } else { $null }
    Checks = @($checks.ToArray()); Failure = $failure
    CrashOrLeak = if (Test-Path -LiteralPath $stderr) {
        [bool](Select-String -LiteralPath $stderr -Pattern 'Segmentation fault|panic:|leaked:' -Quiet)
    } else { $false }
    EvidenceDirectory = $directory
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
$result
if ($failure -or $result.ExitCode -ne 0 -or $result.CrashOrLeak) { throw "IME position regression failed. See $directory" }
