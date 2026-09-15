<#
.SYNOPSIS
Checks native window and shell behavior of Ghostty on Windows.

.DESCRIPTION
Starts a dedicated Ghostty process, validates its shell-visible styles and
large and small class icons, creates a split, checks tab-bar and divider layout
across every monitor, then performs a maximize, minimize, restore, and graceful
close sequence using Win32 APIs. Existing Ghostty processes and windows are
not modified.

.PARAMETER Executable
Ghostty executable to test. Relative paths are resolved from the repository
root. The default is zig-out/release/bin/ghostty.exe.

.PARAMETER TimeoutSeconds
Maximum time to wait for each state transition. The default is 10 seconds.

.PARAMETER KeepOpenOnFailure
Leave the dedicated test process open when a check fails. By default, the
script first requests a graceful close and then terminates only the process it
started if that close does not finish within the timeout.

.PARAMETER TestGpuRecovery
Enable the private test hook, recreate the D3D11 device and all renderer GPU
resources, then verify that the existing terminal session can still execute a
command. This tests controlled recovery without forcing a physical GPU fault.

.PARAMETER GpuRecoveryIterations
Number of consecutive GPU resource rebuilds to perform in the same terminal
session when TestGpuRecovery is enabled. The default is 1.

.EXAMPLE
./scripts/test-windows-window-state.ps1

.EXAMPLE
./scripts/test-windows-window-state.ps1 `
    -Executable zig-out/version-check-script/bin/ghostty.exe

.EXAMPLE
./scripts/test-windows-window-state.ps1 `
    -TestGpuRecovery `
    -GpuRecoveryIterations 20
#>
[CmdletBinding()]
param(
    [string]$Executable = "",
    [ValidateRange(1, 60)]
    [int]$TimeoutSeconds = 10,
    [switch]$TestGpuRecovery,
    [ValidateRange(1, 100)]
    [int]$GpuRecoveryIterations = 1,
    [switch]$KeepOpenOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "This script tests the native Windows Ghostty executable."
}
if (-not $TestGpuRecovery -and $PSBoundParameters.ContainsKey("GpuRecoveryIterations")) {
    throw "GpuRecoveryIterations requires TestGpuRecovery."
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($Executable)) {
    $executablePath = Join-Path $repositoryRoot "zig-out\release\bin\ghostty.exe"
} elseif ([System.IO.Path]::IsPathRooted($Executable)) {
    $executablePath = [System.IO.Path]::GetFullPath($Executable)
} else {
    $executablePath = [System.IO.Path]::GetFullPath(
        (Join-Path $repositoryRoot $Executable)
    )
}

if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "Ghostty executable not found: $executablePath"
}

$logDirectory = Join-Path $repositoryRoot "zig-out\logs"
[System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
$sessionName = "window-state-{0}-{1}" -f `
    (Get-Date -Format "yyyyMMdd-HHmmss-fff"), `
    ([System.Guid]::NewGuid().ToString("N").Substring(0, 8))
$stdoutPath = Join-Path $logDirectory "$sessionName.stdout.log"
$stderrPath = Join-Path $logDirectory "$sessionName.stderr.log"
$testStateRoot = Join-Path $repositoryRoot "zig-out\test-state"
$sessionDirectory = Join-Path $testStateRoot $sessionName
$configPath = Join-Path $sessionDirectory "config.ghostty"
$inputMarkerPath = Join-Path $sessionDirectory "terminal-input.txt"
$gpuRecoveryMarkerPath = Join-Path $sessionDirectory "gpu-recovery.txt"

if (-not ("GhosttyWindowStateNative" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class GhosttyWindowStateNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO
    {
        public int cbSize;
        public uint flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsZoomed(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags
    );

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassNameW(
        IntPtr hWnd,
        StringBuilder className,
        int classNameLength
    );

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(
        IntPtr hWnd,
        out uint processId
    );

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetGUIThreadInfo(
        uint threadId,
        ref GUITHREADINFO info
    );

    public static IntPtr FindWindow(uint processId, string expectedClassName)
    {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
        {
            uint candidateProcessId;
            GetWindowThreadProcessId(hWnd, out candidateProcessId);
            if (candidateProcessId != processId)
                return true;

            StringBuilder className = new StringBuilder(256);
            if (GetClassNameW(hWnd, className, className.Capacity) == 0)
                return true;
            if (!String.Equals(
                className.ToString(),
                expectedClassName,
                StringComparison.Ordinal
            ))
                return true;

            result = hWnd;
            return false;
        }, IntPtr.Zero);
        return result;
    }

    public static IntPtr[] FindWindows(uint processId, string expectedClassName)
    {
        List<IntPtr> results = new List<IntPtr>();
        EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
        {
            uint candidateProcessId;
            GetWindowThreadProcessId(hWnd, out candidateProcessId);
            if (candidateProcessId != processId)
                return true;

            StringBuilder className = new StringBuilder(256);
            if (GetClassNameW(hWnd, className, className.Capacity) == 0)
                return true;
            if (!String.Equals(
                className.ToString(),
                expectedClassName,
                StringComparison.Ordinal
            ))
                return true;

            results.Add(hWnd);
            return true;
        }, IntPtr.Zero);
        return results.ToArray();
    }

    public static IntPtr GetFocusedRootWindow(IntPtr hWnd)
    {
        uint processId;
        uint threadId = GetWindowThreadProcessId(hWnd, out processId);
        GUITHREADINFO info = new GUITHREADINFO();
        info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
        if (threadId == 0 || !GetGUIThreadInfo(threadId, ref info))
            return IntPtr.Zero;

        IntPtr focused = info.hwndFocus != IntPtr.Zero
            ? info.hwndFocus
            : info.hwndActive;
        return focused == IntPtr.Zero
            ? IntPtr.Zero
            : GetAncestor(focused, 2);
    }

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLong32(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "GetClassLongPtrW")]
    private static extern IntPtr GetClassLongPtr64(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "GetClassLongW")]
    private static extern uint GetClassLong32(IntPtr hWnd, int index);

    public static long GetWindowLongValue(IntPtr hWnd, int index)
    {
        return IntPtr.Size == 8
            ? GetWindowLongPtr64(hWnd, index).ToInt64()
            : GetWindowLong32(hWnd, index);
    }

    public static IntPtr GetClassLongPtrValue(IntPtr hWnd, int index)
    {
        return IntPtr.Size == 8
            ? GetClassLongPtr64(hWnd, index)
            : new IntPtr(unchecked((long)GetClassLong32(hWnd, index)));
    }

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint command);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(
        IntPtr hWnd,
        uint attribute,
        out int value,
        int valueSize
    );

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PostMessageW(
        IntPtr hWnd,
        uint message,
        UIntPtr wParam,
        IntPtr lParam
    );

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageW(
        IntPtr hWnd,
        uint message,
        UIntPtr wParam,
        IntPtr lParam
    );
}
"@
}

# PowerShell itself may be DPI unaware. Without a per-monitor-aware thread,
# USER32 virtualizes rectangles returned for windows on scaled monitors and a
# physical 40-pixel tab bar at 125% appears to this test as 32 pixels.
$dpiAwarenessPerMonitorV2 = [IntPtr]::new(-4)
$previousDpiAwareness = `
    [GhosttyWindowStateNative]::SetThreadDpiAwarenessContext(
        $dpiAwarenessPerMonitorV2
    )
