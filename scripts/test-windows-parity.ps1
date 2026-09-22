<#
.SYNOPSIS
Controlled native regression for OSC 7 inheritance, search, resize, and cursors.
.DESCRIPTION
Uses only dedicated test processes and configuration. Saves a search screenshot
for visual inspection. Keyboard messages are synthetic; physical IME operation
and mixed-DPI monitors still require separate checks.
#>
[CmdletBinding()]
param(
    [string]$Executable = 'zig-out/parity-d3d11/bin/ghostty.exe',
    [ValidateRange(1, 60)][int]$TimeoutSeconds = 15,
    [switch]$DisableCwdInheritance
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = if ([IO.Path]::IsPathRooted($Executable)) {
    (Resolve-Path -LiteralPath $Executable).Path
} else {
    (Resolve-Path -LiteralPath (Join-Path $root $Executable)).Path
}
$name = 'parity-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
# Retain reproduction inputs outside the window-state/soak cleanup area.
$state = Join-Path $root "zig-out/test-fixtures/$name"
$logs = Join-Path $root 'zig-out/logs'
$target = Join-Path $state 'cwd space 日本語'
$null = New-Item -ItemType Directory -Path $target, $logs -Force
$record = Join-Path $state 'records'
$null = New-Item -ItemType Directory -Path $record
$startup = Join-Path $state 'startup.ps1'
$config = Join-Path $state 'config'
$screenshot = Join-Path $logs "$name.png"
$resultPath = Join-Path $logs "$name.json"

if (-not ('GhosttyParityNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public static class GhosttyParityNative {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
    [StructLayout(LayoutKind.Sequential)] public struct CURSORINFO { public int Size,Flags; public IntPtr Cursor; public POINT Point; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc f, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] private static extern IntPtr ReadTextMessageW(IntPtr h, uint m, UIntPtr w, StringBuilder s);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] private static extern IntPtr SendTextMessageW(IntPtr h, uint m, UIntPtr w, string s);
    public static bool SetWindowTextW(IntPtr h, string s) { return SendTextMessageW(h, 0x000C, UIntPtr.Zero, s) != IntPtr.Zero; }
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, UIntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, UIntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO c);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr LoadCursorW(IntPtr h, IntPtr id);
    public static string Class(IntPtr h) { var s=new StringBuilder(256); GetClassNameW(h,s,256); return s.ToString(); }
    public static string Text(IntPtr h) { var s=new StringBuilder(4096); ReadTextMessageW(h,0x000D,new UIntPtr(4096),s); return s.ToString(); }
    public static IntPtr[] Windows(uint pid) { var list=new List<IntPtr>(); EnumWindows((h,p)=>{ uint n; GetWindowThreadProcessId(h,out n); if(n==pid && Class(h)=="GhosttyWindow") list.Add(h); return true; },IntPtr.Zero); return list.ToArray(); }
    public static IntPtr[] Children(IntPtr parent,string cls) { var list=new List<IntPtr>(); EnumChildWindows(parent,(h,p)=>{ if(Class(h)==cls) list.Add(h); return true; },IntPtr.Zero); return list.ToArray(); }
    public static CURSORINFO Cursor() { var c=new CURSORINFO(); c.Size=Marshal.SizeOf(c); if(!GetCursorInfo(ref c)) throw new Exception("GetCursorInfo"); return c; }
}
'@
}

function Wait-State([string]$Description, [scriptblock]$Check) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $Check) { return }
        if ($script:process.HasExited) { throw "Ghostty exited while waiting for $Description" }
        Start-Sleep -Milliseconds 80
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    if ($Description -match 'cursor|pointer') {
        $cursor = [GhosttyParityNative]::Cursor()
        $underPointer = [GhosttyParityNative]::WindowFromPoint($cursor.Point)
        Write-Host ([ordered]@{
            Check = $Description
            Cursor = $cursor.Cursor.ToInt64()
            Flags = $cursor.Flags
            X = $cursor.Point.X
            Y = $cursor.Point.Y
            WindowUnderPointer = $underPointer.ToInt64()
            WindowClass = [GhosttyParityNative]::Class($underPointer)
            ForegroundWindow = [GhosttyParityNative]::GetForegroundWindow().ToInt64()
            ExpectedSurface = $script:surface.ToInt64()
            ExpectedWindow = $script:window.ToInt64()
        } | ConvertTo-Json -Compress)
    }
    throw "Timed out: $Description"
}
function Key([IntPtr]$Handle, [int]$Code) {
    $null = [GhosttyParityNative]::PostMessageW($Handle, 0x100, [UIntPtr]::new($Code), [IntPtr]::new(1))
    $null = [GhosttyParityNative]::PostMessageW($Handle, 0x101, [UIntPtr]::new($Code), [IntPtr]::new(0xC0000001L))
}
function Text([IntPtr]$Handle, [string]$Value) {
    foreach ($c in $Value.ToCharArray()) {
        $null = [GhosttyParityNative]::PostMessageW($Handle, 0x102, [UIntPtr]::new([uint16]$c), [IntPtr]::Zero)
    }
}
function Command([IntPtr]$Handle, [string]$Value) { Text $Handle $Value; Key $Handle 13 }
function Records { @(Get-ChildItem -LiteralPath $record -Filter '*.txt') }
function Assert-Cwd([int]$Count, [string]$Expected) {
    Wait-State "$Count child startup records" { @(Records).Count -eq $Count }
    $latest = (Records | Sort-Object LastWriteTimeUtc | Select-Object -Last 1).FullName
    Wait-State 'complete cwd record' { ([IO.File]::ReadAllText($latest)).Trim() -eq $Expected }
}
function Status([IntPtr]$Bar) { [GhosttyParityNative]::Text([GhosttyParityNative]::GetDlgItem($Bar, 1102)) }

