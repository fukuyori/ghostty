<#
.SYNOPSIS
Reads the product names from brand.json in a Ghostty install prefix.

.DESCRIPTION
Dot-source this file from the release, installer and test scripts. Every
Windows build writes brand.json, generated from src/brand.zig, to the root
of its install prefix (zig-out by default, zig-out\release for the release
script). Scripts read the executable, resource directory, terminfo, window
class and other names from it instead of spelling them out, so a rename
changes src/brand.zig only.

The file is required: a prefix without it was built before brand.json
existed or by another build, and guessing the names would hide that.
#>

$script:GhosttyBrandSchema = 1

$script:GhosttyBrandFields = @(
    "display_name",
    "identifier",
    "env_prefix",
    "exe_name",
    "resources_dir_name",
    "config_dir_name",
    "config_file_name",
    "terminfo_name",
    "term_program",
    "window_class_prefix",
    "ipc_pipe_prefix",
    "app_user_model_id",
    "installer_app_id"
)

function Get-GhosttyBrand {
    param(
        # Install prefix that holds brand.json, bin\ and share\.
        [Parameter(Mandatory)]
        [string]$Prefix
    )

    $path = Join-Path $Prefix "brand.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "brand.json is missing from $Prefix. Rebuild with zig build so the install prefix contains it."
    }

    try {
        $brand = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Unable to parse ${path}: $($_.Exception.Message)"
    }

    if ($brand.schema -ne $script:GhosttyBrandSchema) {
        throw "$path has schema '$($brand.schema)', but this script expects $script:GhosttyBrandSchema. Rebuild, or update scripts/windows-brand.ps1 together with src/brand.zig."
    }
    foreach ($field in $script:GhosttyBrandFields) {
        $value = $brand.$field
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            throw "$path has no value for '$field'."
        }
    }

    return $brand
}

function Get-GhosttyBrandExecutable {
    param(
        [Parameter(Mandatory)]
        [string]$Prefix,

        [Parameter(Mandatory)]
        $Brand
    )

    return Join-Path $Prefix ("bin\{0}.exe" -f $Brand.exe_name)
}

function Get-GhosttyBrandForPrefix {
    param(
        # Install prefix a test script uses, which may not have brand.json.
        [Parameter(Mandatory)]
        [string]$Prefix,

        # Repository root; its zig-out\brand.json is the fallback.
        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    if (Test-Path -LiteralPath (Join-Path $Prefix "brand.json") -PathType Leaf) {
        return Get-GhosttyBrand -Prefix $Prefix
    }
    return Get-GhosttyBrand -Prefix (Join-Path $RepositoryRoot "zig-out")
}

function Get-GhosttyBrandForExecutable {
    param(
        # Executable a test script was given, as the script resolved it.
        [Parameter(Mandatory)]
        [string]$Executable,

        # Repository root; its zig-out\brand.json is the fallback.
        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    # An executable under <prefix>\bin uses that prefix's brand.json. An
    # executable elsewhere, or from a prefix without brand.json, falls back
    # to the repository's default zig-out prefix.
    $directory = Split-Path -Parent $Executable
    if ($directory -and (Split-Path -Leaf $directory) -eq "bin") {
        $prefix = Split-Path -Parent $directory
        if ($prefix) {
            return Get-GhosttyBrandForPrefix -Prefix $prefix -RepositoryRoot $RepositoryRoot
        }
    }
    return Get-GhosttyBrand -Prefix (Join-Path $RepositoryRoot "zig-out")
}