if ($previousDpiAwareness -eq [IntPtr]::Zero) {
    throw "SetThreadDpiAwarenessContext(PER_MONITOR_AWARE_V2) failed."
}

$swMaximize = 3
$swMinimize = 6
$swRestore = 9
$wmClose = 0x0010
$wmKeyDown = 0x0100
$wmKeyUp = 0x0101
$wmChar = 0x0102
$wmTestRecoverRenderer = 0x0403
$wmTestRecoveryStatus = 0x0404
$vkF5 = 0x74
$vkF6 = 0x75
$vkF7 = 0x76
$vkF8 = 0x77
$vkF9 = 0x78
$vkF10 = 0x79
$vkReturn = 0x0D
$gwlStyle = -16
$gwlExStyle = -20
$gclpHIcon = -14
$gclpHIconSm = -34
$gwOwner = 4
$gwChild = 5
$gaRoot = 2
$dwmwaCloaked = 14
$wsCaption = 0x00C00000
$wsSysMenu = 0x00080000
$wsThickFrame = 0x00040000
$wsMinimizeBox = 0x00020000
$wsMaximizeBox = 0x00010000
$wsExToolWindow = 0x00000080
$swpNoZOrder = 0x0004
$swpNoActivate = 0x0010
$timeoutMilliseconds = $TimeoutSeconds * 1000

function Wait-ForCondition {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Condition,
        [Parameter(Mandatory)]
        [string]$Description
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.ElapsedMilliseconds -lt $timeoutMilliseconds) {
        if (& $Condition) {
            return
        }
        Start-Sleep -Milliseconds 50
    }

    throw "Timed out waiting for $Description."
}

function Set-TestConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [ValidateSet("always", "never")]
        [string]$TabBarMode
    )

    $lines = @(
        "window-show-tab-bar = $TabBarMode"
        "command = direct:cmd.exe /D /Q"
    )
    $content = ($lines -join [System.Environment]::NewLine) + `
        [System.Environment]::NewLine
    [System.IO.File]::WriteAllText(
        $Path,
        $content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Send-TestText {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$Handle,
        [Parameter(Mandatory)]
        [string]$Text
    )

    foreach ($unit in $Text.ToCharArray()) {
        if (-not [GhosttyWindowStateNative]::PostMessageW(
            $Handle,
            $wmChar,
            [UIntPtr]::new([uint16]$unit),
            [IntPtr]::Zero
        )) {
            throw "Failed to send terminal text to Ghostty."
        }
    }
}

function Send-TestKey {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$Handle,
        [Parameter(Mandatory)]
        [uint32]$VirtualKey,
        [Parameter(Mandatory)]
        [string]$Description
    )

    if (-not [GhosttyWindowStateNative]::PostMessageW(
        $Handle,
        $wmKeyDown,
        [UIntPtr]::new($VirtualKey),
        [IntPtr]::Zero
    ) -or -not [GhosttyWindowStateNative]::PostMessageW(
        $Handle,
        $wmKeyUp,
        [UIntPtr]::new($VirtualKey),
        [IntPtr]::Zero
    )) {
        throw "Failed to send the $Description key to Ghostty."
    }
}

function Wait-ForMainWindow {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.ElapsedMilliseconds -lt $timeoutMilliseconds) {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "Ghostty exited before creating a top-level window."
        }

        $handle = $Process.MainWindowHandle
        if ($handle -ne [IntPtr]::Zero -and
            [GhosttyWindowStateNative]::IsWindowVisible($handle)) {
            return $handle
        }
        Start-Sleep -Milliseconds 50
    }

    throw "Timed out waiting for the Ghostty top-level window."
}

function Get-ProcessTopLevelWindows {
    param(
        [Parameter(Mandatory)]
        [uint32]$ProcessId
    )

    @(
        [GhosttyWindowStateNative]::FindWindows(
            $ProcessId,
            "GhosttyWindow"
        )
    )
}

function Get-WindowRectangle {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$Handle
    )

    $rect = [GhosttyWindowStateNative+RECT]::new()
    if (-not [GhosttyWindowStateNative]::GetWindowRect($Handle, [ref]$rect)) {
        throw "GetWindowRect failed for handle $Handle."
    }

    [pscustomobject]@{
        X = $rect.Left
        Y = $rect.Top
        Width = $rect.Right - $rect.Left
        Height = $rect.Bottom - $rect.Top
    }
}

function Wait-ForProcessWindow {
    param(
        [Parameter(Mandatory)]
        [uint32]$ProcessId,
        [Parameter(Mandatory)]
        [string]$ClassName
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.ElapsedMilliseconds -lt $timeoutMilliseconds) {
        $handle = [GhosttyWindowStateNative]::FindWindow($ProcessId, $ClassName)
        if ($handle -ne [IntPtr]::Zero -and
            [GhosttyWindowStateNative]::IsWindowVisible($handle)) {
            return $handle
        }
        Start-Sleep -Milliseconds 50
    }

    throw "Timed out waiting for the $ClassName window."
}

function Wait-ForOwnedProcessWindow {
    param(
        [Parameter(Mandatory)]
        [uint32]$ProcessId,
        [Parameter(Mandatory)]
        [string]$ClassName,
        [Parameter(Mandatory)]
        [IntPtr]$OwnerHandle
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.ElapsedMilliseconds -lt $timeoutMilliseconds) {
        $handle = @(
            [GhosttyWindowStateNative]::FindWindows($ProcessId, $ClassName) |
                Where-Object {
                    [GhosttyWindowStateNative]::GetWindow($_, $gwOwner) -eq `
                        $OwnerHandle
                }
        ) | Select-Object -First 1
        if ($handle -and
            [GhosttyWindowStateNative]::IsWindowVisible($handle)) {
            return [IntPtr]$handle
        }
        Start-Sleep -Milliseconds 50
    }

    throw "Timed out waiting for the $ClassName window owned by $OwnerHandle."
}

