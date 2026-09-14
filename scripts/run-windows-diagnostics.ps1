<#
.SYNOPSIS
Runs Ghostty with stdout and stderr redirected to diagnostic log files.

.DESCRIPTION
Starts the native Windows Ghostty executable with GHOSTTY_LOG=stderr=true for
the child process. Logs are written under zig-out/logs by default so startup
failures remain available when the GUI subsystem has no visible console.

.PARAMETER Executable
Ghostty executable to run. Relative paths are resolved from the repository
root. The default is zig-out/bin/ghostty.exe.

.PARAMETER LogDirectory
Directory for stdout and stderr logs. Relative paths are resolved from the
repository root. The default is zig-out/logs.

.PARAMETER AdditionalArguments
Arguments passed to Ghostty.

.PARAMETER Wait
Wait for Ghostty to exit and include its exit code in the result.

.EXAMPLE
./scripts/run-windows-diagnostics.ps1

.EXAMPLE
./scripts/run-windows-diagnostics.ps1 -Wait

.EXAMPLE
./scripts/run-windows-diagnostics.ps1 -AdditionalArguments @('+validate-config') -Wait
#>
[CmdletBinding()]
param(
    [string]$Executable = "",
    [string]$LogDirectory = "",
    [string[]]$AdditionalArguments = @(),
    [switch]$Wait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "This script runs the native Windows Ghostty executable."
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($Executable)) {
    $executablePath = Join-Path $repositoryRoot "zig-out\bin\ghostty.exe"
} elseif ([System.IO.Path]::IsPathRooted($Executable)) {
    $executablePath = [System.IO.Path]::GetFullPath($Executable)
} else {
    $executablePath = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $Executable))
}

if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "Ghostty executable not found: $executablePath"
}

if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $logDirectoryPath = Join-Path $repositoryRoot "zig-out\logs"
} elseif ([System.IO.Path]::IsPathRooted($LogDirectory)) {
    $logDirectoryPath = [System.IO.Path]::GetFullPath($LogDirectory)
} else {
    $logDirectoryPath = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $LogDirectory))
}

[System.IO.Directory]::CreateDirectory($logDirectoryPath) | Out-Null

$sessionName = "ghostty-{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"), ([System.Guid]::NewGuid().ToString("N").Substring(0, 8))
$stdoutPath = Join-Path $logDirectoryPath "$sessionName.stdout.log"
$stderrPath = Join-Path $logDirectoryPath "$sessionName.stderr.log"

$previousGhosttyLog = [System.Environment]::GetEnvironmentVariable(
    "GHOSTTY_LOG",
    [System.EnvironmentVariableTarget]::Process
)

try {
    [System.Environment]::SetEnvironmentVariable(
        "GHOSTTY_LOG",
        "stderr=true",
        [System.EnvironmentVariableTarget]::Process
    )
    $startOptions = @{
        FilePath = $executablePath
        RedirectStandardOutput = $stdoutPath
        RedirectStandardError = $stderrPath
        PassThru = $true
    }
    if ($AdditionalArguments.Count -gt 0) {
        $startOptions.ArgumentList = $AdditionalArguments
    }
    $process = Start-Process @startOptions
} finally {
    [System.Environment]::SetEnvironmentVariable(
        "GHOSTTY_LOG",
        $previousGhosttyLog,
        [System.EnvironmentVariableTarget]::Process
    )
}

$exitCode = $null
if ($Wait) {
    $process.WaitForExit()
    $exitCode = $process.ExitCode
}

[pscustomobject]@{
    ProcessId = $process.Id
    Executable = $executablePath
    StdoutLog = $stdoutPath
    StderrLog = $stderrPath
    Waited = [bool]$Wait
    ExitCode = $exitCode
}
