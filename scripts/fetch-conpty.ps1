<#
.SYNOPSIS
Downloads the ConPTY host that Ghostty ships next to ghostty.exe.

.DESCRIPTION
Fetches the pinned Microsoft.Windows.Console.ConPTY package, checks it
against the hash recorded below, and extracts the x64 conpty.dll and
OpenConsole.exe into vendor/conpty.

The in-box ConPTY drops APC sequences, so a program running in a Ghostty pty
cannot draw images with the Kitty graphics protocol. The OpenConsole host in
this package passes them through. See vendor/conpty/README.md.

The package is not fetched through build.zig.zon because Zig's package
manager keys the archive format off the file extension and refuses .nupkg,
and Microsoft publishes the pair in no other form.

.PARAMETER Force
Re-download even when the files are already in place and match.

.EXAMPLE
./scripts/fetch-conpty.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Both files must come from the same package version: conpty.dll on its own
# silently falls back to the in-box host.
$Version = "1.24.260710001"
$PackageHash = "175640566A3B59C4B132070EE96C2C77E5AB7EDD2E92732A5EB3610BBF63D90E"

# Paths inside the package, and what we call them once extracted.
$Wanted = @(
    @{
        Entry = "runtimes/win-x64/native/conpty.dll"
        Name = "conpty.dll"
        Hash = "39FBA2713E2495117B1591AE8C32A3B904BEA7AA66069CF7815E2844C76D75D8"
    },
    @{
        Entry = "build/native/runtimes/x64/OpenConsole.exe"
        Name = "OpenConsole.exe"
        Hash = "B7FD936C2668B87B9ECF7B3366DC6568AFC1C6F981874CBA3E955A1C35CF8160"
    }
)

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$destination = Join-Path $repositoryRoot "vendor\conpty"
[System.IO.Directory]::CreateDirectory($destination) | Out-Null

function Test-Extracted {
    foreach ($file in $Wanted) {
        $path = Join-Path $destination $file.Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.Hash) { return $false }
    }
    return $true
}

if (-not $Force -and (Test-Extracted)) {
    Write-Host "ConPTY $Version is already in vendor\conpty."
    return
}

$url = "https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/" +
    "$Version/microsoft.windows.console.conpty.$Version.nupkg"

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("ghostty-conpty-" + [System.Guid]::NewGuid().ToString("N"))
[System.IO.Directory]::CreateDirectory($staging) | Out-Null
try {
    $package = Join-Path $staging "conpty.nupkg"
    Write-Host "Downloading ConPTY $Version..."
    Invoke-WebRequest -Uri $url -OutFile $package -UseBasicParsing

    $actual = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    if ($actual -ne $PackageHash) {
        throw "ConPTY package hash mismatch.`n  expected $PackageHash`n  actual   $actual"
    }

    # A .nupkg is a zip. Read the entries directly so the other several
    # megabytes of the package never hit the disk.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($package)
    try {
        foreach ($file in $Wanted) {
            $entry = $archive.Entries | Where-Object { $_.FullName -eq $file.Entry }
            if (-not $entry) { throw "ConPTY package has no $($file.Entry)." }
            $path = Join-Path $destination $file.Name
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $true)

            $extracted = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            if ($extracted -ne $file.Hash) {
                throw "$($file.Name) hash mismatch.`n  expected $($file.Hash)`n  actual   $extracted"
            }
            Write-Host "  $($file.Name)"
        }
    } finally {
        $archive.Dispose()
    }
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "ConPTY $Version is in vendor\conpty."
