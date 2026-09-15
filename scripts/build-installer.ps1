<#
.SYNOPSIS
Builds the Ghostty Windows installer with Inno Setup.

.DESCRIPTION
Stages the release tree produced by scripts/build-release.ps1, reads the
version from the executable's file properties, and compiles
dist/windows/ghostty.iss with the Inno Setup command-line compiler. With
-Sign, the staged ghostty.exe is signed with signtool before packaging and
Inno Setup signs the installer and the embedded uninstaller with the same
certificate. The release tree itself is never modified.

.PARAMETER ReleaseDirectory
The release prefix that contains bin\ghostty.exe and share\. Relative paths
are resolved from the repository root. The default is zig-out\release.

.PARAMETER OutputDirectory
Directory that receives the installer and the staged, optionally signed,
release files. The default is zig-out\installer.

.PARAMETER Version
Expected version string, for example 1.3.2-windows.1. When given, the
executable's FileVersion must match or the build fails.

.PARAMETER OutputBaseName
Installer file name without the extension. The default is
ghostty-<version>-x64-setup, with the version read from the release
executable.

.PARAMETER Sign
Sign ghostty.exe, the installer, and the uninstaller with Authenticode.
By default the certificate is selected by subject name from the CODESIGN_CERT
environment variable (signtool /n), the same convention as the other
packaging scripts on this machine. CertificateSubject, CertificateThumbprint,
or PfxPath override it.

.PARAMETER CertificateSubject
Subject name (or a substring of it) of a code-signing certificate in the
certificate store, passed to signtool /n. Defaults to CODESIGN_CERT.

.PARAMETER CertificateThumbprint
SHA-1 thumbprint of a code-signing certificate in the current user's or the
machine's certificate store, passed to signtool /sha1. Use this when several
certificates share a subject name.

.PARAMETER PfxPath
Path to a PFX file containing the signing certificate and private key.

.PARAMETER PfxPassword
Password for PfxPath. The value is passed to signtool and to the Inno Setup
compiler on their command lines, where other processes of the same user can
observe it. Prefer CertificateThumbprint.

.PARAMETER TimestampUrl
RFC 3161 timestamp server. The default is http://timestamp.sectigo.com.
Timestamping keeps signatures valid after the certificate expires.

.PARAMETER NoTimestamp
Sign without contacting a timestamp server. Only for offline verification of
the signing path; distributed builds should always be timestamped.

.PARAMETER SignToolPath
Path to signtool.exe. The default searches the installed Windows SDKs.

.PARAMETER IsccPath
Path to ISCC.exe. The default searches the Inno Setup 6 install locations.

.EXAMPLE
./scripts/build-installer.ps1

.EXAMPLE
# Uses the certificate named by $env:CODESIGN_CERT.
./scripts/build-installer.ps1 -Version 1.3.2-windows.1 -Sign

