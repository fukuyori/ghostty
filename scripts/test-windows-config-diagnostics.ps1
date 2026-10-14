<#
.SYNOPSIS
Checks configuration diagnostics across reloads and window/shell closure.
.DESCRIPTION
Starts dedicated processes with isolated configs. Keyboard and close messages
are synthetic. Saves JSON, stderr, and a dialog capture under zig-out/logs;
retains the inputs under zig-out/test-fixtures. Existing windows are untouched.
An invalid configuration is intentional: the test checks its diagnostic UI.
.EXAMPLE
./scripts/test-windows-config-diagnostics.ps1 -Executable zig-out/bin/ghostty.exe
#>
[CmdletBinding()]
param(
    [string]$Executable = 'zig-out/bin/ghostty.exe',
    [ValidateSet('StartupClose', 'ReloadClose', 'ReloadDismiss', 'RepeatedReload',
        'QueuedOwnerClose', 'OwnerCloseWithOtherWindow', 'ShellExit', 'PaletteReloadClose')]
    [string[]]$Case = @('StartupClose', 'ReloadClose', 'ReloadDismiss', 'RepeatedReload',
        'QueuedOwnerClose', 'OwnerCloseWithOtherWindow', 'ShellExit', 'PaletteReloadClose'),
    [ValidateRange(1, 60)][int]$TimeoutSeconds = 15
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = if ([IO.Path]::IsPathRooted($Executable)) {
    (Resolve-Path -LiteralPath $Executable).Path
} else {
    (Resolve-Path -LiteralPath (Join-Path $root $Executable)).Path
}
$name = 'config-diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$logs = Join-Path $root 'zig-out/logs'
$fixture = Join-Path $root "zig-out/test-fixtures/$name"
$null = New-Item -ItemType Directory -Force -Path $logs, $fixture
Add-Type -AssemblyName System.Drawing
if (-not ('GhosttyDiagnosticNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class GhosttyDiagnosticNative {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc f, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageTimeoutW")]
    static extern IntPtr ReadText(IntPtr h, uint msg, UIntPtr w, StringBuilder s, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, UIntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public static string Class(IntPtr h) { var s=new StringBuilder(256); GetClassNameW(h,s,256); return s.ToString(); }
    public static string Text(IntPtr h) { var s=new StringBuilder(4096); UIntPtr result; if(ReadText(h,0xD,new UIntPtr(4096),s,2,2000,out result)==IntPtr.Zero) throw new Exception("Window text timed out"); return s.ToString(); }
    public static IntPtr[] Windows(uint pid, string cls) { var list=new List<IntPtr>(); EnumWindows((h,p)=>{ uint n; GetWindowThreadProcessId(h,out n); if(n==pid && Class(h)==cls) list.Add(h); return true; },IntPtr.Zero); return list.ToArray(); }
    public static IntPtr[] Children(IntPtr parent, string cls) { var list=new List<IntPtr>(); EnumChildWindows(parent,(h,p)=>{ if(Class(h)==cls) list.Add(h); return true; },IntPtr.Zero); return list.ToArray(); }
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
    if (-not [GhosttyDiagnosticNative]::PostMessageW($Handle, $Message, [UIntPtr]::new($W), [IntPtr]::new($L))) {
        throw "PostMessage failed: $Message"
    }
}
function Key([IntPtr]$Handle, [int]$Code) {
    Post $Handle 0x100 $Code 1
    Post $Handle 0x101 $Code 0xC0000001L
}
function Dialogs {
    @([GhosttyDiagnosticNative]::Windows($process.Id, '#32770') | Where-Object {
        [GhosttyDiagnosticNative]::Text($_) -eq 'Ghostty Configuration Error'
    })
}
function Diagnostic-Text([IntPtr]$Dialog) {
    (@([GhosttyDiagnosticNative]::Children($Dialog, 'Static') | ForEach-Object {
        [GhosttyDiagnosticNative]::Text($_)
    }) -join "`n")
}
function Palettes {
    @([GhosttyDiagnosticNative]::Windows($process.Id, '#32770') | Where-Object {
        [GhosttyDiagnosticNative]::GetDlgItem($_, 1201) -ne [IntPtr]::Zero
    })
}
function Wait-Diagnostic([string]$Contains) {
    Wait-State "diagnostic containing $Contains" {
        $dialogs = @(Dialogs)
        $dialogs.Count -eq 1 -and (Diagnostic-Text $dialogs[0]).Contains($Contains)
    }
    return @(Dialogs)[0]
}
function Dismiss-Diagnostic([IntPtr]$Dialog) {
    # Find the actual native button; its control ID is not assumed.
    $buttons = @([GhosttyDiagnosticNative]::Children($Dialog, 'Button'))
    if ($buttons.Count -ne 1) { throw "Expected one diagnostic button, got $($buttons.Count)" }
    Post $buttons[0] 0xF5
}
function Capture([IntPtr]$Handle, [string]$Path) {
    $null = [GhosttyDiagnosticNative]::SetWindowPos($Handle, [IntPtr]::new(-1), 0, 0, 0, 0, 0x43)
    Start-Sleep -Milliseconds 250
    $rect = [GhosttyDiagnosticNative+RECT]::new()
    if (-not [GhosttyDiagnosticNative]::GetWindowRect($Handle, [ref]$rect)) { throw 'Dialog rectangle unavailable' }
    $bitmap = [Drawing.Bitmap]::new($rect.R-$rect.L, $rect.B-$rect.T)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rect.L, $rect.T, 0, 0, $bitmap.Size)
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Write-Config([string]$ErrorSetting = '') {
    [IO.File]::WriteAllText($config, $validConfig + "`n" + $ErrorSetting + "`n")
}
function Reload-Count {
    if (-not (Test-Path -LiteralPath $stderr)) { return 0 }
    return @(Select-String -LiteralPath $stderr -Pattern 'info: reading configuration file path=' |
        Where-Object { $_.Line.Contains($config) }).Count
}
function Reload([string]$ErrorSetting) {
    $before = Reload-Count
    Write-Config $ErrorSetting
    Key $surface 113
    Wait-State 'configuration reload read' { (Reload-Count) -gt $before }
}
$results = @()
foreach ($scenario in $Case) {
    $prefix = Join-Path $logs "$name-$scenario"
    $config = Join-Path $fixture "$scenario.config"
    $exitMarker = Join-Path $fixture "$scenario.exit"
    $stderr = "$prefix.stderr.log"
    $command = "[Console]::WriteLine('Config diagnostic regression'); while (-not [IO.File]::Exists('$($exitMarker.Replace("'", "''"))')) { Start-Sleep -Milliseconds 100 }"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $validConfig = @"
command = pwsh.exe -NoLogo -NoProfile -EncodedCommand $encoded
shell-integration = none
confirm-close-surface = false
quit-after-last-window-closed = true
window-width = 80
window-height = 20
keybind = f2=reload_config
keybind = f3=new_window
keybind = f4=close_all_windows
keybind = f5=toggle_command_palette
"@
    Write-Config $(if ($scenario -eq 'StartupClose') { 'font-size = invalid-diagnostic-test' } else { '' })
    $process = $null
    $window = [IntPtr]::Zero
    $forced = $false
    $failure = $null
    try {
        $process = Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList @('--config-default-files=false', "--config-file=`"$config`"") -PassThru -RedirectStandardOutput "$prefix.stdout.log" -RedirectStandardError $stderr
        Wait-State 'main window' { [GhosttyDiagnosticNative]::Windows($process.Id, 'GhosttyWindow').Count -eq 1 }
        $window = [GhosttyDiagnosticNative]::Windows($process.Id, 'GhosttyWindow')[0]
        Wait-State 'surface' { [GhosttyDiagnosticNative]::Children($window, 'GhosttyWindow').Count -eq 1 }
        $surface = [GhosttyDiagnosticNative]::Children($window, 'GhosttyWindow')[0]
        if ($scenario -ne 'StartupClose') {
            Wait-State 'outer event loop' { Select-String -LiteralPath $stderr -Pattern 'starting Win32 event loop' -Quiet }
        }
        if ($scenario -eq 'OwnerCloseWithOtherWindow') {
            Key $surface 114
            Wait-State 'second window' { [GhosttyDiagnosticNative]::Windows($process.Id, 'GhosttyWindow').Count -eq 2 }
        }
        if ($scenario -eq 'PaletteReloadClose') {
            Key $surface 116
            Wait-State 'command palette' { @(Palettes).Count -eq 1 }
            $palette = @(Palettes)[0]
            Reload 'font-size = invalid-diagnostic-test'
            Start-Sleep -Milliseconds 200
            if (@(Dialogs).Count -ne 0) { throw 'Diagnostic nested inside palette modal loop' }
            Post $palette 0x10
        } elseif ($scenario -ne 'StartupClose') {
            Reload 'font-size = invalid-diagnostic-test'
        }
        $dialog = Wait-Diagnostic 'font-size'
        Capture $dialog "$prefix.png"
        if ($scenario -in @('RepeatedReload', 'QueuedOwnerClose', 'OwnerCloseWithOtherWindow')) {
            Reload 'cursor-style = invalid-diagnostic-test'
            Start-Sleep -Milliseconds 200
            if (@(Dialogs).Count -ne 1 -or -not (Diagnostic-Text $dialog).Contains('font-size')) {
                throw 'Reload nested or replaced the active diagnostic'
            }
        }
        switch ($scenario) {
            'RepeatedReload' {
                Dismiss-Diagnostic $dialog
                $dialog = Wait-Diagnostic 'cursor-style'
                Dismiss-Diagnostic $dialog
                Wait-State 'all diagnostics dismissed' { @(Dialogs).Count -eq 0 }
                Post $window 0x10
            }
            'ReloadDismiss' {
                Dismiss-Diagnostic $dialog
                Wait-State 'diagnostic dismissed' { @(Dialogs).Count -eq 0 }
                Reload ''
                Start-Sleep -Milliseconds 250
                if (@(Dialogs).Count -ne 0) { throw 'Valid reload showed a diagnostic' }
                Post $window 0x10
            }
            'ShellExit' { [IO.File]::WriteAllText($exitMarker, 'exit') }
            'OwnerCloseWithOtherWindow' {
                Post $window 0x10
                Wait-State 'owner closed and survivor remains' { [GhosttyDiagnosticNative]::Windows($process.Id, 'GhosttyWindow').Count -eq 1 -and -not [GhosttyDiagnosticNative]::IsWindow($window) }
                Start-Sleep -Milliseconds 250
                if (@(Dialogs).Count -ne 0) { throw 'Stale diagnostic survived its owner' }
                $survivor = [GhosttyDiagnosticNative]::Windows($process.Id, 'GhosttyWindow')[0]
                Post $survivor 0x10
            }
            default { Post $window 0x10 }
        }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { throw 'Process did not exit' }
        if ($process.ExitCode -ne 0) { throw "Exit code $($process.ExitCode)" }
        if (Select-String -LiteralPath $stderr -Pattern 'Segmentation fault|panic:|leaked:' -Quiet) { throw 'Crash or allocation leak in stderr' }
    } catch {
        $failure = $_.Exception.Message
    } finally {
        if ($null -ne $process -and -not $process.HasExited) {
            foreach ($owned in [GhosttyDiagnosticNative]::Windows($process.Id, 'GhosttyWindow')) {
                $null = [GhosttyDiagnosticNative]::PostMessageW($owned, 0x10, [UIntPtr]::Zero, [IntPtr]::Zero)
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
            ForcedTermination = $forced; Stderr = $stderr; Capture = "$prefix.png"
        }
    }
}
$summary = [pscustomobject]@{
    Executable = $exe; SHA256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    Results = $results; Fixture = $fixture
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $logs "$name.json") -Encoding utf8
$summary
if (@($results | Where-Object { -not $_.Passed }).Count -gt 0) {
    throw "Configuration diagnostic regression failed; see $logs/$name.json"
}
