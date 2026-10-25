#requires -Version 7.0
<#
.SYNOPSIS
Builds and tests both IME variants with source and executable evidence.
.DESCRIPTION
Records HEAD, the working-tree patch, hashes of changed files, exact commands,
exit codes and executable hashes in a timestamped directory. GUI checks run
sequentially. Physical Japanese IME acceptance remains a separate manual run
of test-windows-ime.ps1; this script does not claim visual acceptance.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'windows-brand.ps1')
$directory = Join-Path $root ('zig-out/logs/ime-verification-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$null = New-Item -ItemType Directory -Path $directory -Force
$summaryPath = Join-Path $directory 'summary.json'
$steps = [Collections.Generic.List[object]]::new()
$summary = [ordered]@{
    Started = (Get-Date).ToString('o'); Commit = $null; WorkingTree = @()
    WorkingTreePatch = (Join-Path $directory 'working-tree.patch')
    ChangedFileHashes = @(); Steps = @(); Executables = @()
    AutomatedPassed = $false; PhysicalAcceptance = 'Separate owner-operated check'
    Failure = $null
}
function Save-Summary {
    $summary.Steps = @($steps.ToArray())
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
}
function Invoke-Check([string]$Label, [string]$Command, [string[]]$Arguments) {
    $record = [pscustomobject]@{
        Name = $Label; Command = $Command; Arguments = $Arguments
        Started = (Get-Date).ToString('o'); Finished = $null
        ExitCode = $null; Passed = $false; Log = (Join-Path $directory "$Label.log")
    }
    $steps.Add($record)
    Save-Summary
    & $Command @Arguments 2>&1 | Tee-Object -FilePath $record.Log | Out-Host
    $record.ExitCode = $LASTEXITCODE
    $record.Finished = (Get-Date).ToString('o')
    $record.Passed = $record.ExitCode -eq 0
    Save-Summary
    if (-not $record.Passed) { throw "$Label failed (exit $($record.ExitCode)); see $($record.Log)" }
}
Push-Location $root
try {
    $summary.Commit = (& git rev-parse HEAD)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify HEAD.' }
    $summary.WorkingTree = @(& git status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify working-tree changes.' }
    & git diff HEAD --binary | Set-Content -LiteralPath $summary.WorkingTreePatch -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'Cannot record working-tree patch.' }
    $changed = @(& git diff HEAD --name-only) + @(& git ls-files --others --exclude-standard)
    $summary.ChangedFileHashes = @($changed | Sort-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        ForEach-Object { Get-FileHash -LiteralPath $_ | Select-Object Path,Hash })
    $zig = (Get-Command zig -CommandType Application).Source
    $pwsh = (Get-Command pwsh -CommandType Application).Source
    Invoke-Check 'normal-build' $zig @('build','--prefix','zig-out/ime-normal','--summary','all')
    Invoke-Check 'hook-build' $zig @('build','-Dwin32-test-hooks=true','--prefix','zig-out/ime-diagnostics','--summary','all')
    Invoke-Check 'normal-tests' $zig @('build','test','-Dtest-filter=Win32','--summary','all')
    Invoke-Check 'hook-tests' $zig @('build','test','-Dtest-filter=Win32','-Dwin32-test-hooks=true','--summary','all')
    $normalPrefix = Join-Path $root 'zig-out/ime-normal'
    $hookPrefix = Join-Path $root 'zig-out/ime-diagnostics'
    $normal = Get-GhosttyBrandExecutable -Prefix $normalPrefix -Brand (Get-GhosttyBrand -Prefix $normalPrefix)
    $hook = Get-GhosttyBrandExecutable -Prefix $hookPrefix -Brand (Get-GhosttyBrand -Prefix $hookPrefix)
    $summary.Executables = @(Get-FileHash -LiteralPath $normal,$hook | Select-Object Path,Hash)
    Invoke-Check 'position' $pwsh @('-NoProfile','-File',(Join-Path $PSScriptRoot 'test-windows-ime-position.ps1'),'-Executable',$hook)
    Invoke-Check 'normal-window' $pwsh @('-NoProfile','-File',(Join-Path $PSScriptRoot 'test-windows-window-state.ps1'),'-Executable',$normal)
    Invoke-Check 'hook-window' $pwsh @('-NoProfile','-File',(Join-Path $PSScriptRoot 'test-windows-window-state.ps1'),'-Executable',$hook)
    foreach ($expected in $summary.Executables) {
        if ((Get-FileHash -LiteralPath $expected.Path).Hash -ne $expected.Hash) { throw 'Executable changed during verification.' }
    }
    foreach ($expected in $summary.ChangedFileHashes) {
        if ((Get-FileHash -LiteralPath $expected.Path).Hash -ne $expected.Hash) { throw "Source changed during verification: $($expected.Path)" }
    }
    if ((& git rev-parse HEAD) -ne $summary.Commit) { throw 'HEAD changed during verification.' }
    $summary.AutomatedPassed = $true
} catch {
    $summary.Failure = $_.Exception.Message
    throw
} finally {
    $summary['Finished'] = (Get-Date).ToString('o')
    Save-Summary
    Pop-Location
    Write-Host "IME verification summary: $summaryPath"
}