.EXAMPLE
./scripts/build-installer.ps1 -Version 1.3.2-windows.1 -Sign `
    -CertificateThumbprint 0123456789ABCDEF0123456789ABCDEF01234567
#>
[CmdletBinding()]
param(
    [string]$ReleaseDirectory = "",
    [string]$OutputDirectory = "",
    [string]$Version = "",
    [string]$OutputBaseName = "",
    [switch]$Sign,
    [string]$CertificateSubject = "",
    [string]$CertificateThumbprint = "",
    [string]$PfxPath = "",
    [string]$PfxPassword = "",
    [string]$TimestampUrl = "http://timestamp.sectigo.com",
    [switch]$NoTimestamp,
    [string]$SignToolPath = "",
    [string]$IsccPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "This script builds the Windows installer with Inno Setup."
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$scriptFile = Join-Path $repositoryRoot "dist\windows\ghostty.iss"
if (-not (Test-Path -LiteralPath $scriptFile -PathType Leaf)) {
    throw "Installer script not found: $scriptFile"
}

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
    Join-Path $repositoryRoot "zig-out\installer"
} else {
    Resolve-RepositoryPath $OutputDirectory
}

# ---------------------------------------------------------------------------
# Validate the release tree.
# ---------------------------------------------------------------------------
$releaseExecutable = Join-Path $releaseRoot "bin\ghostty.exe"
$requiredPaths = @(
    $releaseExecutable
    (Join-Path $releaseRoot "share\terminfo\ghostty.terminfo")
    (Join-Path $releaseRoot "share\ghostty\themes")
    (Join-Path $releaseRoot "share\ghostty\shell-integration")
)
foreach ($required in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Release tree is incomplete; missing $required. Run scripts/build-release.ps1 first."
    }
}

# The compiled terminfo database is only present when the release build found
# tic. Ship whatever is there, and say so when the database is missing: without
# it, programs reading terminfo inside Ghostty cannot resolve xterm-ghostty.
$terminfoRoot = Join-Path $releaseRoot (Join-Path "share" "terminfo")
$terminfoCompiled = @(
    Get-ChildItem -LiteralPath $terminfoRoot -File -Recurse |
        Where-Object { $_.Name -in @("ghostty", "xterm-ghostty") }
).Count -gt 0
if (-not $terminfoCompiled) {
    Write-Warning ("The release tree has no compiled terminfo database, so " +
        "the installer cannot ship one. Install tic (Git for Windows ships " +
        "one) and rerun scripts/build-release.ps1.")
}

$versionInfo = (Get-Item -LiteralPath $releaseExecutable).VersionInfo
if ([string]::IsNullOrWhiteSpace($versionInfo.FileVersion)) {
    throw "The release executable does not contain FileVersion information."
}
if ($versionInfo.IsDebug) {
    throw "The release executable is a debug build; installers are built from ReleaseFast output."
}
$versionString = $versionInfo.FileVersion
if (-not [string]::IsNullOrWhiteSpace($Version) -and $Version -ne $versionString) {
    throw "Expected version $Version but the executable reports $versionString."
}
$numericVersion = "{0}.{1}.{2}.{3}" -f `
    $versionInfo.FileMajorPart, `
    $versionInfo.FileMinorPart, `
    $versionInfo.FileBuildPart, `
    $versionInfo.FilePrivatePart
# The file name carries the version read from the executable, minus the build
# metadata a development build appends (1.3.2-windows-+abc1234), which would
# otherwise change the name on every commit. Inno Setup rejects file names
# outside this character set, and dropping the metadata leaves a trailing
# separator to clean up.
#   1.3.2-windows-+abc1234 -> ghostty-1.3.2-windows-x64-setup.exe
#   1.3.2-windows.3        -> ghostty-1.3.2-windows.3-x64-setup.exe
$isDevelopmentBuild = $versionString.Contains("+")
if (-not [string]::IsNullOrWhiteSpace($OutputBaseName)) {
    $outputBase = $OutputBaseName
} else {
    $safeVersion = $versionString.Split("+")[0]
    $safeVersion = ($safeVersion -replace '[^0-9A-Za-z.\-]', '-') -replace '-{2,}', '-'
    $outputBase = "ghostty-$($safeVersion.Trim('-'))-x64-setup"
}
if ($isDevelopmentBuild) {
    Write-Warning ("Packaging the development build $versionString. This is " +
        "not a distributable release; build with " +
        "-AdditionalZigArgs '-Dversion-string=X.Y.Z-windows.N' for that.")
}

# ---------------------------------------------------------------------------
# Locate tools.
# ---------------------------------------------------------------------------
function Find-Iscc {
    if (-not [string]::IsNullOrWhiteSpace($IsccPath)) {
        if (-not (Test-Path -LiteralPath $IsccPath -PathType Leaf)) {
            throw "ISCC.exe not found: $IsccPath"
        }
        return (Resolve-Path -LiteralPath $IsccPath).Path
    }
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe")
        (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    $onPath = Get-Command ISCC.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($onPath) {
        return $onPath.Source
    }
    throw "Inno Setup 6 (ISCC.exe) was not found. Install it from https://jrsoftware.org/isinfo.php or pass -IsccPath."
}

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

$iscc = Find-Iscc

# ---------------------------------------------------------------------------
# Signing configuration.
# ---------------------------------------------------------------------------
$signTool = $null
$signArguments = @()
$signerDescription = $null
if ($Sign) {
    $haveThumbprint = -not [string]::IsNullOrWhiteSpace($CertificateThumbprint)
    $havePfx = -not [string]::IsNullOrWhiteSpace($PfxPath)
    $haveSubject = -not [string]::IsNullOrWhiteSpace($CertificateSubject)
    $selectors = @(@($haveThumbprint, $havePfx, $haveSubject) | Where-Object { $_ })
    if ($selectors.Count -gt 1) {
        throw "-CertificateSubject, -CertificateThumbprint, and -PfxPath are mutually exclusive."
    }
    if ($selectors.Count -eq 0) {
        # Same convention as the other packaging scripts: CODESIGN_CERT holds
        # the subject name of the certificate in the user's store.
        if ([string]::IsNullOrWhiteSpace($env:CODESIGN_CERT)) {
            throw "-Sign needs a certificate. Set the CODESIGN_CERT environment variable to the subject name of your code-signing certificate, or pass -CertificateSubject, -CertificateThumbprint, or -PfxPath."
        }
        $CertificateSubject = $env:CODESIGN_CERT
        $haveSubject = $true
    }
    if ($NoTimestamp -and -not [string]::IsNullOrWhiteSpace($TimestampUrl) -and
        $PSBoundParameters.ContainsKey("TimestampUrl")) {
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
        $signerDescription = "subject '$CertificateSubject' ($($matching.Count) matching certificate(s))"
    } elseif ($haveThumbprint) {
        $thumbprint = ($CertificateThumbprint -replace '\s', '').ToUpperInvariant()
        if ($thumbprint -notmatch '^[0-9A-F]{40}$') {
            throw "CertificateThumbprint must be a 40-character SHA-1 hex string."
        }
        $signArguments += @("/sha1", $thumbprint)
        $signerDescription = "thumbprint $thumbprint"
    } else {
        $pfxFullPath = Resolve-RepositoryPath $PfxPath
        if (-not (Test-Path -LiteralPath $pfxFullPath -PathType Leaf)) {
            throw "PFX file not found: $pfxFullPath"
        }
        $signArguments += @("/f", $pfxFullPath)
        if (-not [string]::IsNullOrWhiteSpace($PfxPassword)) {
            $signArguments += @("/p", $PfxPassword)
        }
        $signerDescription = "PFX $pfxFullPath"
    }
    Write-Host "Code signing enabled: $signerDescription"
}

function Invoke-SignTool {
    param(
        [Parameter(Mandatory)]
        [string]$File
    )
    & $signTool @signArguments $File
    if ($LASTEXITCODE -ne 0) {
        throw "signtool failed with exit code $LASTEXITCODE for $File."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $File
    if ($null -eq $signature.SignerCertificate) {
        throw "No Authenticode signature was applied to $File."
    }
}

# ---------------------------------------------------------------------------
# Stage the release tree so signing never touches zig-out/release.
# ---------------------------------------------------------------------------
$stageRoot = Join-Path $outputRoot "stage"
if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
[System.IO.Directory]::CreateDirectory($outputRoot) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $stageRoot "bin")) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $stageRoot "share")) | Out-Null
Copy-Item -LiteralPath $releaseExecutable -Destination (Join-Path $stageRoot "bin\ghostty.exe")
# The whole terminfo directory, so the compiled database travels with the
# source rather than only the source file.
Copy-Item `
    -LiteralPath $terminfoRoot `
    -Destination (Join-Path $stageRoot "share\terminfo") `
    -Recurse
