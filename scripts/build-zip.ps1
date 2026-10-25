<#
.SYNOPSIS
Builds the portable Windows ZIP archive.

.DESCRIPTION
Stages the release tree produced by scripts/build-release.ps1 under a top
folder named like the archive, adds LICENSE and THIRD-PARTY-NOTICES.md,
optionally signs the staged executable, and compresses the folder. The
release tree itself is never modified. The version must match
dist/windows/version.txt, as for the installer.

.PARAMETER ReleaseDirectory
The release prefix that contains the executable in bin\ and share\. Relative
paths are resolved from the repository root. The default is zig-out\release.

.PARAMETER OutputDirectory
Directory that receives the archive and the staged files. The default is
zig-out\zip.

.PARAMETER OutputBaseName
Archive file name without the extension, also used for the top folder in the
archive. The default is <exe>-<version>-x64-portable, with the executable name
from brand.json and the version read from the release executable.

.PARAMETER Sign
Sign the staged executable with Authenticode before compressing it. By
default the certificate is selected by subject name from the CODESIGN_CERT
environment variable (signtool /n), as in scripts/build-installer.ps1.
CertificateSubject, CertificateThumbprint, or PfxPath override it.

.PARAMETER CertificateSubject
Subject name (or a substring of it) of a code-signing certificate in the
certificate store, passed to signtool /n. Defaults to CODESIGN_CERT.

.PARAMETER CertificateThumbprint
SHA-1 thumbprint of a code-signing certificate, passed to signtool /sha1.

.PARAMETER PfxPath
Path to a PFX file containing the signing certificate and private key.

.PARAMETER PfxPassword
Password for PfxPath. It appears on the signtool command line.

.PARAMETER TimestampUrl
RFC 3161 timestamp server. The default is http://timestamp.sectigo.com.

.PARAMETER NoTimestamp
Sign without a timestamp. Only for offline verification of the signing path.

.PARAMETER SignToolPath
Path to signtool.exe. The default searches the installed Windows SDKs.

.EXAMPLE
./scripts/build-zip.ps1

.EXAMPLE
# Uses the certificate named by $env:CODESIGN_CERT.
./scripts/build-zip.ps1 -Sign
#>
[CmdletBinding()]
param(
    [string]$ReleaseDirectory = "",
    [string]$OutputDirectory = "",
    [string]$OutputBaseName = "",
    [switch]$Sign,
    [string]$CertificateSubject = "",
    [string]$CertificateThumbprint = "",
    [string]$PfxPath = "",
    [string]$PfxPassword = "",
    [string]$TimestampUrl = "http://timestamp.sectigo.com",
    [switch]$NoTimestamp,
    [string]$SignToolPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "This script builds the Windows ZIP archive."
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-RepositoryPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $Path))
}

$releaseRoot = if ([string]::IsNullOrWhiteSpace($ReleaseDirectory)) {
    Join-Path $repositoryRoot "zig-out\release"
} else {
    Resolve-RepositoryPath $ReleaseDirectory
}
$outputRoot = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Join-Path $repositoryRoot "zig-out\zip"
} else {
    Resolve-RepositoryPath $OutputDirectory
}

# ---------------------------------------------------------------------------
# Validate the release tree.
# ---------------------------------------------------------------------------
. (Join-Path $PSScriptRoot "windows-brand.ps1")
$brand = Get-GhosttyBrand -Prefix $releaseRoot
$releaseExecutable = Get-GhosttyBrandExecutable -Prefix $releaseRoot -Brand $brand
$releaseResources = Join-Path $releaseRoot (Join-Path "share" $brand.resources_dir_name)
$licenseFiles = @(
    (Join-Path $repositoryRoot "LICENSE")
    # Required by the MIT license the ConPTY host is redistributed under.
    (Join-Path $repositoryRoot "dist\windows\THIRD-PARTY-NOTICES.md")
)
$requiredPaths = @(
    $releaseExecutable
    (Join-Path $releaseRoot ("share\terminfo\{0}.terminfo" -f $brand.identifier))
    (Join-Path $releaseResources "themes")
    (Join-Path $releaseResources "shell-integration")
    (Join-Path $releaseRoot "bin\conpty.dll")
    (Join-Path $releaseRoot "bin\OpenConsole.exe")
) + $licenseFiles
foreach ($required in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Release tree is incomplete; missing $required. Run scripts/build-release.ps1 first."
    }
}