function Get-TabBarLayout {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$ParentHandle,
        [Parameter(Mandatory)]
        [IntPtr]$TabBarHandle
    )

    $client = [GhosttyWindowStateNative+RECT]::new()
    if (-not [GhosttyWindowStateNative]::GetClientRect(
        $ParentHandle,
        [ref]$client
    )) {
        throw "GetClientRect failed for handle $ParentHandle."
    }
    $origin = [GhosttyWindowStateNative+POINT]::new()
    if (-not [GhosttyWindowStateNative]::ClientToScreen(
        $ParentHandle,
        [ref]$origin
    )) {
        throw "ClientToScreen failed for handle $ParentHandle."
    }

    $tabBar = Get-WindowRectangle -Handle $TabBarHandle
    $tabBarOwner = [GhosttyWindowStateNative]::GetWindow($TabBarHandle, $gwOwner)
    $clientWidth = $client.Right - $client.Left
    $parentDpi = [GhosttyWindowStateNative]::GetDpiForWindow($ParentHandle)
    $tabBarDpi = [GhosttyWindowStateNative]::GetDpiForWindow($TabBarHandle)
    $expectedHeight = [Math]::Truncate((32 * $parentDpi + 48) / 96)

    if ($tabBar.X -ne $origin.X -or $tabBar.Y -ne $origin.Y) {
        throw "Tab bar origin does not match the parent client origin."
    }
    if ($tabBar.Width -ne $clientWidth) {
        throw "Tab bar width does not match the parent client width."
    }
    if ($tabBar.Height -ne $expectedHeight) {
        throw "Tab bar height $($tabBar.Height) does not match expected height $expectedHeight (parent DPI $parentDpi, tab bar DPI $tabBarDpi)."
    }
    if ($tabBarDpi -ne $parentDpi) {
        throw "Tab bar DPI $tabBarDpi does not match parent DPI $parentDpi."
    }
    if ($tabBarOwner -ne $ParentHandle) {
        throw "Tab bar owner $tabBarOwner does not match parent $ParentHandle."
    }

    [pscustomobject]@{
        ParentDpi = $parentDpi
        TabBarDpi = $tabBarDpi
        Owner = $tabBarOwner.ToInt64()
        X = $tabBar.X
        Y = $tabBar.Y
        Width = $tabBar.Width
        Height = $tabBar.Height
    }
}

