<#
.SYNOPSIS
Builds a portable Windows release of Ghostty.

.DESCRIPTION
Runs the default Zig build in ReleaseFast mode for the baseline CPU and
installs the result into zig-out/release by default. This script does not
create a distribution archive or installer.

.PARAMETER OutputDirectory
The install prefix for the release build. Relative paths are resolved from the
repository root.

.PARAMETER AdditionalZigArgs
Additional arguments passed to `zig build`.

.EXAMPLE
./scripts/build-release.ps1

.EXAMPLE
./scripts/build-release.ps1 -OutputDirectory zig-out/release-local
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = "",
    [string[]]$AdditionalZigArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "This script builds the native Windows Ghostty executable."
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot "build.zig") -PathType Leaf)) {
    throw "Unable to locate the Ghostty repository root."
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $releaseRoot = Join-Path $repositoryRoot "zig-out\release"
} elseif ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $releaseRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
} else {
    $releaseRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $OutputDirectory))
}

$zig = Get-Command zig -CommandType Application -ErrorAction Stop
$zigVersion = & $zig.Path version
if ($LASTEXITCODE -ne 0) {
    throw "Failed to query the Zig version."
}

$buildArguments = @(
    "build"
    "--prefix"
    $releaseRoot
    "-Doptimize=ReleaseFast"
    "-Dcpu=baseline"
    "-Demit-docs=false"
    "--summary"
    "all"
) + $AdditionalZigArgs

Write-Host "Building Ghostty release with Zig $zigVersion"
Write-Host "Output: $releaseRoot"

Push-Location $repositoryRoot
try {
    & $zig.Path @buildArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Ghostty release build failed with exit code $LASTEXITCODE."
    }
} finally {
    Pop-Location
}

$executable = Join-Path $releaseRoot "bin\ghostty.exe"
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "The build completed without producing $executable."
}

$resources = Join-Path $releaseRoot "share\ghostty"
if (-not (Test-Path -LiteralPath $resources -PathType Container)) {
    throw "The build completed without producing $resources."
}

$header = [byte[]]::new(2)
$stream = [System.IO.File]::OpenRead($executable)
try {
    $headerLength = $stream.Read($header, 0, $header.Length)
} finally {
    $stream.Dispose()
}

if ($headerLength -ne 2 -or $header[0] -ne 0x4D -or $header[1] -ne 0x5A) {
    throw "The generated executable does not have a valid PE header."
}

$file = Get-Item -LiteralPath $executable
$hash = Get-FileHash -LiteralPath $executable -Algorithm SHA256

[pscustomobject]@{
    Executable   = $file.FullName
    Resources    = $resources
    Optimization = "ReleaseFast"
    Cpu          = "baseline"
    SizeBytes    = $file.Length
    Sha256       = $hash.Hash
}