# The archive takes the whole release tree, so it must hold only what the
# current build installed. scripts/build-release.ps1 empties its output
# before building; an older or hand-made tree may still carry other files.
$foreignExecutables = @(
    Get-ChildItem -LiteralPath (Join-Path $releaseRoot "bin") -File -Filter "*.exe" |
        Where-Object { $_.Name -notin @("$($brand.exe_name).exe", "OpenConsole.exe") }
)
if ($foreignExecutables.Count -gt 0) {
    throw ("The release tree contains executables from another build: " +
        "$($foreignExecutables.Name -join ', '). Rebuild with scripts/build-release.ps1.")
}

$versionInfo = (Get-Item -LiteralPath $releaseExecutable).VersionInfo
if ([string]::IsNullOrWhiteSpace($versionInfo.FileVersion)) {
    throw "The release executable does not contain FileVersion information."
}
if ($versionInfo.IsDebug) {
    throw "The release executable is a debug build; archives are built from ReleaseFast output."
}
$versionString = $versionInfo.FileVersion
if ($versionInfo.ProductName -ne $brand.display_name) {
    throw ("brand.json names the product $($brand.display_name) but the executable " +
        "reports $($versionInfo.ProductName). Rebuild with scripts/build-release.ps1.")
}
. (Join-Path $PSScriptRoot "windows-version.ps1")
$expectedVersion = Get-GhosttyWindowsVersion -RepositoryRoot $repositoryRoot
if ($expectedVersion -ne $versionString) {
    throw ("dist/windows/version.txt holds $expectedVersion but the executable " +
        "reports $versionString. Rebuild with scripts/build-release.ps1.")
}
if (-not [string]::IsNullOrWhiteSpace($OutputBaseName)) {
    $outputBase = $OutputBaseName
} else {
    $safeVersion = $versionString.Split("+")[0]
    $safeVersion = ($safeVersion -replace '[^0-9A-Za-z.\-]', '-') -replace '-{2,}', '-'
    $outputBase = "$($brand.exe_name)-$($safeVersion.Trim('-'))-x64-portable"
}

# ---------------------------------------------------------------------------
# Signing configuration (the same rules as scripts/build-installer.ps1).
# ---------------------------------------------------------------------------
function Find-SignTool {
    if (-not [string]::IsNullOrWhiteSpace($SignToolPath)) {
        if (-not (Test-Path -LiteralPath $SignToolPath -PathType Leaf)) {
            throw "signtool.exe not found: $SignToolPath"
        }
        return (Resolve-Path -LiteralPath $SignToolPath).Path
    }
    $kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    $architecture = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq "Arm64") {
        "arm64"
    } else {
        "x64"
    }
    $candidates = @(
        Get-ChildItem -Path (Join-Path $kits "*\$architecture\signtool.exe") -ErrorAction SilentlyContinue |
            Sort-Object -Property FullName -Descending
    )
    if ($candidates.Count -gt 0) {
        return $candidates[0].FullName
    }
    $onPath = Get-Command signtool.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($onPath) {
        return $onPath.Source
    }
    throw "signtool.exe was not found. Install the Windows SDK or pass -SignToolPath."
}

$signTool = $null
$signArguments = @()
if ($Sign) {
    $haveThumbprint = -not [string]::IsNullOrWhiteSpace($CertificateThumbprint)
    $havePfx = -not [string]::IsNullOrWhiteSpace($PfxPath)
    $haveSubject = -not [string]::IsNullOrWhiteSpace($CertificateSubject)
    $selectors = @(@($haveThumbprint, $havePfx, $haveSubject) | Where-Object { $_ })
    if ($selectors.Count -gt 1) {
        throw "-CertificateSubject, -CertificateThumbprint, and -PfxPath are mutually exclusive."
    }
    if ($selectors.Count -eq 0) {
        if ([string]::IsNullOrWhiteSpace($env:CODESIGN_CERT)) {
            throw "-Sign needs a certificate. Set the CODESIGN_CERT environment variable to the subject name of your code-signing certificate, or pass -CertificateSubject, -CertificateThumbprint, or -PfxPath."
        }
        $CertificateSubject = $env:CODESIGN_CERT
        $haveSubject = $true
    }
    if ($NoTimestamp -and $PSBoundParameters.ContainsKey("TimestampUrl")) {
        throw "-NoTimestamp cannot be combined with -TimestampUrl."
    }

    $signTool = Find-SignTool
    $signArguments = @("sign", "/fd", "SHA256")
    if (-not $NoTimestamp) {
        if ([string]::IsNullOrWhiteSpace($TimestampUrl)) {
            throw "A timestamp URL is required unless -NoTimestamp is given."
        }
        $signArguments += @("/td", "SHA256", "/tr", $TimestampUrl)
    }
    if ($haveSubject) {
        $matching = @(
            Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue |
                Where-Object { $_.Subject -like "*$CertificateSubject*" -and $_.HasPrivateKey }
        )
        if ($matching.Count -eq 0) {
            throw "No code-signing certificate with a private key matches subject '$CertificateSubject'."
        }
        $signArguments += @("/n", $CertificateSubject)
        Write-Host "Code signing enabled: subject '$CertificateSubject' ($($matching.Count) matching certificate(s))"
    } elseif ($haveThumbprint) {
        $thumbprint = ($CertificateThumbprint -replace '\s', '').ToUpperInvariant()
        if ($thumbprint -notmatch '^[0-9A-F]{40}$') {
            throw "CertificateThumbprint must be a 40-character SHA-1 hex string."
        }
        $signArguments += @("/sha1", $thumbprint)
        Write-Host "Code signing enabled: thumbprint $thumbprint"
    } else {
        $pfxFullPath = Resolve-RepositoryPath $PfxPath
        if (-not (Test-Path -LiteralPath $pfxFullPath -PathType Leaf)) {
            throw "PFX file not found: $pfxFullPath"
        }
        $signArguments += @("/f", $pfxFullPath)
        if (-not [string]::IsNullOrWhiteSpace($PfxPassword)) {
            $signArguments += @("/p", $PfxPassword)
        }
        Write-Host "Code signing enabled: PFX $pfxFullPath"
    }
}