function Wait-ForTabBarLayout {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$ParentHandle,
        [Parameter(Mandatory)]
        [IntPtr]$TabBarHandle
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastError = $null
    while ($stopwatch.ElapsedMilliseconds -lt $timeoutMilliseconds) {
        try {
            return Get-TabBarLayout `
                -ParentHandle $ParentHandle `
                -TabBarHandle $TabBarHandle
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 50
    }

    throw "Timed out waiting for the tab bar layout: $lastError"
}

function Get-SplitDividerLayout {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$ParentHandle,
        [Parameter(Mandatory)]
        [IntPtr]$TabBarHandle,
        [Parameter(Mandatory)]
        [IntPtr]$DividerHandle
    )

    $client = [GhosttyWindowStateNative+RECT]::new()
    if (-not [GhosttyWindowStateNative]::GetClientRect(
        $ParentHandle,
        [ref]$client
    )) {
        throw "GetClientRect failed for handle $ParentHandle."
    }
    $origin = [GhosttyWindowStateNative+POINT]::new()
    if (-not [GhosttyWindowStateNative]::ClientToScreen(
        $ParentHandle,
        [ref]$origin
    )) {
        throw "ClientToScreen failed for handle $ParentHandle."
    }

    $tabBar = Get-WindowRectangle -Handle $TabBarHandle
    $divider = Get-WindowRectangle -Handle $DividerHandle
    $parentDpi = [GhosttyWindowStateNative]::GetDpiForWindow($ParentHandle)
    $dividerDpi = [GhosttyWindowStateNative]::GetDpiForWindow($DividerHandle)
    $dividerOwner = [GhosttyWindowStateNative]::GetWindow($DividerHandle, $gwOwner)
    $clientWidth = $client.Right - $client.Left
    $clientHeight = $client.Bottom - $client.Top
    $contentTop = $origin.Y + $tabBar.Height
    $contentBottom = $origin.Y + $clientHeight
    $maximumDividerWidth = [Math]::Max(
        2,
        [Math]::Truncate((2 * $parentDpi + 48) / 96)
    )

    if ($dividerOwner -ne $ParentHandle) {
        throw "Split divider owner $dividerOwner does not match parent $ParentHandle."
    }
    if ($dividerDpi -ne $parentDpi) {
        throw "Split divider DPI $dividerDpi does not match parent DPI $parentDpi."
    }
    if ($divider.Width -lt 1 -or $divider.Width -gt $maximumDividerWidth) {
        throw "Vertical split divider width $($divider.Width) is outside the expected range."
    }
    if ($divider.Height -le $divider.Width) {
        throw "Expected a vertical split divider, got $($divider.Width)x$($divider.Height)."
    }
    if ($divider.X -lt $origin.X -or
        $divider.X + $divider.Width -gt $origin.X + $clientWidth) {
        throw "Split divider is outside the parent client width."
    }
    if ($divider.Y -ne $contentTop -or
        $divider.Y + $divider.Height -ne $contentBottom) {
        throw "Split divider does not span the terminal content height."
    }

    [pscustomobject]@{
        ParentDpi = $parentDpi
        DividerDpi = $dividerDpi
        Owner = $dividerOwner.ToInt64()
        X = $divider.X
        Y = $divider.Y
        Width = $divider.Width
        Height = $divider.Height
    }
}

