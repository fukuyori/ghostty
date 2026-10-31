#requires -Version 7.0
<#
.SYNOPSIS
Builds a fresh parity target and binds runtime results to source evidence.
.DESCRIPTION
Requires the verified ConPTY files prepared by fetch-conpty.ps1. Uses a unique
prefix; never reuses a prior executable. Records source and dependency inputs,
Zig version, exact commands, exit codes and executable hash. Runs both cwd
inheritance modes, preserving failures rather than treating a retry as success.
Controlled keyboard messages do not establish physical input/IME acceptance.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'windows-brand.ps1')
$name = 'parity-verification-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$directory = Join-Path $root "zig-out/logs/$name"
$prefix = Join-Path $root "zig-out/$name"
$null = New-Item -ItemType Directory -Path $directory
$summaryPath = Join-Path $directory 'summary.json'
$steps = [Collections.Generic.List[object]]::new()
$summary = [ordered]@{
    Started = (Get-Date).ToString('o'); Finished = $null; Repository = $root
    Commit = $null; Branch = $null; WorkingTree = @(); ZigVersion = $null
    SourceManifest = (Join-Path $directory 'source.json'); Patch = (Join-Path $directory 'source.patch')
    Executable = $null; ExecutableHash = $null; Steps = @()
    InputsUnchanged = $false; AutomatedPassed = $false; Failure = $null
    VisualInspection = 'Pending; inspect runtime captures separately'
}
function Save-Summary {
    $summary.Steps = @($steps.ToArray())
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
}
function Read-Git([string[]]$Arguments) {
    $output = @(& git -C $root @Arguments)
    if ($LASTEXITCODE -ne 0) { throw "git failed: $($Arguments -join ' ')" }
    return $output
}
function Read-Inputs {
    $paths = @(Read-Git @('-c','core.quotepath=false','ls-files','--cached','--others','--exclude-standard'))
    $paths += @('vendor/conpty/conpty.dll','vendor/conpty/OpenConsole.exe')
    foreach ($relative in ($paths | Sort-Object -Unique)) {
        $path = Join-Path $root $relative
        [pscustomobject]@{
            Path = $relative
            Hash = if (Test-Path -LiteralPath $path -PathType Leaf) {
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            } else { $null }
        }
    }
}
function Invoke-Step([string]$Label, [string]$Command, [string[]]$Arguments) {
    $record = [pscustomobject]@{
        Name = $Label; Command = $Command; Arguments = $Arguments
        Log = (Join-Path $directory "$Label.log"); ExitCode = $null
    }
    $steps.Add($record)
    Save-Summary
    & $Command @Arguments 2>&1 | Tee-Object -FilePath $record.Log | Out-Host
    $record.ExitCode = $LASTEXITCODE
    Save-Summary
    return ($record.ExitCode -eq 0)
}
Push-Location $root
try {
    foreach ($file in @('conpty.dll','OpenConsole.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root "vendor/conpty/$file") -PathType Leaf)) {
            throw 'Prepare the verified ConPTY files with scripts/fetch-conpty.ps1 before this check.'
        }
    }
    $summary.Commit = (Read-Git @('rev-parse','HEAD')) -join ''
    $summary.Branch = (Read-Git @('branch','--show-current')) -join ''
    $summary.WorkingTree = @(Read-Git @('status','--porcelain'))
    Read-Git @('diff','HEAD','--binary') | Set-Content -LiteralPath $summary.Patch -Encoding utf8
    $inputs = @(Read-Inputs) | ConvertTo-Json -Depth 4
    $inputs | Set-Content -LiteralPath $summary.SourceManifest -Encoding utf8
    $zig = (Get-Command zig -CommandType Application | Select-Object -First 1).Source
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $summary.ZigVersion = (& $zig version) -join ''
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read Zig version.' }
    Save-Summary
    if (-not (Invoke-Step 'build' $zig @('build','--prefix',$prefix,'-Dcpu=baseline','-Demit-docs=false','--summary','all'))) {
        throw 'Fresh build failed; no runtime check was started.'
    }
    $summary.Executable = Get-GhosttyBrandExecutable -Prefix $prefix -Brand (Get-GhosttyBrand -Prefix $prefix)
    $summary.ExecutableHash = (Get-FileHash -LiteralPath $summary.Executable -Algorithm SHA256).Hash
    if (((@(Read-Inputs) | ConvertTo-Json -Depth 4) -cne $inputs) -or
        (((Read-Git @('rev-parse','HEAD')) -join '') -ne $summary.Commit) -or
        (((Read-Git @('branch','--show-current')) -join '') -ne $summary.Branch)) {
        throw 'Source or dependency inputs changed during the build.'
    }
    $arguments = @('-NoProfile','-File',(Join-Path $PSScriptRoot 'test-windows-parity.ps1'),'-Executable',$summary.Executable)
    $normalPassed = Invoke-Step 'inheritance-enabled' $pwsh $arguments
    $disabledPassed = Invoke-Step 'inheritance-disabled' $pwsh ($arguments + @('-DisableCwdInheritance'))
    $summary.InputsUnchanged = ((@(Read-Inputs) | ConvertTo-Json -Depth 4) -ceq $inputs) -and
        (((Read-Git @('rev-parse','HEAD')) -join '') -eq $summary.Commit) -and
        (((Read-Git @('branch','--show-current')) -join '') -eq $summary.Branch) -and
        ((Get-FileHash -LiteralPath $summary.Executable -Algorithm SHA256).Hash -eq $summary.ExecutableHash)
    $summary.AutomatedPassed = $normalPassed -and $disabledPassed -and $summary.InputsUnchanged
    if (-not $summary.AutomatedPassed) { throw 'Parity failed or inputs changed; see the recorded steps.' }
} catch {
    $summary.Failure = $_.Exception.Message
    throw
} finally {
    $summary.Finished = (Get-Date).ToString('o')
    Save-Summary
    Pop-Location
    Write-Host "Parity build verification: $summaryPath"
}
