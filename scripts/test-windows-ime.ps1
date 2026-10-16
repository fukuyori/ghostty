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
$process.WaitForExit()
$result = [ordered]@{
    Pid = $process.Id
    Executable = $exe
    Sha256 = $hash
    ExitCode = $process.ExitCode
    TracePresent = [bool](Select-String -LiteralPath $stderr -SimpleMatch 'win32_ime_trace' -Quiet)
    CrashOrLeak = [bool](Select-String -LiteralPath $stderr -Pattern 'Segmentation fault|panic:|leaked:' -Quiet)
    EvidenceDirectory = $directory
}
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'session.json') -Encoding utf8
$result
