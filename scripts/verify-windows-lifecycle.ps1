#requires -Version 7.0
<#
.SYNOPSIS
Builds both lifecycle variants and collects automated desktop acceptance.
.DESCRIPTION
Run from an ordinary interactive PowerShell window. Builds use separate
output trees, then check that ordinary builds ignore test controls and run
all lifecycle cases with representative screenshots. Stops on a failed step
and preserves its exit code and log in a timestamped JSON summary.
Image inspection remains a separate human check even when every step passes.
.EXAMPLE
./scripts/verify-windows-lifecycle.ps1
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Native exit codes are collected explicitly, including a failed build.
$PSNativeCommandUseErrorActionPreference = $false
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'windows-brand.ps1')
$logs = Join-Path $root 'zig-out/logs'
$null = New-Item -ItemType Directory -Force -Path $logs
$name = 'lifecycle-acceptance-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$summaryPath = Join-Path $logs "$name.json"
$steps = [Collections.Generic.List[object]]::new()
$summary = [ordered]@{
    Started = (Get-Date).ToString('o')
    Commit = $null
    WorkingTree = @()
    Steps = @()
    Executables = @()
    Screenshots = @()
    AutomatedPassed = $false
    VisualInspection = 'Pending'
    Failure = $null
}
function Save-Summary {
    $summary.Steps = @($steps.ToArray())
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
}
function Invoke-Check([string]$Label, [string]$Command, [string[]]$Arguments) {
    $log = Join-Path $logs "$name-$Label.log"
    $step = [ordered]@{ Name=$Label; ExitCode=$null; Passed=$false; Log=$log }
    $steps.Add([pscustomobject]$step)
    $record = $steps[$steps.Count - 1]
    Save-Summary
    & $Command @Arguments 2>&1 | Tee-Object -FilePath $log | Out-Host
    $record.ExitCode = $LASTEXITCODE
    $record.Passed = $record.ExitCode -eq 0
    Save-Summary
    if (-not $record.Passed) { throw "$Label failed (exit $($record.ExitCode)); see $log" }
}
$previousCache = [Environment]::GetEnvironmentVariable('ZIG_GLOBAL_CACHE_DIR', 'Process')
Push-Location $root
try {
    if (-not (Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        throw 'This PowerShell lacks Start-Process -Environment; use a PowerShell version that supports it'
    }
    $zig = (Get-Command zig -CommandType Application).Source
    $pwsh = (Get-Command pwsh -CommandType Application).Source
    $summary.Commit = (& git rev-parse HEAD)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to identify repository HEAD' }
    $summary.WorkingTree = @(& git status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to identify working-tree changes' }
    $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $root '.zig-cache/global'

    Invoke-Check 'normal-build' $zig @('build','--prefix','zig-out/lifecycle-normal','--summary','all')
    Invoke-Check 'hook-build' $zig @('build','-Dwin32-test-hooks=true','--prefix','zig-out/lifecycle-hooks','--summary','all')
    $normalPrefix = Join-Path $root 'zig-out/lifecycle-normal'
    $hookPrefix = Join-Path $root 'zig-out/lifecycle-hooks'
    $normal = Get-GhosttyBrandExecutable -Prefix $normalPrefix -Brand (Get-GhosttyBrand -Prefix $normalPrefix)
    $hook = Get-GhosttyBrandExecutable -Prefix $hookPrefix -Brand (Get-GhosttyBrand -Prefix $hookPrefix)
    $summary.Executables = @(Get-FileHash -LiteralPath $normal,$hook | Select-Object Path,Hash)

    $script = Join-Path $PSScriptRoot 'test-windows-lifecycle.ps1'
    $disabledJson = Join-Path $logs "$name-hooks-disabled.json"
    $summary['HooksDisabledResult'] = $disabledJson
    Invoke-Check 'hooks-disabled' $pwsh @('-NoLogo','-NoProfile','-File',$script,'-Executable',$normal,'-Area','HooksDisabled','-SummaryPath',$disabledJson)
    $casesJson = Join-Path $logs "$name-cases.json"
    $summary['LifecycleResult'] = $casesJson
    Invoke-Check 'lifecycle-cases' $pwsh @('-NoLogo','-NoProfile','-File',$script,'-Executable',$hook,'-CaptureWindows','-SummaryPath',$casesJson)
    $cases = Get-Content -LiteralPath $casesJson -Raw | ConvertFrom-Json
    if ($cases.Results.Count -ne 37 -or @($cases.Results | Where-Object { -not $_.Passed }).Count -or $cases.Leftovers.Count) {
        throw 'Lifecycle summary does not contain 37 passing cases with empty leftovers'
    }
    $summary.Screenshots = @($cases.Results | Where-Object { $_.PSObject.Properties.Name -contains 'Screenshot' } | ForEach-Object { $_.Screenshot })
    if ($summary.Screenshots.Count -ne 4) { throw 'Expected four representative captures' }
    foreach ($capture in $summary.Screenshots) {
        if (-not (Test-Path -LiteralPath $capture -PathType Leaf)) { throw "Capture is missing: $capture" }
    }
    $summary.AutomatedPassed = $true
} catch {
    $summary.Failure = $_.Exception.Message
    throw
} finally {
    [Environment]::SetEnvironmentVariable('ZIG_GLOBAL_CACHE_DIR', $previousCache, 'Process')
    Pop-Location
    $summary['Finished'] = (Get-Date).ToString('o')
    Save-Summary
    Write-Host "Acceptance summary: $summaryPath"
}
Write-Host 'Automated checks passed. Inspect the four images; VisualInspection remains Pending.'
