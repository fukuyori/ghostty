<#
.SYNOPSIS
Checks modal action lifetime and close-target identity in dedicated processes.
.DESCRIPTION
Uses synthetic native key messages and marker-driven shell exits. This does
not verify physical input or Narrator speech. Logs and fixtures stay in zig-out.
#>
[CmdletBinding()]
param(
    [string]$Executable = 'zig-out/bin/ghostty.exe',
    [ValidateSet('RenameShellExit', 'CloseTabIndexShift', 'CloseAllShellExit', 'QuitShellExit')]
    [string[]]$Case = @('RenameShellExit', 'CloseTabIndexShift', 'CloseAllShellExit', 'QuitShellExit'),
    [ValidateRange(1, 60)][int]$TimeoutSeconds = 15
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = if ([IO.Path]::IsPathRooted($Executable)) {
    (Resolve-Path -LiteralPath $Executable).Path
} else { (Resolve-Path -LiteralPath (Join-Path $root $Executable)).Path }
$name = 'modal-actions-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$fixture = Join-Path $root "zig-out/test-fixtures/$name"
$logs = Join-Path $root 'zig-out/logs'
$null = New-Item -ItemType Directory -Force -Path $fixture, $logs
if (-not ('GhosttyModalNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class GhosttyModalNative {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc f, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageTimeoutW")]
    static extern IntPtr ReadText(IntPtr h, uint m, UIntPtr w, StringBuilder s, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, UIntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
    public static string Class(IntPtr h) { var s=new StringBuilder(256); GetClassNameW(h,s,256); return s.ToString(); }
    public static string Text(IntPtr h) { var s=new StringBuilder(4096); UIntPtr r; if(ReadText(h,0xD,new UIntPtr(4096),s,2,2000,out r)==IntPtr.Zero) throw new Exception("Window text timed out"); return s.ToString(); }
    public static IntPtr[] Windows(uint pid, string cls) { var list=new List<IntPtr>(); EnumWindows((h,p)=>{ uint n; GetWindowThreadProcessId(h,out n); if(n==pid && Class(h)==cls) list.Add(h); return true; },IntPtr.Zero); return list.ToArray(); }
    public static IntPtr[] Children(IntPtr parent) { var list=new List<IntPtr>(); EnumChildWindows(parent,(h,p)=>{ if(Class(h)=="GhosttyWindow") list.Add(h); return true; },IntPtr.Zero); return list.ToArray(); }
}
'@
}
function Wait-State([string]$Description, [scriptblock]$Check) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $Check) { return }
        if ($process.HasExited) { throw "Process exited ($($process.ExitCode)): $Description" }
        Start-Sleep -Milliseconds 50
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Timed out: $Description"
}
function Post([IntPtr]$Handle, [uint32]$Message, [uint64]$W = 0, [long]$L = 0) {
    if (-not [GhosttyModalNative]::PostMessageW($Handle, $Message, [UIntPtr]::new($W), [IntPtr]::new($L))) { throw 'PostMessage failed' }
}
function Key([int]$Code) {
    $visible = @([GhosttyModalNative]::Children($window) | Where-Object { [GhosttyModalNative]::IsWindowVisible($_) })
    if ($visible.Count -ne 1) { throw "Expected one visible terminal, found $($visible.Count)" }
    Post $visible[0] 0x100 $Code 1
    Post $visible[0] 0x101 $Code 0xC0000001L
}
function Wait-Title([string]$Previous = '') {
    Wait-State 'shell title' {
        $title = [GhosttyModalNative]::Text($window)
        $title -match '^Modal probe [0-9]+$' -and $title -ne $Previous
    }
    return [GhosttyModalNative]::Text($window)
}
function Exit-Shell([string]$Title) {
    if ($Title -notmatch '^Modal probe ([0-9]+)$') { throw 'Unexpected probe title' }
    [IO.File]::WriteAllText((Join-Path $directory ('exit-' + $Matches[1])), 'exit')
}
$results = @()
foreach ($scenario in $Case) {
    $directory = Join-Path $fixture $scenario
    $null = New-Item -ItemType Directory -Path $directory
    $prefix = Join-Path $logs "$name-$scenario"
    $probe = Join-Path $directory 'probe.ps1'
    @'
[Console]::Write(([char]27).ToString() + ']2;Modal probe ' + $PID + [char]7)
[Console]::WriteLine('Dedicated modal lifetime regression. Waiting for exit marker.')
[IO.File]::WriteAllText((Join-Path $PSScriptRoot ('shell-' + $PID)), '')
while (-not [IO.File]::Exists((Join-Path $PSScriptRoot ('exit-' + $PID)))) { Start-Sleep -Milliseconds 50 }
'@ | Set-Content -LiteralPath $probe -Encoding utf8
    $command = "& '$($probe.Replace("'", "''"))'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $config = Join-Path $directory 'config'
    @"
command = pwsh.exe -NoLogo -NoProfile -EncodedCommand $encoded
shell-integration = none
confirm-close-surface = always
quit-after-last-window-closed = true
window-show-tab-bar = always
window-new-tab-position = end
keybind = f2=new_tab
keybind = f4=prompt_tab_title
keybind = f6=close_tab
keybind = f8=close_all_windows
keybind = f9=quit
"@ | Set-Content -LiteralPath $config -Encoding utf8
    $process = $null
    $failure = $null
    $forced = $false
    try {
        $process = Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList @('--config-default-files=false', "--config-file=`"$config`"") -PassThru -RedirectStandardOutput "$prefix.stdout.log" -RedirectStandardError "$prefix.stderr.log"
        Wait-State 'main window' { [GhosttyModalNative]::Windows($process.Id, 'GhosttyWindow').Count -eq 1 }
        $window = [GhosttyModalNative]::Windows($process.Id, 'GhosttyWindow')[0]
        $null = [GhosttyModalNative]::ShowWindow($window, 9)
        Wait-State 'visible terminal' { @([GhosttyModalNative]::Children($window) | Where-Object { [GhosttyModalNative]::IsWindowVisible($_) }).Count -eq 1 }
        $first = Wait-Title
        if ($scenario -eq 'CloseTabIndexShift') {
            Key 113
            $second = Wait-Title $first
            Key 113
            $third = Wait-Title $second
            Key 117
        } else {
            Key $(switch ($scenario) { 'RenameShellExit' { 115 }; 'CloseAllShellExit' { 119 }; 'QuitShellExit' { 120 } })
        }
        Wait-State 'modal dialog' { [GhosttyModalNative]::Windows($process.Id, '#32770').Count -eq 1 }
        $dialog = [GhosttyModalNative]::Windows($process.Id, '#32770')[0]
        Exit-Shell $first
        if ($scenario -eq 'CloseTabIndexShift') {
            Wait-State 'earlier tab exits inside modal' { [GhosttyModalNative]::Children($window).Count -eq 2 }
            # WM_COMMAND/IDYES avoids BM_CLICK's active-dialog requirement.
            Post $dialog 0x111 6
            Wait-State 'original target closes and other tab survives' {
                [GhosttyModalNative]::Children($window).Count -eq 1 -and [GhosttyModalNative]::Text($window) -eq $second
            }
            Exit-Shell $second
        }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { throw 'Process did not exit' }
        if ($process.ExitCode -ne 0) { throw "Exit code $($process.ExitCode)" }
        if (Select-String -LiteralPath "$prefix.stderr.log" -Pattern 'Segmentation fault|panic:|leaked:' -Quiet) { throw 'Crash or allocation leak in stderr' }
    } catch { $failure = $_.Exception.Message }
    finally {
        if ($null -ne $process -and -not $process.HasExited) {
            # Exit only this scenario's probe shells; never touch user terminals.
            foreach ($marker in Get-ChildItem -LiteralPath $directory -Filter 'shell-*') {
                if ($marker.Name -match '^shell-([0-9]+)$') { Exit-Shell ('Modal probe ' + $Matches[1]) }
            }
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                Stop-Process -Id $process.Id -Force
                $process.WaitForExit()
                $forced = $true
            }
        }
        $results += [pscustomobject]@{
            Case = $scenario; Passed = ($null -eq $failure); Failure = $failure
            ProcessId = $(if ($null -ne $process) { $process.Id } else { $null })
            ExitCode = $(if ($null -ne $process -and $process.HasExited) { $process.ExitCode } else { $null })
            ForcedTermination = $forced; Stderr = "$prefix.stderr.log"
        }
    }
}
$summary = [pscustomobject]@{ Executable = $exe; SHA256 = (Get-FileHash -LiteralPath $exe).Hash; Results = $results; Fixture = $fixture }
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $logs "$name.json") -Encoding utf8
$results | Format-Table -AutoSize
if (@($results | Where-Object { -not $_.Passed }).Count -gt 0) { throw "Modal action regression failed; see $logs/$name.json" }
