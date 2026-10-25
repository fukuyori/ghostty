<#
.SYNOPSIS
Checks Win32 creation rollback and IPC UI timeout on a test-hook build.
.DESCRIPTION
Requires -Dwin32-test-hooks=true. Enables GHOSTTY_TEST_LIFECYCLE only in
dedicated child processes, saves JSON and stderr, and never uses user config.
Each injected failure must preserve native HWNDs, ownership/tree state and
focus, allow a later successful creation, and exit without allocator leaks.
IPC checks cover late completion, a failed late creation, and shutdown both
before and after the real five-second UI timeout.
Use -CaptureWindows on an accessible desktop to save representative images;
a capture failure fails the case instead of silently claiming visual coverage.
.PARAMETER SummaryPath
Optional JSON output path for a caller collecting multiple checks. Relative
paths are resolved from the repository root; the default is timestamped.
.EXAMPLE
zig build -Dwin32-test-hooks=true --prefix zig-out/lifecycle-hooks
./scripts/test-windows-lifecycle.ps1 -Executable zig-out/lifecycle-hooks/bin/ghostty.exe
#>
[CmdletBinding()]
param(
    [string]$Executable = '',
    [ValidateSet('All', 'Rollback', 'Ipc', 'HooksDisabled')][string]$Area = 'All',
    [string]$CaseFilter = '',
    [switch]$CaptureWindows,
    [string]$SummaryPath = '',
    [int]$TimeoutSeconds = 20
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'windows-brand.ps1')
if (-not $Executable) {
    $defaultPrefix = Join-Path $root 'zig-out/lifecycle-hooks'
    $Executable = Get-GhosttyBrandExecutable -Prefix $defaultPrefix -Brand (Get-GhosttyBrandForPrefix -Prefix $defaultPrefix -RepositoryRoot $root)
}
$exe = if ([IO.Path]::IsPathRooted($Executable)) { (Resolve-Path $Executable).Path } else { (Resolve-Path (Join-Path $root $Executable)).Path }
$brand = Get-GhosttyBrandForExecutable -Executable $exe -RepositoryRoot $root
$windowClass = $brand.window_class_prefix + 'Window'
$lifecycleVariable = $brand.env_prefix + 'TEST_LIFECYCLE'
$surfaceIdVariable = $brand.env_prefix + 'SURFACE_ID'
$name = 'lifecycle-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$fixture = Join-Path $root "zig-out/test-fixtures/$name"
$logs = Join-Path $root 'zig-out/logs'
$null = New-Item -ItemType Directory -Force -Path $fixture, $logs
$summaryPath = if (-not $SummaryPath) {
    Join-Path $logs "$name.json"
} elseif ([IO.Path]::IsPathRooted($SummaryPath)) {
    $SummaryPath
} else {
    Join-Path $root $SummaryPath
}
$results = [Collections.Generic.List[object]]::new()
$trackedChildren = @{}
Add-Type -AssemblyName System.Drawing
$testMessage = 0x400 + 112
if (-not ('GhosttyLifecycleNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class GhosttyLifecycleNative {
    // Set from brand.json before the first lookup.
    public static string SurfaceClass, TabBarClass;
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int L,T,R,B; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect rect);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Rect rect);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref Point point);
    public static int[] PaneInsets(IntPtr parent, IntPtr pane) {
        Rect client, child; var origin = new Point();
        if (!GetClientRect(parent,out client) || !ClientToScreen(parent,ref origin) || !GetWindowRect(pane,out child))
            throw new Exception("Fallback geometry unavailable");
        return new int[] { child.L-origin.X, child.T-origin.Y,
            origin.X+client.R-child.R, origin.Y+client.B-child.B };
    }
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct ProcessEntry {
        public uint Size, Usage, Id; public UIntPtr Heap; public uint Module, Threads, Parent;
        public int Priority; public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string Name;
    }
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    public static uint[] Descendants(uint root, long rootStartedUtcTicks) {
        var snapshot=CreateToolhelp32Snapshot(2,0);
        if(snapshot==new IntPtr(-1))throw new Exception("Process snapshot failed: " + Marshal.GetLastWin32Error());
        try {
            var entries=new List<ProcessEntry>(); var entry=new ProcessEntry(); entry.Size=(uint)Marshal.SizeOf(entry);
            if(!Process32FirstW(snapshot,ref entry))throw new Exception("Process enumeration failed");
            do { entries.Add(entry); } while(Process32NextW(snapshot,ref entry));
            var ids=new HashSet<uint>(); ids.Add(root); bool changed;
            do {
                changed=false;
                foreach(var e in entries)if(ids.Contains(e.Parent) && !ids.Contains(e.Id)) {
                    // Parent PIDs in Toolhelp may refer to exited processes.
                    // Do not adopt older processes when a test PID is reused.
                    try {
                        using(var process=System.Diagnostics.Process.GetProcessById((int)e.Id)) {
                            if(process.StartTime.ToUniversalTime().Ticks < rootStartedUtcTicks)continue;
                        }
                    } catch(ArgumentException) { continue; }
                    ids.Add(e.Id); changed=true;
                }
            } while(changed);
            ids.Remove(root); var result=new uint[ids.Count]; ids.CopyTo(result); return result;
        } finally { CloseHandle(snapshot); }
    }
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc f, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, UIntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, UIntPtr w, IntPtr l, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
    public static string Class(IntPtr h) { var s=new StringBuilder(256); GetClassNameW(h,s,256); return s.ToString(); }
    public static long Send(IntPtr h, uint m, ulong w, long l) {
        UIntPtr result;
        if (SendMessageTimeoutW(h,m,new UIntPtr(w),new IntPtr(l),2,15000,out result)==IntPtr.Zero) throw new Exception("SendMessageTimeout failed");
        return unchecked((long)result.ToUInt64());
    }
    public static IntPtr[] Windows(uint pid, string cls) {
        var list=new List<IntPtr>();
        EnumWindows((h,p)=>{uint id; GetWindowThreadProcessId(h,out id); if(id==pid && Class(h)==cls)list.Add(h); return true;},IntPtr.Zero);
        return list.ToArray();
    }
    public static IntPtr[] Children(IntPtr parent) {
        var list=new List<IntPtr>();
        EnumChildWindows(parent,(h,p)=>{if(Class(h)==SurfaceClass && IsWindowVisible(h))list.Add(h); return true;},IntPtr.Zero);
        return list.ToArray();
    }
    public static string Handles(uint pid) {
        var list=new SortedSet<long>();
        EnumProc add=(h,p)=>{uint id; GetWindowThreadProcessId(h,out id); if(id==pid)list.Add(h.ToInt64()); return true;};
        EnumWindows((h,p)=>{uint id; GetWindowThreadProcessId(h,out id); if(id==pid){add(h,p);EnumChildWindows(h,add,IntPtr.Zero);} return true;},IntPtr.Zero);
        return String.Join(",",list);
    }
    public static int TabBars(uint pid) {
        // Tab bars are owned popups, not WS_CHILD windows.
        return Windows(pid,TabBarClass).Length;
    }
}
'@
}
[GhosttyLifecycleNative]::SurfaceClass = $windowClass
[GhosttyLifecycleNative]::TabBarClass = $brand.window_class_prefix + 'TabBar'
function Control([int]$Op, [long]$Value = 0) {
    [GhosttyLifecycleNative]::Send($script:window, $testMessage, $Op, $Value)
}
function Wait-State([string]$Label, [scriptblock]$Check) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $Check) { return }
        if ($script:process.HasExited) { throw "Process exited $($script:process.ExitCode): $Label" }
        Start-Sleep -Milliseconds 50
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Timed out: $Label"
}
function Key([int]$VirtualKey) {
    $pane = [IntPtr]::new((Control 11))
    if ($pane -eq [IntPtr]::Zero) { $pane = @([GhosttyLifecycleNative]::Children($script:window))[0] }
    if (-not [GhosttyLifecycleNative]::PostMessageW($pane,0x100,[UIntPtr]::new($VirtualKey),[IntPtr]::new(1))) { throw 'Key down failed' }
    $null = [GhosttyLifecycleNative]::PostMessageW($pane,0x101,[UIntPtr]::new($VirtualKey),[IntPtr]::new(0xC0000001L))
}
function Snapshot {
    Track-Children
    [ordered]@{
        CoreSurfaces = Control 2; Windows = Control 3; Tabs = Control 4
        Valid = Control 6; Fingerprint = Control 7
        FocusHwnd = Control 11; ActiveTab = Control 12
        FocusedPane = Control 13; Zoomed = Control 14
        Handles = [GhosttyLifecycleNative]::Handles($script:process.Id)
    }
}
function Track-Children {
    if ($null -eq $script:process) { return }
    foreach ($childId in [GhosttyLifecycleNative]::Descendants($script:process.Id, $script:process.StartTime.ToUniversalTime().Ticks)) {
        $child = Get-Process -Id $childId -ErrorAction SilentlyContinue
        if ($null -ne $child -and $null -ne $child.StartTime) {
            $trackedChildren[[int]$childId] = $child.StartTime.ToUniversalTime().Ticks
        }
    }
}
function Capture-Window([IntPtr]$Handle = $script:window) {
    $null = [GhosttyLifecycleNative]::SetWindowPos($Handle,[IntPtr]::new(-1),0,0,0,0,0x13)
    Start-Sleep -Milliseconds 200
    $rect = New-Object GhosttyLifecycleNative+Rect
    if (-not [GhosttyLifecycleNative]::GetWindowRect($Handle,[ref]$rect)) { throw 'Screenshot rectangle unavailable' }
    $bitmap = [Drawing.Bitmap]::new($rect.R-$rect.L,$rect.B-$rect.T)
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try { $graphics.CopyFromScreen($rect.L,$rect.T,0,0,$bitmap.Size) } finally { $graphics.Dispose() }
        $bitmap.Save("$script:prefix.png",[Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
    return "$script:prefix.png"
}
function Start-Case([string]$Label) {
    $script:directory = Join-Path $fixture $Label
    $null = New-Item -ItemType Directory -Force -Path $script:directory
    $script:prefix = Join-Path $logs "$name-$Label"
    $probe = Join-Path $script:directory 'probe.ps1'
    @'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot ("shell-$PID.txt")), "$PID")
[Console]::Write(([char]27).ToString() + ']2;Lifecycle ready' + [char]7)
[Console]::WriteLine("Lifecycle pane $PID - creation/rollback probe")
while ($true) { $null = [Console]::ReadLine() }
'@ | Set-Content -LiteralPath $probe -Encoding utf8
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("& '$($probe.Replace("'", "''"))'"))
    $config = Join-Path $script:directory 'config'
    @"
command = pwsh.exe -NoLogo -NoProfile -EncodedCommand $encoded
shell-integration = none
confirm-close-surface = false
quit-after-last-window-closed = true
window-width = 80
window-height = 24
window-show-tab-bar = always
window-new-tab-position = end
keybind = f2=new_window
keybind = f3=new_tab
keybind = f4=new_split:right
keybind = f5=goto_tab:1
keybind = f6=goto_split:previous
keybind = f7=toggle_split_zoom
keybind = f9=close_surface
keybind = f10=close_all_windows
"@ | Set-Content -LiteralPath $config -Encoding utf8
    $script:process = Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList @('--config-default-files=false', "--config-file=`"$config`"") -Environment @{ $lifecycleVariable = '1' } -PassThru -RedirectStandardOutput "$script:prefix.stdout.log" -RedirectStandardError "$script:prefix.stderr.log"
    Wait-State 'main window' { [GhosttyLifecycleNative]::Windows($script:process.Id,$windowClass).Count -eq 1 }
    $script:window = [GhosttyLifecycleNative]::Windows($script:process.Id,$windowClass)[0]
    $expectedProbe = if ($Area -eq 'HooksDisabled') { 0 } else { 0x47484c54 }
    if ((Control 0) -ne $expectedProbe) { throw "Unexpected lifecycle hook probe (expected $expectedProbe)" }
    Wait-State 'initial shell' { @(Get-ChildItem $script:directory -Filter 'shell-*.txt').Count -eq 1 }
    $null = [GhosttyLifecycleNative]::ShowWindow($script:window, 9)
    $null = [GhosttyLifecycleNative]::SetForegroundWindow($script:window)
    Wait-State 'visible pane' { @([GhosttyLifecycleNative]::Children($script:window)).Count -ge 1 }
    if ($Label.StartsWith('ipc-') -and (Select-String -LiteralPath "$script:prefix.stderr.log" -Pattern 'IPC service unavailable' -Quiet)) { throw 'Test server does not own the IPC endpoint; close the other Debug instance before this check' }
    if ($Area -ne 'HooksDisabled') { Wait-State 'valid ownership' { (Control 6) -eq 1 } }
}
function Finish-Case($Result) {
    if ($null -ne $script:process) {
        Track-Children
        if (-not $script:process.HasExited) {
            foreach ($h in [GhosttyLifecycleNative]::Windows($script:process.Id,$windowClass)) {
                $null = [GhosttyLifecycleNative]::PostMessageW($h,0x10,[UIntPtr]::Zero,[IntPtr]::Zero)
            }
            if (-not $script:process.WaitForExit($TimeoutSeconds * 1000)) {
                Stop-Process -Id $script:process.Id -Force
                $script:process.WaitForExit()
                $Result.ForcedTermination = $true
            }
        }
        $Result.ExitCode = $script:process.ExitCode
        $Result.CrashOrLeak = [bool](Select-String -LiteralPath "$script:prefix.stderr.log" -Pattern 'panic:|Segmentation fault|leaked:|reached unreachable|assertion failure' -Quiet)
        $Result.Stderr = "$script:prefix.stderr.log"
    }
    $Result.Passed = $null -eq $Result.Failure -and $Result.ExitCode -eq 0 -and -not $Result.ForcedTermination -and -not $Result.CrashOrLeak
    $results.Add([pscustomobject]$Result)
    Save-Summary
    Write-Host "$($Result.Case): Passed=$($Result.Passed) $($Result.Failure)"
}
function Save-Summary {
    [ordered]@{ Executable = $exe; SHA256 = (Get-FileHash $exe).Hash; Results = @($results.ToArray()) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
}
$points = [ordered]@{ parent_hwnd=1; child_hwnd=2; tab_bar_hwnd=3; surface_init=4; window_init=5; window_append=6; tab_insert=7; split_insert=8; core_alloc=9; core_register=10; core_config=11; core_init=12; core_ready=13; scrollbar_ready=14; window_owned=15; tab_owned=16; split_owned=17 }
if ($Area -in 'All','Rollback') {
    foreach ($action in 'window','tab','split') {
        $actionPoints = switch ($action) {
            window { @('parent_hwnd','child_hwnd','surface_init','window_init','window_append','window_owned','core_alloc','core_register','core_config','core_init','core_ready','scrollbar_ready','tab_bar_hwnd') }
            tab { @('child_hwnd','surface_init','tab_insert','tab_owned','core_alloc','core_register','core_config','core_init','core_ready','scrollbar_ready') }
            split { @('child_hwnd','surface_init','split_insert','split_owned','core_alloc','core_register','core_config','core_init','core_ready','scrollbar_ready') }
        }
        foreach ($point in $actionPoints) {
            $label = "$action-$point"
            if ($CaseFilter -and $label -notlike $CaseFilter) { continue }
            $script:process = $null
            $result = [ordered]@{ Case=$label; Failure=$null; ExitCode=$null; ForcedTermination=$false; CrashOrLeak=$false }
            try {
                Start-Case $label
                # Keep multiple existing tabs and panes; rollback must restore
                # the original active tab, not merely select any surviving tab.
                Key 114; Wait-State 'second tab' { (Control 4) -eq 2 }
                Key 114; Wait-State 'third tab' { (Control 4) -eq 3 }
                Key 116; Wait-State 'first tab selected' { (Control 12) -eq 0 }
                Key 115; Wait-State 'existing split' { (Control 2) -eq 4 }
                Key 117
                Start-Sleep -Milliseconds 100
                Key 118; Wait-State 'existing split zoomed' { (Control 14) -ne 0 }
                Wait-State 'baseline shells' { @(Get-ChildItem $script:directory -Filter 'shell-*.txt').Count -eq 4 }
                Start-Sleep -Milliseconds 200
                $before = Snapshot
                $beforeTabBars = [GhosttyLifecycleNative]::TabBars($script:process.Id)
                if ($before.Valid -ne 1) { throw 'Invalid baseline' }
                $null = Control 1 $points[$point]
                $vk = switch ($action) { window {113} tab {114} split {115} }
                Key $vk
                Wait-State 'failure injected' { (Control 5) -eq 1 }
                $after = Snapshot
                $result.Before = $before; $result.After = $after
                if ($point -eq 'tab_bar_hwnd') {
                    if ($after.Windows -ne $before.Windows + 1 -or $after.CoreSurfaces -ne $before.CoreSurfaces + 1 -or $after.Valid -ne 1) { throw 'Tab-bar failure did not degrade to a usable window' }
                    if ([GhosttyLifecycleNative]::TabBars($script:process.Id) -ne $beforeTabBars) { throw 'Failed tab bar unexpectedly exists' }
                    $result.TabBarFallback = $true
                    $fallback = @([GhosttyLifecycleNative]::Windows($script:process.Id,$windowClass) | Where-Object { $_ -ne $script:window })
                    if ($fallback.Count -ne 1) { throw 'Expected exactly one fallback window' }
                    $panes = @([GhosttyLifecycleNative]::Children($fallback[0]))
                    if ($panes.Count -ne 1) { throw 'Expected one visible fallback pane' }
                    $result.FallbackPaneInsets = [GhosttyLifecycleNative]::PaneInsets($fallback[0],$panes[0])
                    if (@($result.FallbackPaneInsets | Where-Object { $_ -ne 0 }).Count) { throw 'Fallback pane does not fill the client area' }
                    if ($CaptureWindows) {
                        Wait-State 'fallback shell ready' { @(Get-ChildItem $script:directory -Filter 'shell-*.txt').Count -eq $before.CoreSurfaces + 1 }
                        $result.CaptureStage = 'tab-bar-fallback-before-retry'
                        $result.Screenshot = Capture-Window $fallback[0]
                    }
                    Key $vk
                    Wait-State 'later window with tab bar' { (Control 3) -eq $before.Windows + 2 }
                    if ((Control 6) -ne 1 -or (Control 5) -ne 1 -or [GhosttyLifecycleNative]::TabBars($script:process.Id) -ne $beforeTabBars + 1) { throw 'Tab bar did not recover on retry' }
                    $result.LaterCreationSucceeded = $true
                } else {
                    if (($before | ConvertTo-Json -Compress) -cne ($after | ConvertTo-Json -Compress)) { throw 'Rollback changed HWNDs, ownership, split tree or focus' }
                    if (-not (Select-String -LiteralPath "$script:prefix.stderr.log" -SimpleMatch "key binding action failed action=new_$action err=error.TestLifecycleFailure" -Quiet)) { throw 'Creation action did not report the injected failure' }
                    if ($CaptureWindows -and $point -eq 'core_ready') {
                        $result.CaptureStage = 'rollback-before-retry'
                        $result.Screenshot = Capture-Window
                    }
                    Key $vk
                    Wait-State 'later creation' { (Control 2) -eq $before.CoreSurfaces + 1 }
                    if ((Control 6) -ne 1 -or (Control 5) -ne 1) { throw 'Invalid state after retry' }
                    $result.LaterCreationSucceeded = $true
                }
                Key 121
                if (-not $script:process.WaitForExit($TimeoutSeconds * 1000)) { throw 'Normal close-all did not exit' }
            } catch { $result.Failure = $_.Exception.Message; $result.ErrorPosition = $_.ScriptStackTrace } finally { Finish-Case $result }
        }
    }
}
if ($Area -in 'All','Ipc') {
    foreach ($mode in 'late-success','late-failure','shutdown-before-timeout','shutdown-after-timeout') {
        $label = "ipc-$mode"
        if ($CaseFilter -and $label -notlike $CaseFilter) { continue }
        $script:process = $null
        $client = $null
        $result = [ordered]@{ Case=$label; Failure=$null; ExitCode=$null; ForcedTermination=$false; CrashOrLeak=$false }
        try {
            Start-Case $label
            $before = Snapshot
            $null = Control 8 1
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $client = Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList '+new-tab' -Environment @{$surfaceIdVariable='0'} -PassThru -RedirectStandardError "$script:prefix.client.stderr.log" -RedirectStandardOutput "$script:prefix.client.stdout.log"
            Wait-State 'held IPC request' { (Control 9) -eq 1 }
            if ($mode -eq 'shutdown-before-timeout') {
                $result.ShutdownRequestedSeconds = $watch.Elapsed.TotalSeconds
                if ($result.ShutdownRequestedSeconds -ge 4.5) { throw 'Missed pre-timeout shutdown window' }
                Key 121
            } else {
                if (-not $client.WaitForExit(12000)) { throw 'IPC client did not time out' }
                $result.TimeoutSeconds = $watch.Elapsed.TotalSeconds
                $message = Get-Content "$script:prefix.client.stderr.log" -Raw
                if ($client.ExitCode -eq 0 -or $message -notmatch 'completion unknown; the tab may be created later') { throw "Wrong IPC timeout response: $message" }
                if ($result.TimeoutSeconds -lt 4.5) { throw 'Did not exercise the real 5s timeout' }
                if ((Control 9) -ne 1 -or (Control 10) -ne 1 -or (Control 2) -ne $before.CoreSurfaces) { throw 'Timed-out request ownership or tab count is wrong' }
                if ($mode -eq 'shutdown-after-timeout') {
                    Key 121
                } else {
                    if ($mode -eq 'late-failure') { $null = Control 1 13 }
                    $null = Control 8 0
                    Wait-State 'request released' { (Control 9) -eq 0 -and (Control 10) -eq 0 }
                    $expected = $before.CoreSurfaces + $(if ($mode -eq 'late-success') {1} else {0})
                    if ((Control 2) -ne $expected -or (Control 6) -ne 1) { throw 'Late completion left invalid state' }
                    $result.LateSurfaces = Control 2
                    # A subsequent real IPC request must still succeed.
                    $retry = Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList '+new-tab' -Environment @{$surfaceIdVariable='0'} -PassThru -RedirectStandardError "$script:prefix.retry.stderr.log" -RedirectStandardOutput "$script:prefix.retry.stdout.log"
                    if (-not $retry.WaitForExit(12000) -or $retry.ExitCode -ne 0) { throw 'Subsequent IPC request failed' }
                    Wait-State 'retry tab and release' { (Control 2) -eq $expected + 1 -and (Control 10) -eq 0 }
                    $result.SubsequentIpcSucceeded = $true
                    Key 121
                }
            }
            if (-not $script:process.WaitForExit($TimeoutSeconds * 1000)) { throw 'IPC server did not exit normally' }
            if (-not $client.WaitForExit(12000)) { throw 'IPC client did not exit at shutdown' }
            if ($client.ExitCode -eq 0) { throw 'Held request unexpectedly reported success' }
            $result.ClientExitCode = $client.ExitCode
            $result.ClientStderr = Get-Content "$script:prefix.client.stderr.log" -Raw
            if (-not (Select-String "$script:prefix.stderr.log" -Pattern 'IPC test requests remaining=0' -Quiet)) { throw 'Missing IPC cleanup evidence' }
        } catch { $result.Failure = $_.Exception.Message; $result.ErrorPosition = $_.ScriptStackTrace } finally {
            Finish-Case $result
            if ($null -ne $client -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force }
        }
    }
}
if ($Area -eq 'HooksDisabled') {
    $script:process = $null
    $result = [ordered]@{ Case='hooks-disabled'; Failure=$null; ExitCode=$null; ForcedTermination=$false; CrashOrLeak=$false }
    try {
        Start-Case 'hooks-disabled'
        if ((Control 1 13) -ne 0 -or (Control 8 1) -ne 0) { throw 'Non-hook build accepted test controls' }
        Key 114
        Wait-State 'normal tab with test environment set' { @(Get-ChildItem $script:directory -Filter 'shell-*.txt').Count -eq 2 }
        $result.ControlsIgnored = $true
        Key 121
        if (-not $script:process.WaitForExit($TimeoutSeconds * 1000)) { throw 'Normal close-all did not exit' }
    } catch { $result.Failure = $_.Exception.Message; $result.ErrorPosition = $_.ScriptStackTrace } finally { Finish-Case $result }
}
if ($results.Count -eq 0) { throw 'No cases selected' }
# Match fixture shell PIDs and observed descendant start times; exit 0 of the
# parent alone is not evidence of child cleanup.
$shellIds = @(Get-ChildItem $fixture -Recurse -Filter 'shell-*.txt' | ForEach-Object { [int]([IO.File]::ReadAllText($_.FullName)) })
function Find-Leftovers {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.ProcessName -eq $brand.exe_name -and $_.Path -eq $exe) -or
        ($_.ProcessName -eq 'pwsh' -and $_.Id -in $shellIds) -or
        ($trackedChildren.ContainsKey($_.Id) -and $null -ne $_.StartTime -and $_.StartTime.ToUniversalTime().Ticks -eq $trackedChildren[$_.Id])
    } | Select-Object Id, ProcessName
}
# ConPTY's console host may finish just after the GUI process exits. Wait
# within the same timeout, without terminating children or hiding the first scan.
$cleanupWatch = [Diagnostics.Stopwatch]::StartNew()
$initialLeftovers = @(Find-Leftovers)
$leftovers = $initialLeftovers
while ($leftovers.Count -and $cleanupWatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    Start-Sleep -Milliseconds 100
    $leftovers = @(Find-Leftovers)
}
$summary = Get-Content $summaryPath -Raw | ConvertFrom-Json
$summary | Add-Member -NotePropertyName Leftovers -NotePropertyValue $leftovers
$summary | Add-Member -NotePropertyName InitialLeftovers -NotePropertyValue $initialLeftovers
$summary | Add-Member -NotePropertyName CleanupSeconds -NotePropertyValue $cleanupWatch.Elapsed.TotalSeconds
$summary | Add-Member -NotePropertyName ObservedChildProcessCount -NotePropertyValue $trackedChildren.Count
$summary | ConvertTo-Json -Depth 8 | Set-Content $summaryPath -Encoding utf8
Write-Host "Summary: $summaryPath"
if (@($results | Where-Object { -not $_.Passed }).Count -or $leftovers.Count) { throw 'Lifecycle regression failed; see saved JSON and stderr' }