function Wait-ForSplitDividerLayout {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$ParentHandle,
        [Parameter(Mandatory)]
        [IntPtr]$TabBarHandle,
        [Parameter(Mandatory)]
        [IntPtr]$DividerHandle
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastError = $null
    while ($stopwatch.ElapsedMilliseconds -lt $timeoutMilliseconds) {
        try {
            return Get-SplitDividerLayout `
                -ParentHandle $ParentHandle `
                -TabBarHandle $TabBarHandle `
                -DividerHandle $DividerHandle
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 50
    }

    throw "Timed out waiting for the split divider layout: $lastError"
}

function Test-RestoredRectangle {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Initial,
        [Parameter(Mandatory)]
        [pscustomobject]$Restored
    )

    $tolerance = 2
    foreach ($property in @("X", "Y", "Width", "Height")) {
        $difference = [Math]::Abs($Initial.$property - $Restored.$property)
        if ($difference -gt $tolerance) {
            throw "Restored $property differs by $difference pixels."
        }
    }
}

function Test-ShellEligibility {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$Handle
    )

    $style = [uint64][GhosttyWindowStateNative]::GetWindowLongValue(
        $Handle,
        $gwlStyle
    )
    $extendedStyle = [uint64][GhosttyWindowStateNative]::GetWindowLongValue(
        $Handle,
        $gwlExStyle
    )
    $requiredStyle = [uint64](
        $wsCaption -bor
        $wsSysMenu -bor
        $wsThickFrame -bor
        $wsMinimizeBox -bor
        $wsMaximizeBox
    )
    $missingStyle = $requiredStyle -band (-bnot $style)
    if ($missingStyle -ne 0) {
        throw "Top-level window is missing required style bits 0x$($missingStyle.ToString('X8'))."
    }

    $owner = [GhosttyWindowStateNative]::GetWindow($Handle, $gwOwner)
    if ($owner -ne [IntPtr]::Zero) {
        throw "Top-level window unexpectedly has owner $owner."
    }

    $root = [GhosttyWindowStateNative]::GetAncestor($Handle, $gaRoot)
    if ($root -ne $Handle) {
        throw "MainWindowHandle is not the root top-level window."
    }

    if (($extendedStyle -band $wsExToolWindow) -ne 0) {
        throw "Top-level window is marked as WS_EX_TOOLWINDOW."
    }

    $cloaked = 0
    $dwmResult = [GhosttyWindowStateNative]::DwmGetWindowAttribute(
        $Handle,
        $dwmwaCloaked,
        [ref]$cloaked,
        4
    )
    if ($dwmResult -eq 0 -and $cloaked -ne 0) {
        throw "Top-level window is cloaked by DWM."
    }

    $visible = [GhosttyWindowStateNative]::IsWindowVisible($Handle)
    $largeIcon = [GhosttyWindowStateNative]::GetClassLongPtrValue(
        $Handle,
        $gclpHIcon
    )
    $smallIcon = [GhosttyWindowStateNative]::GetClassLongPtrValue(
        $Handle,
        $gclpHIconSm
    )
    if ($largeIcon -eq [IntPtr]::Zero -or $smallIcon -eq [IntPtr]::Zero) {
        throw "Top-level window class does not provide both large and small icons."
    }
    [pscustomobject]@{
        Style = "0x$($style.ToString('X8'))"
        ExtendedStyle = "0x$($extendedStyle.ToString('X8'))"
        Owner = $owner
        Root = $root
        LargeIcon = $largeIcon.ToInt64()
        SmallIcon = $smallIcon.ToInt64()
        DwmCloaked = if ($dwmResult -eq 0) { [bool]$cloaked } else { $null }
        SnapEligible = [bool](
            ($style -band $wsThickFrame) -and
            ($style -band $wsMaximizeBox)
        )
        AltTabEligible = [bool](
            $visible -and
            $owner -eq [IntPtr]::Zero -and
            ($extendedStyle -band $wsExToolWindow) -eq 0
        )
        TaskbarEligible = [bool](
            $visible -and
            $owner -eq [IntPtr]::Zero -and
            ($extendedStyle -band $wsExToolWindow) -eq 0
        )
    }
}

$process = $null
$windowHandle = [IntPtr]::Zero
$completed = $false
$forcedTermination = $false

try {
    [System.IO.Directory]::CreateDirectory($sessionDirectory) | Out-Null
    Set-TestConfig `
        -Path $configPath `
        -TabBarMode "always"
    $arguments = @(
        "--maximize=false"
        "--fullscreen=false"
        "--confirm-close-surface=false"
        "--quit-after-last-window-closed=true"
        "--title=Ghostty-window-state-test"
        "--config-file=`"$configPath`""
        "--keybind=f5=new_split:right"
        "--keybind=f6=reload_config"
        "--keybind=f7=new_window"
        "--keybind=f8=close_all_windows"
        "--keybind=f9=goto_window:next"
        "--keybind=f10=toggle_visibility"
    )
    $previousGhosttyLog = [System.Environment]::GetEnvironmentVariable(
        "GHOSTTY_LOG",
        [System.EnvironmentVariableTarget]::Process
    )
    $previousRecoveryTest = [System.Environment]::GetEnvironmentVariable(
        "GHOSTTY_TEST_DEVICE_RECOVERY",
        [System.EnvironmentVariableTarget]::Process
    )
    try {
        [System.Environment]::SetEnvironmentVariable(
            "GHOSTTY_LOG",
            "stderr=true",
            [System.EnvironmentVariableTarget]::Process
        )
        if ($TestGpuRecovery) {
            [System.Environment]::SetEnvironmentVariable(
                "GHOSTTY_TEST_DEVICE_RECOVERY",
                "1",
                [System.EnvironmentVariableTarget]::Process
            )
        }
        $process = Start-Process `
            -FilePath $executablePath `
            -ArgumentList $arguments `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru
    } finally {
        [System.Environment]::SetEnvironmentVariable(
            "GHOSTTY_LOG",
            $previousGhosttyLog,
            [System.EnvironmentVariableTarget]::Process
        )
        [System.Environment]::SetEnvironmentVariable(
            "GHOSTTY_TEST_DEVICE_RECOVERY",
            $previousRecoveryTest,
            [System.EnvironmentVariableTarget]::Process
        )
    }

    try {
        $null = $process.WaitForInputIdle($timeoutMilliseconds)
    } catch {
        # MainWindowHandle polling below also covers an early process exit.
    }

    $windowHandle = Wait-ForMainWindow -Process $process
    Write-Verbose "Found top-level window $windowHandle."
    $tabBarHandle = Wait-ForProcessWindow `
        -ProcessId $process.Id `
        -ClassName "GhosttyTabBar"
    Write-Verbose "Found tab bar window $tabBarHandle."
    $shellEligibility = Test-ShellEligibility -Handle $windowHandle

    Wait-ForCondition -Description "the initial restored state" -Condition {
        -not [GhosttyWindowStateNative]::IsZoomed($windowHandle) -and
            -not [GhosttyWindowStateNative]::IsIconic($windowHandle)
    }
    $initial = Get-WindowRectangle -Handle $windowHandle
    $initialTabBar = Wait-ForTabBarLayout `
        -ParentHandle $windowHandle `
        -TabBarHandle $tabBarHandle

    Add-Type -AssemblyName System.Windows.Forms
    $surfaceHandle = [GhosttyWindowStateNative]::GetWindow(
        $windowHandle,
        $gwChild
    )
    if ($surfaceHandle -eq [IntPtr]::Zero) {
        throw "Ghostty surface child window was not found."
    }

    $markerValue = "ghostty-terminal-input"
    $markerCommand = "echo $markerValue>`"$inputMarkerPath`""
    Send-TestText -Handle $surfaceHandle -Text $markerCommand
    Send-TestKey `
        -Handle $surfaceHandle `
        -VirtualKey $vkReturn `
        -Description "terminal Enter"
    Wait-ForCondition -Description "terminal input marker creation" -Condition {
        if (-not [System.IO.File]::Exists($inputMarkerPath)) {
            return $false
        }
        [System.IO.File]::ReadAllText($inputMarkerPath).Trim() -eq $markerValue
    }
    $terminalInput = [pscustomobject]@{
        TextDelivered = $true
        EnterDelivered = $true
        CommandExecuted = $true
    }
    Write-Verbose "Validated terminal text input and command execution."

    $gpuRecovery = $null
    if ($TestGpuRecovery) {
        $completedRecoveries = 0
        for ($recoveryIndex = 1; $recoveryIndex -le $GpuRecoveryIterations; $recoveryIndex++) {
            $initialRecoveryCount = [GhosttyWindowStateNative]::SendMessageW(
                $surfaceHandle,
                $wmTestRecoveryStatus,
                [UIntPtr]::Zero,
                [IntPtr]::Zero
            ).ToInt64()
            if (-not [GhosttyWindowStateNative]::PostMessageW(
                $surfaceHandle,
                $wmTestRecoverRenderer,
                [UIntPtr]::Zero,
                [IntPtr]::Zero
            )) {
                throw "Failed to request controlled GPU recovery $recoveryIndex."
            }
            Wait-ForCondition `
                -Description "controlled GPU resource recovery $recoveryIndex" `
                -Condition {
                    [GhosttyWindowStateNative]::SendMessageW(
                        $surfaceHandle,
                        $wmTestRecoveryStatus,
                        [UIntPtr]::Zero,
                        [IntPtr]::Zero
                    ).ToInt64() -gt $initialRecoveryCount
                }

            $recoveryValue = "ghostty-gpu-recovery-$recoveryIndex"
            $recoveryCommand = "echo $recoveryValue>`"$gpuRecoveryMarkerPath`""
            Send-TestText -Handle $surfaceHandle -Text $recoveryCommand
            Send-TestKey `
                -Handle $surfaceHandle `
                -VirtualKey $vkReturn `
                -Description "terminal Enter after GPU recovery $recoveryIndex"
            Wait-ForCondition `
                -Description "terminal input after GPU recovery $recoveryIndex" `
                -Condition {
                    if (-not [System.IO.File]::Exists($gpuRecoveryMarkerPath)) {
                        return $false
                    }
                    [System.IO.File]::ReadAllText($gpuRecoveryMarkerPath).Trim() -eq `
                        $recoveryValue
            }
            $completedRecoveries++
            Write-Verbose "Validated controlled GPU resource recovery $recoveryIndex."
        }
        $gpuRecovery = [pscustomobject]@{
            Requested = $true
            IterationsRequested = $GpuRecoveryIterations
            IterationsCompleted = $completedRecoveries
            ResourcesRecreated = $true
            TerminalSessionPreserved = $true
        }
    }

    Set-TestConfig `
        -Path $configPath `
        -TabBarMode "never"
    Send-TestKey `
        -Handle $surfaceHandle `
        -VirtualKey $vkF6 `
        -Description "config reload"
    Wait-ForCondition -Description "the tab bar to hide after config reload" -Condition {
        -not [GhosttyWindowStateNative]::IsWindowVisible($tabBarHandle)
    }

    Set-TestConfig `
        -Path $configPath `
        -TabBarMode "always"
    Send-TestKey `
        -Handle $surfaceHandle `
        -VirtualKey $vkF6 `
        -Description "config reload"
    Wait-ForCondition -Description "the tab bar to return after config reload" -Condition {
        [GhosttyWindowStateNative]::IsWindowVisible($tabBarHandle)
    }
    $reloadedTabBar = Wait-ForTabBarLayout `
        -ParentHandle $windowHandle `
        -TabBarHandle $tabBarHandle
    $configReload = [pscustomobject]@{
        Hidden = $true
        Restored = $true
        RestoredLayout = $reloadedTabBar
    }
    Write-Verbose "Validated config reload with tab bar hide and restore."

    Send-TestKey `
        -Handle $surfaceHandle `
        -VirtualKey $vkF5 `
        -Description "split test"
    $dividerHandle = Wait-ForProcessWindow `
        -ProcessId $process.Id `
        -ClassName "GhosttySplitDivider"
    Write-Verbose "Created split divider window $dividerHandle."
    $initialDivider = Wait-ForSplitDividerLayout `
        -ParentHandle $windowHandle `
        -TabBarHandle $tabBarHandle `
        -DividerHandle $dividerHandle

    $monitorLayouts = @()
    foreach ($screen in @([System.Windows.Forms.Screen]::AllScreens)) {
        Write-Verbose "Moving test window to $($screen.DeviceName)."
        $workArea = $screen.WorkingArea
        $current = Get-WindowRectangle -Handle $windowHandle
        $targetX = $workArea.Left + [Math]::Max(
            0,
            [Math]::Truncate(($workArea.Width - $current.Width) / 2)
        )
        $targetY = $workArea.Top + [Math]::Max(
            0,
            [Math]::Truncate(($workArea.Height - $current.Height) / 2)
        )
        if (-not [GhosttyWindowStateNative]::SetWindowPos(
            $windowHandle,
            [IntPtr]::Zero,
            $targetX,
            $targetY,
            $current.Width,
            $current.Height,
            $swpNoZOrder -bor $swpNoActivate
        )) {
            throw "SetWindowPos failed for monitor $($screen.DeviceName)."
        }

        Wait-ForCondition -Description "the move to $($screen.DeviceName)" -Condition {
            $moved = Get-WindowRectangle -Handle $windowHandle
            $centerX = $moved.X + [Math]::Truncate($moved.Width / 2)
            $centerY = $moved.Y + [Math]::Truncate($moved.Height / 2)
            $centerX -ge $workArea.Left -and
                $centerX -lt $workArea.Right -and
                $centerY -ge $workArea.Top -and
                $centerY -lt $workArea.Bottom
        }
        $layout = Wait-ForTabBarLayout `
            -ParentHandle $windowHandle `
            -TabBarHandle $tabBarHandle
        $dividerLayout = Wait-ForSplitDividerLayout `
            -ParentHandle $windowHandle `
            -TabBarHandle $tabBarHandle `
            -DividerHandle $dividerHandle
        $monitorLayouts += [pscustomobject]@{
            DeviceName = $screen.DeviceName
            Primary = $screen.Primary
            WorkingArea = "$($workArea.Left),$($workArea.Top) $($workArea.Width)x$($workArea.Height)"
            ParentDpi = $layout.ParentDpi
            TabBarDpi = $layout.TabBarDpi
            TabBar = "$($layout.X),$($layout.Y) $($layout.Width)x$($layout.Height)"
            DividerDpi = $dividerLayout.DividerDpi
            Divider = "$($dividerLayout.X),$($dividerLayout.Y) $($dividerLayout.Width)x$($dividerLayout.Height)"
        }
        Write-Verbose "Validated tab bar and divider on $($screen.DeviceName)."
    }

    if (-not [GhosttyWindowStateNative]::SetWindowPos(
        $windowHandle,
        [IntPtr]::Zero,
        $initial.X,
        $initial.Y,
        $initial.Width,
        $initial.Height,
        $swpNoZOrder -bor $swpNoActivate
    )) {
        throw "SetWindowPos failed while restoring the initial placement."
    }
    $null = Wait-ForTabBarLayout `
        -ParentHandle $windowHandle `
        -TabBarHandle $tabBarHandle
    $null = Wait-ForSplitDividerLayout `
        -ParentHandle $windowHandle `
        -TabBarHandle $tabBarHandle `
        -DividerHandle $dividerHandle
    Write-Verbose "Restored the initial window placement."

    $null = [GhosttyWindowStateNative]::ShowWindow($windowHandle, $swMaximize)
    Wait-ForCondition -Description "the maximized state" -Condition {
        [GhosttyWindowStateNative]::IsZoomed($windowHandle)
    }
    $maximized = Get-WindowRectangle -Handle $windowHandle
    $maximizedDivider = Wait-ForSplitDividerLayout `
        -ParentHandle $windowHandle `
        -TabBarHandle $tabBarHandle `
        -DividerHandle $dividerHandle
    Write-Verbose "Validated the maximized layout."

    $null = [GhosttyWindowStateNative]::ShowWindow($windowHandle, $swMinimize)
    Wait-ForCondition -Description "the minimized state" -Condition {
        [GhosttyWindowStateNative]::IsIconic($windowHandle)
    }

    $null = [GhosttyWindowStateNative]::ShowWindow($windowHandle, $swRestore)
    Wait-ForCondition -Description "the restored maximized state" -Condition {
        [GhosttyWindowStateNative]::IsZoomed($windowHandle) -and
            -not [GhosttyWindowStateNative]::IsIconic($windowHandle) -and
            [GhosttyWindowStateNative]::IsWindowVisible($windowHandle)
    }

    # Windows restores a minimized window to its state immediately before
    # minimization. Because that state was maximized, request one more restore
    # to return to the original normal placement.
    $null = [GhosttyWindowStateNative]::ShowWindow($windowHandle, $swRestore)
    Wait-ForCondition -Description "the original normal state" -Condition {
        -not [GhosttyWindowStateNative]::IsZoomed($windowHandle) -and
            -not [GhosttyWindowStateNative]::IsIconic($windowHandle) -and
            [GhosttyWindowStateNative]::IsWindowVisible($windowHandle)
    }
    $restored = Get-WindowRectangle -Handle $windowHandle
    Test-RestoredRectangle -Initial $initial -Restored $restored
    $restoredDivider = Wait-ForSplitDividerLayout `
        -ParentHandle $windowHandle `
        -TabBarHandle $tabBarHandle `
        -DividerHandle $dividerHandle
    Write-Verbose "Validated the final restored layout."

    Send-TestKey `
        -Handle $surfaceHandle `
        -VirtualKey $vkF7 `
        -Description "new window"
    Wait-ForCondition -Description "a second top-level window" -Condition {
        @(Get-ProcessTopLevelWindows -ProcessId $process.Id).Count -eq 2
    }
    $secondWindowHandle = @(
        Get-ProcessTopLevelWindows -ProcessId $process.Id |
            Where-Object { $_ -ne $windowHandle }
    )[0]
    $secondShellEligibility = Test-ShellEligibility -Handle $secondWindowHandle
    $secondSurfaceHandle = [GhosttyWindowStateNative]::GetWindow(
        $secondWindowHandle,
        $gwChild
    )
    if ($secondSurfaceHandle -eq [IntPtr]::Zero) {
        throw "The second Ghostty surface child window was not found."
    }
    $secondTabBarHandle = Wait-ForOwnedProcessWindow `
        -ProcessId $process.Id `
        -ClassName "GhosttyTabBar" `
        -OwnerHandle $secondWindowHandle
    $null = Wait-ForTabBarLayout `
        -ParentHandle $secondWindowHandle `
        -TabBarHandle $secondTabBarHandle

    Set-TestConfig `
        -Path $configPath `
        -TabBarMode "never"
    Send-TestKey `
        -Handle $surfaceHandle `
        -VirtualKey $vkF6 `
        -Description "multi-window config reload"
    Wait-ForCondition -Description "both tab bars to hide after config reload" -Condition {
        -not [GhosttyWindowStateNative]::IsWindowVisible($tabBarHandle) -and
            -not [GhosttyWindowStateNative]::IsWindowVisible($secondTabBarHandle)
    }

    Set-TestConfig `
        -Path $configPath `
        -TabBarMode "always"
    Send-TestKey `
        -Handle $surfaceHandle `
        -VirtualKey $vkF6 `
        -Description "multi-window config reload"
    Wait-ForCondition -Description "both tab bars to return after config reload" -Condition {
        [GhosttyWindowStateNative]::IsWindowVisible($tabBarHandle) -and
            [GhosttyWindowStateNative]::IsWindowVisible($secondTabBarHandle)
    }
    $null = Wait-ForTabBarLayout `
        -ParentHandle $windowHandle `
        -TabBarHandle $tabBarHandle
    $null = Wait-ForTabBarLayout `
        -ParentHandle $secondWindowHandle `
        -TabBarHandle $secondTabBarHandle
    Write-Verbose "Validated config reload across both windows."

    Send-TestKey `
        -Handle $surfaceHandle `
        -VirtualKey $vkF9 `
        -Description "next window"
    Wait-ForCondition -Description "focus navigation to the second window" -Condition {
        [GhosttyWindowStateNative]::GetFocusedRootWindow($windowHandle) -eq `
            $secondWindowHandle
    }
    Send-TestKey `
        -Handle $secondSurfaceHandle `
        -VirtualKey $vkF9 `
        -Description "wrapped next window"
    Wait-ForCondition -Description "wrapped focus navigation to the original window" -Condition {
        [GhosttyWindowStateNative]::GetFocusedRootWindow($windowHandle) -eq `
            $windowHandle
    }

    Send-TestKey `
        -Handle $surfaceHandle `
        -VirtualKey $vkF10 `
        -Description "hide all windows"
    Wait-ForCondition -Description "both windows to hide" -Condition {
        -not [GhosttyWindowStateNative]::IsWindowVisible($windowHandle) -and
            -not [GhosttyWindowStateNative]::IsWindowVisible($secondWindowHandle)
    }
    Send-TestKey `
        -Handle $surfaceHandle `
        -VirtualKey $vkF10 `
        -Description "restore all windows"
    Wait-ForCondition -Description "both windows to return" -Condition {
        [GhosttyWindowStateNative]::IsWindowVisible($windowHandle) -and
            [GhosttyWindowStateNative]::IsWindowVisible($secondWindowHandle)
    }
    Write-Verbose "Validated window navigation and visibility toggle."

    if (-not [GhosttyWindowStateNative]::PostMessageW(
        $secondWindowHandle,
        $wmClose,
        [UIntPtr]::Zero,
        [IntPtr]::Zero
    )) {
        throw "Failed to close the second Ghostty window."
    }
    Wait-ForCondition -Description "the individual second-window close" -Condition {
        -not [GhosttyWindowStateNative]::IsWindow($secondWindowHandle)
    }
    $process.Refresh()
    if ($process.HasExited -or
        -not [GhosttyWindowStateNative]::IsWindow($windowHandle)) {
        throw "Closing the second window also closed the original window or process."
    }

    Send-TestKey `
        -Handle $surfaceHandle `
        -VirtualKey $vkF7 `
        -Description "new window"
    Wait-ForCondition -Description "the recreated second top-level window" -Condition {
        @(Get-ProcessTopLevelWindows -ProcessId $process.Id).Count -eq 2
    }
    $recreatedWindowHandle = @(
        Get-ProcessTopLevelWindows -ProcessId $process.Id |
            Where-Object { $_ -ne $windowHandle }
    )[0]
    $multiWindow = [pscustomobject]@{
        Created = $true
        SecondWindowHandle = $secondWindowHandle
        SecondShellEligibility = $secondShellEligibility
        Navigation = $true
        HiddenTogether = $true
        RestoredTogether = $true
        ConfigReloadHidden = $true
        ConfigReloadRestored = $true
        IndividualClose = $true
        OriginalSurvived = $true
        Recreated = $true
        RecreatedWindowHandle = $recreatedWindowHandle
        CloseAll = $false
    }
    Write-Verbose "Validated new-window creation and individual close."

    Send-TestKey `
        -Handle $surfaceHandle `
        -VirtualKey $vkF8 `
        -Description "close all windows"
    if (-not $process.WaitForExit($timeoutMilliseconds)) {
        throw "Ghostty did not exit after close_all_windows."
    }
    if ($process.ExitCode -ne 0) {
        throw "Ghostty exited with code $($process.ExitCode)."
    }
    $multiWindow.CloseAll = $true

    $completed = $true
    [pscustomobject]@{
        Executable = $executablePath
        ProcessId = $process.Id
        WindowHandle = $windowHandle
        TabBarHandle = $tabBarHandle
        DividerHandle = $dividerHandle
        ShellEligibility = $shellEligibility
        MultiWindow = $multiWindow
        TerminalInput = $terminalInput
        GpuRecovery = $gpuRecovery
        ConfigReload = $configReload
        InitialTabBar = $initialTabBar
        InitialDivider = $initialDivider
        MonitorLayouts = $monitorLayouts
        Initial = $initial
        Maximized = $maximized
        MaximizedDivider = $maximizedDivider
        RestoredFromMinimize = "Maximized"
        Restored = $restored
        RestoredDivider = $restoredDivider
        ExitCode = $process.ExitCode
        ForcedTermination = $forcedTermination
        StdoutLog = $stdoutPath
        StderrLog = $stderrPath
    }
} finally {
    if ($null -ne $process -and -not $process.HasExited) {
        if ($KeepOpenOnFailure -and -not $completed) {
            Write-Warning "Leaving test process $($process.Id) open for inspection."
        } else {
            if ($windowHandle -ne [IntPtr]::Zero) {
                $null = [GhosttyWindowStateNative]::PostMessageW(
                    $windowHandle,
                    $wmClose,
                    [UIntPtr]::Zero,
                    [IntPtr]::Zero
                )
            }
            if (-not $process.WaitForExit($timeoutMilliseconds)) {
                Stop-Process -Id $process.Id -Force
                $forcedTermination = $true
            }
        }
    }
    $null = [GhosttyWindowStateNative]::SetThreadDpiAwarenessContext(
        $previousDpiAwareness
    )
    if ($null -eq $process -or $process.HasExited) {
        if ([System.IO.File]::Exists($inputMarkerPath)) {
            [System.IO.File]::Delete($inputMarkerPath)
        }
        if ([System.IO.File]::Exists($gpuRecoveryMarkerPath)) {
            [System.IO.File]::Delete($gpuRecoveryMarkerPath)
        }
        if ([System.IO.File]::Exists($configPath)) {
            [System.IO.File]::Delete($configPath)
        }
        if ([System.IO.Directory]::Exists($sessionDirectory)) {
            [System.IO.Directory]::Delete($sessionDirectory, $false)
        }
    } elseif ($KeepOpenOnFailure) {
        Write-Warning "Keeping test config for the open process: $configPath"
    }
}