Copy-Item `
    -LiteralPath (Join-Path $releaseRoot "share\ghostty") `
    -Destination (Join-Path $stageRoot "share\ghostty") `
    -Recurse

$stagedExecutable = Join-Path $stageRoot "bin\ghostty.exe"
if ($Sign) {
    Write-Host "Signing $stagedExecutable"
    Invoke-SignTool -File $stagedExecutable
}

# ---------------------------------------------------------------------------
# Compile the installer.
# ---------------------------------------------------------------------------
$isccArguments = @(
    "/DGhosttyVersion=$versionString"
    "/DGhosttyNumericVersion=$numericVersion"
    "/DGhosttySourceDir=$stageRoot"
    "/DGhosttyOutputDir=$outputRoot"
    "/DGhosttyOutputBase=$outputBase"
)
if ($Sign) {
    # Inno Setup runs this command for the installer and the uninstaller.
    # $q stands for a double quote and $f for the file being signed.
    $signCommand = '$q' + $signTool + '$q'
    foreach ($argument in $signArguments) {
        if ($argument -match '[\s"]') {
            $signCommand += ' $q' + $argument + '$q'
        } else {
            $signCommand += ' ' + $argument
        }
    }
    $signCommand += ' $f'
    $isccArguments += "/DGhosttySign"
    $isccArguments += "/Sghosttysign=$signCommand"
}
$isccArguments += $scriptFile

Write-Host "Building Ghostty installer $versionString ($numericVersion)"
Write-Host "Inno Setup: $iscc"
Write-Host "Output: $outputRoot"
& $iscc @isccArguments
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
}

$installer = Join-Path $outputRoot "$outputBase.exe"
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "Inno Setup did not produce $installer."
}

# ---------------------------------------------------------------------------
# Verify the result.
# ---------------------------------------------------------------------------
$installerInfo = (Get-Item -LiteralPath $installer).VersionInfo
# Inno Setup pads VERSIONINFO strings with spaces.
$installerProductVersion = $installerInfo.ProductVersion.Trim()
if ($installerProductVersion -ne $versionString) {
    throw "Installer ProductVersion '$installerProductVersion' does not match $versionString."
}
$installerNumeric = "{0}.{1}.{2}.{3}" -f `
    $installerInfo.FileMajorPart, `
    $installerInfo.FileMinorPart, `
    $installerInfo.FileBuildPart, `
    $installerInfo.FilePrivatePart
if ($installerNumeric -ne $numericVersion) {
    throw "Installer numeric version $installerNumeric does not match $numericVersion."
}

$executableSignature = Get-AuthenticodeSignature -LiteralPath $stagedExecutable
$installerSignature = Get-AuthenticodeSignature -LiteralPath $installer
if ($Sign) {
    foreach ($entry in @(
        @{ Name = "ghostty.exe"; Signature = $executableSignature },
        @{ Name = "installer"; Signature = $installerSignature }
    )) {
        if ($null -eq $entry.Signature.SignerCertificate) {
            throw "The $($entry.Name) is not signed although -Sign was requested."
        }
    }
}

$hash = Get-FileHash -LiteralPath $installer -Algorithm SHA256

[pscustomobject]@{
    Installer            = $installer
    Version              = $versionString
    DevelopmentBuild     = $isDevelopmentBuild
    TerminfoCompiled     = $terminfoCompiled
    NumericVersion       = $numericVersion
    SizeBytes            = (Get-Item -LiteralPath $installer).Length
    Sha256               = $hash.Hash
    StagedExecutable     = $stagedExecutable
    Signed               = [bool]$Sign
    ExecutableSignature  = $executableSignature.Status.ToString()
    ExecutableSigner     = if ($executableSignature.SignerCertificate) { $executableSignature.SignerCertificate.Subject } else { $null }
    InstallerSignature   = $installerSignature.Status.ToString()
    InstallerSigner      = if ($installerSignature.SignerCertificate) { $installerSignature.SignerCertificate.Subject } else { $null }
    UninstallerSigned    = [bool]$Sign
    Timestamped          = [bool]($Sign -and -not $NoTimestamp)
    IsccPath             = $iscc
    SignToolPath         = $signTool
}
