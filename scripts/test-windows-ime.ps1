<#
.SYNOPSIS
Records an owner-operated Japanese IME partial-commit reproduction (#48).
.DESCRIPTION
Build first with: zig build -Dwin32-test-hooks=true --prefix zig-out/ime-diagnostics
Opens a dedicated key recorder; typed text is never executed as a command.
IME tracing records message flags, lengths and coordinates, not text. The
dedicated probe records completed lines and their UTF-8 bytes for comparison.
Compose niwanihaniwa, convert, commit only the leading segment, pause to
inspect the remaining composition, then commit it and press Enter. F10 quits.
This is diagnostic collection, not an automated acceptance test.
For focus-resume coverage, also switch to another app while composing,
return and partially commit; record whether the IME kept, committed or
cancelled the composition. Check output-heavy/TUI and resize/DPI scenarios
separately; a successful basic partial commit does not establish those cases.
#>
[CmdletBinding()]
param(
    [string]$Executable = 'zig-out/ime-diagnostics/bin/ghostty.exe',
    [switch]$Probe,
    [string]$RecordPath
)

$ErrorActionPreference = 'Stop'
if ($Probe) {
    if (-not $RecordPath) { throw '-RecordPath is required with -Probe.' }
    $selfProcess = [Diagnostics.Process]::GetCurrentProcess()
    [ordered]@{ Pid = $PID; StartTimeUtc = $selfProcess.StartTime.ToUniversalTime().ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath "$RecordPath.process.json.tmp" -Encoding utf8
    Move-Item -LiteralPath "$RecordPath.process.json.tmp" -Destination "$RecordPath.process.json"
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::TreatControlCAsInput = $true
    [Console]::Write(([char]27).ToString() + ']2;IME partial commit check' + [char]7)
    [Console]::WriteLine('IME partial commit check (#48) - no commands are executed')
    [Console]::WriteLine('Compose niwanihaniwa. Convert and commit only the leading segment.')
    [Console]::WriteLine('Pause to inspect the overlap; then commit the rest and press Enter.')
    [Console]::WriteLine('F10 closes this test window.')
    $line = [Text.StringBuilder]::new()
    [Console]::Write('input> ')
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) {
            $text = $line.ToString()
            [ordered]@{
                Time = [DateTimeOffset]::Now.ToString('o')
                Text = $text
                Utf8Hex = [Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($text))
            } | ConvertTo-Json -Compress | Add-Content -LiteralPath $RecordPath -Encoding utf8
            [Console]::WriteLine()
            [Console]::WriteLine('Recorded: ' + $text)
            $null = $line.Clear()
            [Console]::Write('input> ')
        } elseif ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($line.Length -gt 0) {
                $null = $line.Remove($line.Length - 1, 1)
                [Console]::Write("`b `b")
            }
        } elseif ([int]$key.KeyChar -ge 0x20) {
            $null = $line.Append($key.KeyChar)
            [Console]::Write($key.KeyChar)
        }
    }
}

$root = Split-Path $PSScriptRoot -Parent
$exe = if ([IO.Path]::IsPathRooted($Executable)) { $Executable } else { Join-Path $root $Executable }
$exe = (Resolve-Path -LiteralPath $exe).Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$directory = Join-Path $root "zig-out/test-fixtures/ime-$stamp"
$null = New-Item -ItemType Directory -Path $directory -Force
$record = Join-Path $directory 'lines.jsonl'
$probeCommand = "& '$($PSCommandPath.Replace("'", "''"))' -Probe -RecordPath '$($record.Replace("'", "''"))'"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeCommand))
$config = Join-Path $directory 'config'
@"
command = pwsh.exe -NoLogo -NoProfile -EncodedCommand $encoded
shell-integration = none
confirm-close-surface = false
quit-after-last-window-closed = true
window-width = 100
window-height = 24
keybind = f10=quit
"@ | Set-Content -LiteralPath $config -Encoding utf8
$stderr = Join-Path $directory 'stderr.log'
$stdout = Join-Path $directory 'stdout.log'
$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
$previousTrace = $env:GHOSTTY_TEST_IME_TRACE
try {
    $env:GHOSTTY_TEST_IME_TRACE = '1'
    # This window is intentionally visible for physical IME input and inspection.
    $process = Start-Process -FilePath $exe -WorkingDirectory $root -ArgumentList @(
        '--config-default-files=false', "--config-file=`"$config`""
    ) -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
} finally {
    $env:GHOSTTY_TEST_IME_TRACE = $previousTrace
}
Write-Host "IME check PID $($process.Id), evidence: $directory"
$null = $process.Handle
$probeProcess = $null
$observeWatch = [Diagnostics.Stopwatch]::StartNew()
while (-not $process.HasExited -and $observeWatch.Elapsed.TotalSeconds -lt 10) {
    if (Test-Path -LiteralPath "$record.process.json") {
        $childRecord = Get-Content -LiteralPath "$record.process.json" -Raw | ConvertFrom-Json
        $candidate = Get-Process -Id $childRecord.Pid -ErrorAction SilentlyContinue
        if ($candidate -and $candidate.StartTime.ToUniversalTime().Ticks -eq ([DateTime]$childRecord.StartTimeUtc).ToUniversalTime().Ticks) {
            $null = $candidate.Handle
            $probeProcess = $candidate
            break
        }
    }
    Start-Sleep -Milliseconds 50
}
$process.WaitForExit()
if ($probeProcess -and -not $probeProcess.HasExited) { $null = $probeProcess.WaitForExit(5000) }
$result = [ordered]@{
    Pid = $process.Id
    Executable = $exe
    Sha256 = $hash
    ExitCode = $process.ExitCode
    Commit = (& git -C $root rev-parse HEAD)
    Command = $PSCommandPath
    Arguments = @{ Executable = $Executable }
    TraceEnvironment = 'GHOSTTY_TEST_IME_TRACE=1'
    MainProcessExited = $process.HasExited
    ObservedProbePid = if ($probeProcess) { $probeProcess.Id } else { $null }
    ProbeExited = if ($probeProcess) { $probeProcess.HasExited } else { $null }
    RemainingObservedProcessIds = @(@($process, $probeProcess) | Where-Object { $_ -and -not $_.HasExited } | ForEach-Object { $_.Id })
    TracePresent = [bool](Select-String -LiteralPath $stderr -SimpleMatch 'win32_ime_trace' -Quiet)
    CrashOrLeak = [bool](Select-String -LiteralPath $stderr -Pattern 'Segmentation fault|panic:|leaked:' -Quiet)
    EvidenceDirectory = $directory
}
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'session.json') -Encoding utf8
$result
