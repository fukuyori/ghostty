<#
.SYNOPSIS
Checks blank-row context menus and preserves word/existing selections.
.DESCRIPTION
Starts a dedicated Ghostty, sends mouse input through SendInput, inspects
the native menu and selected text through search_selection, and saves PNGs.
Does not use or alter the clipboard. Physical user acceptance is separate.
#>
[CmdletBinding()]
param([string]$Executable = 'zig-out/blank-context/bin/ghostty.exe')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = (Resolve-Path (Join-Path $root $Executable)).Path
$name = 'blank-context-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
# Retain reproduction inputs outside the window-state/soak cleanup area.
$state = Join-Path $root "zig-out/test-fixtures/$name"
$logs = Join-Path $root 'zig-out/logs'
$null = New-Item -ItemType Directory -Force -Path $state, $logs
Add-Type -AssemblyName System.Drawing
if (-not ('GhosttyContextNative' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class GhosttyContextNative {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MI { public int X,Y; public uint Data,Flags,Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint Type; public MI Mouse; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc f, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="SendMessageW")] static extern IntPtr ReadText(IntPtr h,uint m,UIntPtr w,StringBuilder s);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h,uint m,UIntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,UIntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h,int id);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu,uint id,uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    public static string Class(IntPtr h) { var s=new StringBuilder(256); GetClassNameW(h,s,256); return s.ToString(); }
    public static string Text(IntPtr h) { var s=new StringBuilder(4096); ReadText(h,13,new UIntPtr(4096),s); return s.ToString(); }
    public static IntPtr[] Find(uint pid,string cls,IntPtr parent) { var a=new List<IntPtr>(); EnumProc cb=(h,p)=>{ uint id; GetWindowThreadProcessId(h,out id); if(id==pid && Class(h)==cls) a.Add(h); return true; }; if(parent==IntPtr.Zero) EnumWindows(cb,IntPtr.Zero); else EnumChildWindows(parent,cb,IntPtr.Zero); return a.ToArray(); }
    // SendInput uses physical buttons; the checks use logical left/right.
    public static void Mouse(uint flags) { if(GetSystemMetrics(23)!=0) flags=flags==2?8u:flags==4?16u:flags==8?2u:flags==16?4u:flags; var a=new[]{new INPUT { Mouse=new MI { Flags=flags } }}; if(SendInput(1,a,Marshal.SizeOf(typeof(INPUT)))!=1) throw new Exception("SendInput failed"); }
}
'@
}
function Wait-State([string]$Description,[scriptblock]$Check) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $Check) { return }
        if ($process.HasExited) { throw "Process exited: $Description" }
        Start-Sleep -Milliseconds 80
    } while ($timer.Elapsed.TotalSeconds -lt 15)
    throw "Timed out: $Description"
}
function Key([IntPtr]$Handle,[int]$Code) {
    $null = [GhosttyContextNative]::PostMessageW($Handle,0x100,[UIntPtr]::new($Code),[IntPtr]::new(1))
    $null = [GhosttyContextNative]::PostMessageW($Handle,0x101,[UIntPtr]::new($Code),[IntPtr]::new(0xC0000001L))
}
function Point([int]$Col,[int]$Row) {
    # The fixture uses an exact 80x20 grid, zero padding, and no tab bar.
    $r = [GhosttyContextNative+RECT]::new()
    $null = [GhosttyContextNative]::GetWindowRect($surface,[ref]$r)
    $null = [GhosttyContextNative]::SetCursorPos(($r.L + [int](($Col + 0.5) * ($r.R - $r.L) / 80)),($r.T + [int](($Row + 0.5) * ($r.B - $r.T) / 20)))
    Start-Sleep -Milliseconds 90
    $point = [GhosttyContextNative+POINT]::new()
    $null = [GhosttyContextNative]::GetCursorPos([ref]$point)
    if ([GhosttyContextNative]::WindowFromPoint($point) -ne $surface) { throw 'Test surface is obscured; refusing mouse input to another window' }
}
function Click([int]$Col,[int]$Row,[bool]$Right) {
    Point $Col $Row
    [GhosttyContextNative]::Mouse($(if ($Right) { 8 } else { 2 }))
    [GhosttyContextNative]::Mouse($(if ($Right) { 16 } else { 4 }))
}
function Capture([string]$Suffix) {
    $r = [GhosttyContextNative+RECT]::new()
    $null = [GhosttyContextNative]::GetWindowRect($window,[ref]$r)
    $bitmap = [Drawing.Bitmap]::new(($r.R - $r.L),($r.B - $r.T))
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try { $graphics.CopyFromScreen($r.L,$r.T,0,0,$bitmap.Size) } finally { $graphics.Dispose() }
        $bitmap.Save((Join-Path $logs "$name-$Suffix.png"),[Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
}
function Check-Menu([bool]$Selected,[string]$Screenshot) {
    Wait-State 'context menu visible' { [GhosttyContextNative]::Find($process.Id,'#32768',[IntPtr]::Zero).Count -gt 0 }
    $menuWindow = [GhosttyContextNative]::Find($process.Id,'#32768',[IntPtr]::Zero)[0]
    $menu = [GhosttyContextNative]::SendMessageW($menuWindow,0x1E1,[UIntPtr]::Zero,[IntPtr]::Zero)
    $flags = [GhosttyContextNative]::GetMenuState($menu,1,0)
    if ($flags -eq [uint32]::MaxValue) { throw 'Unable to inspect Copy menu item' }
    if ((($flags -band 3) -eq 0) -ne $Selected) { throw "Copy selection state mismatch: expected=$Selected flags=$flags" }
    Start-Sleep -Milliseconds 150
    Capture $Screenshot
    Key $menuWindow 27
    Wait-State 'context menu dismissed' { [GhosttyContextNative]::Find($process.Id,'#32768',[IntPtr]::Zero).Count -eq 0 }
}
function Check-Selection([string]$Expected) {
    Key $surface 114 # F3 = search_selection; no clipboard access.
    Wait-State 'selection search visible' {
        $bars = [GhosttyContextNative]::Find($process.Id,'#32770',$window)
        $bars.Count -eq 1 -and [GhosttyContextNative]::IsWindowVisible($bars[0])
    }
    $bar = [GhosttyContextNative]::Find($process.Id,'#32770',$window)[0]
    $edit = [GhosttyContextNative]::GetDlgItem($bar,1101)
    $actual = [GhosttyContextNative]::Text($edit)
    if ($actual -ne $Expected) { throw "Selection changed: expected=[$Expected] actual=[$actual]" }
    Key $edit 27
    Wait-State 'selection search closed' { -not [GhosttyContextNative]::IsWindowVisible($bar) }
}
$marker = Join-Path $state 'ready'
$refresh = Join-Path $state 'refresh'
$fixture = 'function Draw { [Console]::Write("$([char]27)[2J$([char]27)[Halpha beta$([char]27)[2;1H" + ('' '' * 80) + "$([char]27)[4;1Hready"); [IO.File]::WriteAllText(''' + $marker.Replace("'","''") + ''',''ok'') }; Draw; while ($true) { if ([IO.File]::Exists(''' + $refresh.Replace("'","''") + ''')) { [IO.File]::Delete(''' + $refresh.Replace("'","''") + '''); Draw }; Start-Sleep -Milliseconds 50 }'
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($fixture))
$config = Join-Path $state 'config'
@"
command = pwsh.exe -NoLogo -NoProfile -EncodedCommand $encoded
window-width = 80
window-height = 20
window-padding-x = 0
window-padding-y = 0
window-show-tab-bar = never
confirm-close-surface = false
shell-integration = none
copy-on-select = none
right-click-action = context-menu
keybind = f3=search_selection
"@ | Set-Content -LiteralPath $config -Encoding utf8
$process = $null
$pointer = [GhosttyContextNative+POINT]::new()
$null = [GhosttyContextNative]::GetCursorPos([ref]$pointer)
try {
    Write-Verbose "Mouse buttons swapped: $([GhosttyContextNative]::GetSystemMetrics(23) -ne 0)"
    $process = Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList @('--config-default-files=false',"--config-file=`"$config`"") -PassThru -RedirectStandardOutput (Join-Path $logs "$name.stdout.log") -RedirectStandardError (Join-Path $logs "$name.stderr.log")
    Wait-State 'test window' { [GhosttyContextNative]::Find($process.Id,'GhosttyWindow',[IntPtr]::Zero).Count -eq 1 }
    $window = [GhosttyContextNative]::Find($process.Id,'GhosttyWindow',[IntPtr]::Zero)[0]
    $null = [GhosttyContextNative]::ShowWindow($window,9)
    $null = [GhosttyContextNative]::SetForegroundWindow($window)
    Wait-State 'terminal child' { [GhosttyContextNative]::Find($process.Id,'GhosttyWindow',$window).Count -eq 1 }
    $surface = [GhosttyContextNative]::Find($process.Id,'GhosttyWindow',$window)[0]
    Wait-State 'fixture output' { Test-Path -LiteralPath $marker }
    Start-Sleep -Milliseconds 700
    Click 15 1 $true
    Check-Menu $false 'spaces'
    Click 15 2 $true
    Check-Menu $false 'unwritten'
    Click 2 0 $true
    Check-Menu $true 'word'
    Check-Selection 'alpha'
    # Search reserves terminal rows. Redraw the fixture after closing it so
    # the next drag uses known coordinates, independent of ConPTY's repaint.
    [IO.File]::WriteAllText($refresh,'refresh')
    Wait-State 'fixture redraw' { -not (Test-Path -LiteralPath $refresh) }
    Start-Sleep -Milliseconds 300
    # Select both words, then right-click inside; selection must not shrink.
    Click 12 0 $false
    Point 0 0
    [GhosttyContextNative]::Mouse(2)
    Start-Sleep -Milliseconds 150
    Point 10 0
    [GhosttyContextNative]::Mouse(4)
    Start-Sleep -Milliseconds 150
    Capture 'drag-selection'
    Click 2 0 $true
    Check-Menu $true 'existing-selection'
    Check-Selection 'alpha beta'
    Click 15 10 $true
    Check-Menu $true 'blank-preserves-selection'
    Check-Selection 'alpha beta'
    $null = [GhosttyContextNative]::PostMessageW($window,0x10,[UIntPtr]::Zero,[IntPtr]::Zero)
    if (-not $process.WaitForExit(15000)) { throw 'Clean exit timed out' }
    if ($process.ExitCode -ne 0) { throw "Exit code $($process.ExitCode)" }
    $result = [ordered]@{ BlankRowsNoSelection = 'pass'; BlankRowsMenu = 'pass'; WordSelection = 'alpha'; ExistingSelection = 'alpha beta'; ExistingSelectionOnBlank = 'alpha beta'; ExitCode = $process.ExitCode; ScreenshotPrefix = (Join-Path $logs $name) }
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logs "$name.json") -Encoding utf8
    [pscustomobject]$result
} catch {
    if ($process -and -not $process.HasExited -and (Get-Variable window -ErrorAction SilentlyContinue)) { Capture 'failure' }
    throw
} finally {
    [GhosttyContextNative]::Mouse(4) # Release a drag if a check interrupted it.
    $null = [GhosttyContextNative]::SetCursorPos($pointer.X,$pointer.Y)
    if ($process -and -not $process.HasExited) {
        foreach ($h in [GhosttyContextNative]::Find($process.Id,'GhosttyWindow',[IntPtr]::Zero)) { $null = [GhosttyContextNative]::PostMessageW($h,0x10,[UIntPtr]::Zero,[IntPtr]::Zero) }
        if (-not $process.WaitForExit(5000)) { $process.Kill(); $process.WaitForExit() }
    }
}