# ---------------------------------------------------------------------------
# Stage the release tree so signing never touches zig-out/release.
# ---------------------------------------------------------------------------
$stageRoot = Join-Path $outputRoot "stage"
if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
$stageTop = Join-Path $stageRoot $outputBase
[System.IO.Directory]::CreateDirectory($stageTop) | Out-Null
foreach ($item in Get-ChildItem -LiteralPath $releaseRoot -Force) {
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $stageTop $item.Name) -Recurse
}
foreach ($license in $licenseFiles) {
    Copy-Item -LiteralPath $license -Destination (Join-Path $stageTop (Split-Path -Leaf $license))
}
$stagedExecutable = Get-GhosttyBrandExecutable -Prefix $stageTop -Brand $brand

if ($Sign) {
    Write-Host "Signing $stagedExecutable"
    & $signTool @signArguments $stagedExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "signtool failed with exit code $LASTEXITCODE for $stagedExecutable."
    }
    if ($null -eq (Get-AuthenticodeSignature -LiteralPath $stagedExecutable).SignerCertificate) {
        throw "No Authenticode signature was applied to $stagedExecutable."
    }
}

# ---------------------------------------------------------------------------
# Compress and verify.
# ---------------------------------------------------------------------------
$archive = Join-Path $outputRoot "$outputBase.zip"
if (Test-Path -LiteralPath $archive) {
    Remove-Item -LiteralPath $archive -Force
}
Write-Host "Building $($brand.display_name) portable archive $versionString"
Write-Host "Output: $archive"
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stageTop,
    $archive,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $true
)

$stagedFileCount = @(Get-ChildItem -LiteralPath $stageTop -File -Recurse).Count
$zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
try {
    $entries = @($zip.Entries | Where-Object { -not $_.FullName.EndsWith("/") })
    $executableEntry = "$outputBase/bin/$($brand.exe_name).exe"
    if (-not ($entries | Where-Object { $_.FullName -eq $executableEntry })) {
        throw "The archive does not contain $executableEntry."
    }
    if ($entries.Count -ne $stagedFileCount) {
        throw "The archive holds $($entries.Count) files but $stagedFileCount were staged."
    }
    $entryCount = $entries.Count
} finally {
    $zip.Dispose()
}

$executableSignature = Get-AuthenticodeSignature -LiteralPath $stagedExecutable
if ($Sign -and $null -eq $executableSignature.SignerCertificate) {
    throw "The executable is not signed although -Sign was requested."
}
$hash = Get-FileHash -LiteralPath $archive -Algorithm SHA256

[pscustomobject]@{
    Archive             = $archive
    Version             = $versionString
    DevelopmentBuild    = $versionString.Contains("+")
    Files               = $entryCount
    SizeBytes           = (Get-Item -LiteralPath $archive).Length
    Sha256              = $hash.Hash
    StagedExecutable    = $stagedExecutable
    Signed              = [bool]$Sign
    ExecutableSignature = $executableSignature.Status.ToString()
    ExecutableSigner    = if ($executableSignature.SignerCertificate) { $executableSignature.SignerCertificate.Subject } else { $null }
    Timestamped         = [bool]($Sign -and -not $NoTimestamp)
    SignToolPath        = $signTool
}
