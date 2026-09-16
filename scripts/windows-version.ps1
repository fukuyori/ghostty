<#
.SYNOPSIS
Reads the Windows preview version from dist/windows/version.txt.

.DESCRIPTION
Dot-source this file from the release and installer scripts. The version comes
from the working tree, so it does not depend on commits or tags. The file must
hold a single Semantic Version whose major, minor, and patch match the
.version in build.zig.zon. See docs/version-update-checklist.md.
#>

function Get-GhosttyWindowsVersion {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $versionFile = Join-Path $RepositoryRoot "dist\windows\version.txt"
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
        throw "The Windows version file is missing: $versionFile"
    }

    $lines = @(
        Get-Content -LiteralPath $versionFile -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" }
    )
    if ($lines.Count -ne 1) {
        throw "$versionFile must contain exactly one version line, for example 1.3.2-windows.6."
    }
    $version = $lines[0]

    # Semantic Versioning 2.0.0 (https://semver.org), the same grammar
    # std.SemanticVersion.parse accepts for -Dversion-string.
    $identifier = '(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    $pattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)' +
        "(?:-$identifier(?:\.$identifier)*)?" +
        '(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
    if ($version -notmatch $pattern) {
        throw "$versionFile holds '$version', which is not a Semantic Version."
    }
    $numeric = "{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3]

    $zon = Join-Path $RepositoryRoot "build.zig.zon"
    $zonText = Get-Content -LiteralPath $zon -Raw -Encoding UTF8
    if ($zonText -notmatch '\.version\s*=\s*"([0-9]+)\.([0-9]+)\.([0-9]+)') {
        throw "Unable to read .version from $zon."
    }
    $zonNumeric = "{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3]
    if ($numeric -ne $zonNumeric) {
        throw "$versionFile holds $version, but build.zig.zon is on $zonNumeric; the numeric parts must match."
    }

    return $version
}