$startupText = @'
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText((Join-Path '__RECORD__' ([guid]::NewGuid().ToString() + '.txt')), $PWD.Path)
$esc = [char]27
$uri = [Uri]::new('__TARGET__' + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
[Console]::Write("$esc]7;$uri$([char]7)")
1..3 | ForEach-Object { [Console]::WriteLine('parity-needle ' + $_) }
[Console]::WriteLine('日本語検索 日本語検索')
1..100 | ForEach-Object { [Console]::WriteLine('scrollback row ' + $_) }
'@
$startupText.Replace('__RECORD__', $record.Replace("'", "''")).Replace('__TARGET__', $target.Replace("'", "''")) |
    Set-Content -LiteralPath $startup -Encoding utf8
$encodedStartup = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("& '$($startup.Replace("'", "''"))'"))
$inherit = (-not $DisableCwdInheritance).ToString().ToLowerInvariant()
$expectedCwd = if ($DisableCwdInheritance) { $root } else { $target }
@"
command = pwsh.exe -NoLogo -NoProfile -NoExit -EncodedCommand $encodedStartup
working-directory = $root
window-width = 100
window-height = 28
confirm-close-surface = false
shell-integration = none
mouse-hide-while-typing = true
window-inherit-working-directory = $inherit
tab-inherit-working-directory = $inherit
split-inherit-working-directory = $inherit
keybind = f2=start_search
keybind = f3=new_tab
keybind = f4=new_split:right
keybind = f5=new_window
keybind = f6=close_surface
keybind = f7=goto_tab:1
"@ | Set-Content -LiteralPath $config -Encoding utf8

$process = $null
$pointer = [GhosttyParityNative+POINT]::new()
$null = [GhosttyParityNative]::GetCursorPos([ref]$pointer)
try {
    $process = Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList @('--config-default-files=false', "--config-file=`"$config`"") -PassThru -RedirectStandardOutput (Join-Path $logs "$name.stdout.log") -RedirectStandardError (Join-Path $logs "$name.stderr.log")
    Wait-State 'initial window' { [GhosttyParityNative]::Windows($process.Id).Count -eq 1 }
    $window = [GhosttyParityNative]::Windows($process.Id)[0]
    $null = [GhosttyParityNative]::ShowWindow($window, 9)
    $null = [GhosttyParityNative]::SetForegroundWindow($window)
    Wait-State 'initial terminal' { [GhosttyParityNative]::Children($window, 'GhosttyWindow').Count -eq 1 }
    $surface = [GhosttyParityNative]::Children($window, 'GhosttyWindow')[0]
    Assert-Cwd 1 $root
    Start-Sleep -Milliseconds 800
    Key $surface 113 # F2
    Wait-State 'search bar' { [GhosttyParityNative]::Children($window, '#32770').Count -eq 1 }
    $bar = [GhosttyParityNative]::Children($window, '#32770')[0]
    Wait-State 'visible initialized search controls' {
        [GhosttyParityNative]::IsWindowVisible($bar) -and [GhosttyParityNative]::GetDlgItem($bar, 1101) -ne [IntPtr]::Zero
    }
    $edit = [GhosttyParityNative]::GetDlgItem($bar, 1101)
    if (-not [GhosttyParityNative]::SetWindowTextW($edit, 'parity-needle')) { throw 'WM_SETTEXT failed' }
    Write-Verbose "Needle: $([GhosttyParityNative]::Text($edit)); status: $(Status $bar)"
    Wait-State 'three scrollback matches' { (Status $bar) -match '/ 3$' }
    Key $surface 113
    Start-Sleep -Milliseconds 150
    Wait-State 'refocusing active search preserves results' { (Status $bar) -match '/ 3$' }
    Key $edit 13
    Wait-State 'first selected match' { (Status $bar) -eq '1 / 3' }
    $first = Status $bar
    Key $edit 13
    Wait-State 'Enter moves to next match' { (Status $bar) -ne $first -and (Status $bar) -match '/ 3$' }
    $null = [GhosttyParityNative]::SendMessageW($bar, 0x111, [UIntPtr]::new(1103), [IntPtr]::Zero)
    Wait-State 'Previous restores selection' { (Status $bar) -eq $first }
    $null = [GhosttyParityNative]::SetWindowTextW($edit, '日本語検索')
    Wait-State 'Unicode search' { (Status $bar) -match '/ 2$' }
    $null = [GhosttyParityNative]::SetWindowTextW($edit, 'no-such-parity-match')
    Wait-State 'no matches' { (Status $bar) -eq '0 / 0' }
    $null = [GhosttyParityNative]::SetWindowTextW($edit, '')
    Wait-State 'empty query clears results' { (Status $bar) -eq '' }
    $null = [GhosttyParityNative]::SetWindowTextW($edit, 'parity-needle')
    Wait-State 'query restarted' { (Status $bar) -match '/ 3$' }
    Key $edit 13
    Wait-State 'selected match before resize' { (Status $bar) -eq '1 / 3' }
    foreach ($i in 1..8) {
        $null = [GhosttyParityNative]::SetWindowPos($window, [IntPtr]::Zero, 50, 50, (700 + 40 * ($i % 2)), (400 + 100 * ($i % 2)), 0x14)
        Start-Sleep -Milliseconds 120
    }
    Wait-State 'resize preserves match count' { (Status $bar) -match '/ 3$' }
    Add-Type -AssemblyName System.Drawing
    $rect = [GhosttyParityNative+RECT]::new()
    $null = [GhosttyParityNative]::GetWindowRect($window, [ref]$rect)
    Start-Sleep -Milliseconds 300
    $bitmap = [Drawing.Bitmap]::new($rect.R - $rect.L, $rect.B - $rect.T)
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try { $graphics.CopyFromScreen($rect.L, $rect.T, 0, 0, $bitmap.Size) } finally { $graphics.Dispose() }
        $bitmap.Save($screenshot, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
    Key $edit 27
    Wait-State 'Escape closes search' { -not [GhosttyParityNative]::IsWindowVisible($bar) }
    $marker = Join-Path $state 'input-after-search.txt'
    Command $surface "[IO.File]::WriteAllText('$($marker.Replace("'", "''"))','ok')"
    Wait-State 'input after search and resize' { (Test-Path -LiteralPath $marker) -and [IO.File]::ReadAllText($marker) -eq 'ok' }
    Command $surface '[Console]::Write("$([char]27)]22;pointer$([char]7)")'
    Start-Sleep -Milliseconds 300
    $surfaceRect = [GhosttyParityNative+RECT]::new()
    $null = [GhosttyParityNative]::GetWindowRect($surface, [ref]$surfaceRect)
    $mouseX = $surfaceRect.L + 30
    $mouseY = $surfaceRect.B - 12
    $null = [GhosttyParityNative]::SetCursorPos($mouseX, $mouseY)
    $hand = [GhosttyParityNative]::LoadCursorW([IntPtr]::Zero, [IntPtr]::new(32649))
    Wait-State 'OSC 22 hand cursor' { [GhosttyParityNative]::Cursor().Cursor -eq $hand }
    Text $surface 'a'
    Wait-State 'typing hides pointer' { [GhosttyParityNative]::Cursor().Flags -eq 0 }
    $null = [GhosttyParityNative]::SetCursorPos(($mouseX + 3), $mouseY)
    Wait-State 'mouse motion restores pointer' { [GhosttyParityNative]::Cursor().Flags -eq 1 }
    Key $surface 8
    Command $surface '[Console]::Write("$([char]27)]22;text$([char]7)")'
    Start-Sleep -Milliseconds 200
    $null = [GhosttyParityNative]::SetCursorPos(($mouseX + 6), $mouseY)
    $ibeam = [GhosttyParityNative]::LoadCursorW([IntPtr]::Zero, [IntPtr]::new(32513))
    Wait-State 'OSC 22 text cursor' { [GhosttyParityNative]::Cursor().Cursor -eq $ibeam }
    # Remote host and Unix paths must not replace the last valid native cwd.
    Command $surface '[Console]::Write("$([char]27)]7;file://ghostty-invalid-remote/C:/Windows$([char]7)$([char]27)]7;file://localhost/home/user$([char]7)")'
    Start-Sleep -Milliseconds 250
    Key $surface 113
    Wait-State 'reopen retained search' { [GhosttyParityNative]::IsWindowVisible($bar) -and (Status $bar) -match '/ 3$' }
    Key $surface 114 # new tab
    Assert-Cwd 2 $expectedCwd
    Wait-State 'old tab search hidden' { -not [GhosttyParityNative]::IsWindowVisible($bar) }
    $newTabSurface = @([GhosttyParityNative]::Children($window, 'GhosttyWindow') | Where-Object { $_ -ne $surface })[0]
    Key $newTabSurface 113
    Wait-State 'second pane search' { [GhosttyParityNative]::Children($window, '#32770').Count -eq 2 }
    $secondBar = @([GhosttyParityNative]::Children($window, '#32770') | Where-Object { $_ -ne $bar })[0]
    Wait-State 'second bar visible' { [GhosttyParityNative]::IsWindowVisible($secondBar) }
    $secondEdit = [GhosttyParityNative]::GetDlgItem($secondBar, 1101)
    $null = [GhosttyParityNative]::SetWindowTextW($secondEdit, '日本語検索')
    Wait-State 'second pane independent query' { (Status $secondBar) -match '/ 2$' -and [GhosttyParityNative]::Text($edit) -eq 'parity-needle' }
    Key $newTabSurface 118 # first tab
    Wait-State 'tab search visibility restored' { [GhosttyParityNative]::IsWindowVisible($bar) -and -not [GhosttyParityNative]::IsWindowVisible($secondBar) }
    Key $surface 115 # split
    Assert-Cwd 3 $expectedCwd
    $splitSurface = @([GhosttyParityNative]::Children($window, 'GhosttyWindow') | Where-Object { $_ -ne $surface -and $_ -ne $newTabSurface })[0]
    Key $splitSurface 113
    Wait-State 'split search bar' { [GhosttyParityNative]::Children($window, '#32770').Count -eq 3 }
    $splitBar = @([GhosttyParityNative]::Children($window, '#32770') | Where-Object { $_ -ne $bar -and $_ -ne $secondBar })[0]
    Wait-State 'split search visible' { [GhosttyParityNative]::IsWindowVisible($splitBar) }
    $null = [GhosttyParityNative]::SetWindowTextW([GhosttyParityNative]::GetDlgItem($splitBar, 1101), 'parity-needle')
    Wait-State 'split search matches' { (Status $splitBar) -match '/ 3$' }
    Key $splitSurface 117 # close pane with running search
    Wait-State 'search pane closed' { [GhosttyParityNative]::Children($window, 'GhosttyWindow').Count -eq 2 -and [GhosttyParityNative]::Children($window, '#32770').Count -eq 2 }
    Key $surface 116 # window
    Assert-Cwd 4 $expectedCwd
    Wait-State 'two top-level windows' { [GhosttyParityNative]::Windows($process.Id).Count -eq 2 }
    $result = [ordered]@{ SearchScrollback = 3; UnicodeMatches = 2; SearchNavigation = 'pass'; EmptyAndNoMatches = 'pass'; PaneSearchIsolationAndClose = 'pass'; ResizeCycles = 8; InputAfterSearch = 'pass'; MouseShapeAndVisibility = 'pass'; CwdWindowTabSplit = 'pass'; CwdInheritanceEnabled = -not $DisableCwdInheritance; Screenshot = $screenshot }
    foreach ($h in [GhosttyParityNative]::Windows($process.Id)) { $null = [GhosttyParityNative]::PostMessageW($h, 0x10, [UIntPtr]::Zero, [IntPtr]::Zero) }
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { throw 'Ghostty did not exit cleanly' }
    if ($process.ExitCode -ne 0) { throw "Ghostty exit code: $($process.ExitCode)" }
    $result.ExitCode = $process.ExitCode
    $result | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding utf8
    [pscustomobject]$result
} finally {
    $null = [GhosttyParityNative]::SetCursorPos($pointer.X, $pointer.Y)
    if ($process -and -not $process.HasExited) {
        foreach ($h in [GhosttyParityNative]::Windows($process.Id)) { $null = [GhosttyParityNative]::PostMessageW($h, 0x10, [UIntPtr]::Zero, [IntPtr]::Zero) }
        if (-not $process.WaitForExit(5000)) { $process.Kill(); $process.WaitForExit() }
    }
    # Keep dedicated inputs and logs under zig-out so failures are reproducible.
}
