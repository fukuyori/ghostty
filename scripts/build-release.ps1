<#
.SYNOPSIS
Builds a portable Windows release of Ghostty.

.DESCRIPTION
Runs the default Zig build in ReleaseFast mode for the baseline CPU and
installs the result into zig-out/release by default. It validates the PE
format, Windows GUI subsystem, version information, required resource
directories, and output hash. This script does not create a distribution
archive or installer.

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

$shellIntegration = Join-Path $resources "shell-integration"
$themes = Join-Path $resources "themes"
foreach ($requiredDirectory in @($shellIntegration, $themes)) {
    if (-not (Test-Path -LiteralPath $requiredDirectory -PathType Container)) {
        throw "The release is missing required resources: $requiredDirectory"
    }
}

$shellIntegrationFileCount = @(
    Get-ChildItem -LiteralPath $shellIntegration -File -Recurse
).Count
$themeFileCount = @(
    Get-ChildItem -LiteralPath $themes -File -Recurse
).Count
if ($shellIntegrationFileCount -eq 0 -or $themeFileCount -eq 0) {
    throw "The release contains an empty required resource directory."
}

$stream = [System.IO.File]::OpenRead($executable)
$reader = [System.IO.BinaryReader]::new($stream)
try {
    if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) {
        throw "The generated executable does not have a valid DOS header."
    }

    $stream.Position = 0x3C
    $peOffset = $reader.ReadInt32()
    if ($peOffset -lt 0 -or $peOffset + 92 -gt $stream.Length) {
        throw "The generated executable has an invalid PE header offset."
    }

    $stream.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x00004550) {
        throw "The generated executable does not have a valid PE signature."
    }

    $machineValue = $reader.ReadUInt16()
    $machine = switch ($machineValue) {
        0x014C { "x86" }
        0x8664 { "x64" }
        0xAA64 { "arm64" }
        default { throw "Unsupported PE machine type: 0x{0:X4}" -f $machineValue }
    }

    $optionalHeaderOffset = $peOffset + 24
    $stream.Position = $optionalHeaderOffset
    $optionalHeaderMagic = $reader.ReadUInt16()
    $peFormat = switch ($optionalHeaderMagic) {
        0x010B { "PE32" }
        0x020B { "PE32+" }
        default { throw "Unsupported PE optional header: 0x{0:X4}" -f $optionalHeaderMagic }
    }

    $stream.Position = $optionalHeaderOffset + 68
    $subsystemValue = $reader.ReadUInt16()
    if ($subsystemValue -ne 2) {
        throw "The generated executable is not a Windows GUI application (subsystem $subsystemValue)."
    }
} finally {
    $reader.Dispose()
    $stream.Dispose()
}

$file = Get-Item -LiteralPath $executable
$hash = Get-FileHash -LiteralPath $executable -Algorithm SHA256
$versionInfo = $file.VersionInfo

if ([string]::IsNullOrWhiteSpace($versionInfo.FileVersion)) {
    throw "The release executable does not contain FileVersion information."
}
if ([string]::IsNullOrWhiteSpace($versionInfo.ProductVersion)) {
    throw "The release executable does not contain ProductVersion information."
}
if ($versionInfo.FileVersion -ne $versionInfo.ProductVersion) {
    throw "FileVersion and ProductVersion do not match."
}
if ($versionInfo.IsDebug) {
    throw "The release executable is marked as a debug build."
}

$versionOutput = & $executable --version 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "The release executable failed to report its version."
}
$versionLine = @(
    $versionOutput -split "`r?`n" | Where-Object { $_ -match '^Ghostty\s+\S+' }
) | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($versionLine)) {
    throw "The release executable returned an unrecognized version string."
}
$cliVersion = ($versionLine -replace '^Ghostty\s+', '').Trim()
if ($cliVersion -ne $versionInfo.FileVersion) {
    throw "The CLI version does not match the Windows FileVersion."
}

[pscustomobject]@{
    Executable   = $file.FullName
    Resources    = $resources
    Optimization = "ReleaseFast"
    Cpu          = "baseline"
    PEFormat     = $peFormat
    Machine      = $machine
    Subsystem    = "WindowsGui"
    Version      = $cliVersion
    FileVersion  = $versionInfo.FileVersion
    ProductVersion = $versionInfo.ProductVersion
    Debug         = $versionInfo.IsDebug
    ShellFiles   = $shellIntegrationFileCount
    ThemeFiles   = $themeFileCount
    SizeBytes    = $file.Length
    Sha256       = $hash.Hash
}
