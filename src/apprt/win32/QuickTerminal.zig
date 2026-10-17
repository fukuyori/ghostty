//! The quick terminal for the Win32 runtime: a single, lazily created,
//! captionless topmost window shown and hidden by `toggle_quick_terminal`.
//!
//! The window is a tool window, so it has no taskbar button and no Alt+Tab
//! entry. Its shell and splits survive while it is hidden; it is destroyed
//! only when its last shell exits or every window is closed. Geometry comes
//! from the `quick-terminal-*` settings and the work area of the selected
//! monitor. See docs/windows.md for the Windows meaning of each setting.
const std = @import("std");
const win32 = @import("win32").everything;
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const WindowLayout = @import("WindowLayout.zig");
const WindowLifecycle = @import("WindowLifecycle.zig");

const log = std.log.scoped(.win32);

/// App-owned quick terminal state.
pub const State = struct {
    /// Foreground window when the quick terminal was last shown with
    /// activation. An explicit hide returns to it.
    previous_foreground: ?win32.HWND = null,
    /// Monitor selected when the window was last shown. Layout updates keep
    /// it, so a `mouse` screen does not chase the cursor while shown.
    monitor: ?win32.HMONITOR = null,
    /// `quick-terminal-screen` value `monitor` was selected for.
    screen: Config.QuickTerminalScreen = .main,
    /// Guards against autohide while the window is already being hidden.
    hiding: bool = false,
};

pub const HideReason = enum { explicit, autohide };

pub fn find(app: *App) ?*Window {
    for (app.windows.items) |window| {
        if (window.quick) return window;
    }
    return null;
}

pub fn toggle(app: *App) !bool {
    if (find(app)) |window| {
        if (win32.IsWindowVisible(window.hwnd) != 0) {
            hide(app, window, .explicit);
        } else {
            show(app, window);
        }
        return true;
    }

    try WindowLifecycle.createWindow(app, .{ .quick = true });
    const window = find(app) orelse return false;
    show(app, window);
    return true;
}

/// Native creation style for the quick terminal window.
pub fn exStyle(config: *const Config, base: win32.WINDOW_EX_STYLE) win32.WINDOW_EX_STYLE {
    var style = base;
    style.TOOLWINDOW = 1;
    style.TOPMOST = 1;
    style.NOACTIVATE = @intFromBool(keyboardDisabledFor(config));
    return style;
}

/// `quick-terminal-keyboard-interactivity = none` keeps keyboard focus away
/// from the quick terminal, including on mouse clicks.
pub fn keyboardDisabled(app: *const App, window: *const Window) bool {
    return window.quick and keyboardDisabledFor(app.config);
}

/// Whether `surface` may take native keyboard focus. Every programmatic
/// focus change goes through this so `keyboard-interactivity = none` holds.
pub fn allowsFocus(surface: *Surface) bool {
    const app = surface.rtApp();
    const window = app.windowForSurface(surface) orelse return true;
    return !keyboardDisabled(app, window);
}

fn keyboardDisabledFor(config: *const Config) bool {
    return config.@"quick-terminal-keyboard-interactivity" == .none;
}

pub fn show(app: *App, window: *Window) void {
    const activate = !keyboardDisabledFor(app.config);
    if (activate) {
        // Remember whichever window was in front, including another
        // Ghostty window, so an explicit hide returns to it.
        const foreground = win32.GetForegroundWindow();
        app.quick_terminal.previous_foreground = if (foreground) |hwnd|
            if (hwnd != window.hwnd) hwnd else null
        else
            null;
    }
    app.quick_terminal.screen = app.config.@"quick-terminal-screen";
    app.quick_terminal.monitor = selectMonitor(app.quick_terminal.screen);
    if (!place(app, window)) return;
    // ShowWindow, unlike SWP_SHOWWINDOW, sends WM_SHOWWINDOW, which resumes
    // rendering after the occlusion caused by hiding.
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNA);
    for (window.tabs.items) |tab| {
        for (tab.surfaces.items) |surface| surface.shown = true;
    }
    WindowLayout.layoutWindow(app, window);
    if (activate) {
        // Windows can refuse foreground activation when another process
        // holds the foreground lock. The window is still shown topmost.
        _ = win32.SetForegroundWindow(window.hwnd);
        _ = win32.SetFocus(window.focusedSurface().hwnd);
    }
}

pub fn hide(app: *App, window: *Window, reason: HideReason) void {
    if (app.quick_terminal.hiding) return;
    if (win32.IsWindowVisible(window.hwnd) == 0) return;
    app.quick_terminal.hiding = true;
    defer app.quick_terminal.hiding = false;

    const restore = takeRestoreTarget(app, window, reason);
    // Activate the previous application while the quick terminal still
    // owns the foreground, which is when Windows permits the change.
    if (restore) |hwnd| _ = win32.SetForegroundWindow(hwnd);
    _ = win32.ShowWindow(window.hwnd, win32.SW_HIDE);
    quitIfUnreachable(app);
}

/// A hidden quick terminal with no other window and no registered global
/// keybinding can never be shown again, so the application quits as it does
/// after its last window closes. Running processes are confirmed first like
/// `quit`; declining shows the quick terminal again.
pub fn quitIfUnreachable(app: *App) void {
    if (app.windows.items.len == 0) return;
    if (app.global_hotkeys.count() > 0) return;
    for (app.windows.items) |window| {
        if (!window.quick) return;
        if (win32.IsWindowVisible(window.hwnd) != 0) return;
    }
    log.info("quick terminal is hidden with no other window or global keybinding; quitting", .{});
    _ = WindowLifecycle.queueCloseAllWith(app, .{
        .all = true,
        .quit = true,
        .snapshot_session = true,
        .show_quick_on_cancel = true,
    });
}

/// Called before the quick terminal window is destroyed.
pub fn destroying(app: *App, window: *Window) void {
    if (takeRestoreTarget(app, window, .explicit)) |hwnd| {
        _ = win32.SetForegroundWindow(hwnd);
    }
    app.quick_terminal = .{};
}

fn takeRestoreTarget(app: *App, window: *Window, reason: HideReason) ?win32.HWND {
    const previous = app.quick_terminal.previous_foreground;
    app.quick_terminal.previous_foreground = null;
    if (reason != .explicit) return null;
    const hwnd = previous orelse return null;
    if (win32.IsWindow(hwnd) == 0) return null;
    // The user already moved elsewhere; do not take the foreground back.
    if (win32.GetForegroundWindow() != window.hwnd) return null;
    return hwnd;
}

/// WM_ACTIVATE for the quick terminal window.
pub fn activationChanged(app: *App, window: *Window, active: bool, other: ?win32.HWND) void {
    if (active) return;
    if (other) |hwnd| {
        if (ownedBy(hwnd, window.hwnd)) return;
    }
    if (app.config.@"quick-terminal-autohide") hide(app, window, .autohide);
}

fn ownedBy(hwnd: win32.HWND, owner: win32.HWND) bool {
    // Confirmation and rename dialogs are owned by the quick terminal and
    // must not hide it.
    const root = win32.GetAncestor(hwnd, win32.GA_ROOTOWNER) orelse return false;
    return root == owner;
}

/// Reapply configured geometry and style, for example after a config reload,
/// a DPI change, or a monitor or work-area change.
pub fn refresh(app: *App, window: *Window) void {
    applyExStyle(app, window);
    if (win32.IsWindowVisible(window.hwnd) == 0) return;
    if (keyboardDisabledFor(app.config)) releaseFocus(app, window);
    // A changed screen setting selects a monitor again; other refreshes
    // keep the monitor chosen when the window was shown.
    const screen = app.config.@"quick-terminal-screen";
    if (screen != app.quick_terminal.screen or !monitorValid(app.quick_terminal.monitor)) {
        app.quick_terminal.monitor = selectMonitor(screen);
        app.quick_terminal.screen = screen;
    }
    if (place(app, window)) WindowLayout.layoutWindow(app, window);
}

/// Give up keyboard focus after a reload to `keyboard-interactivity = none`.
fn releaseFocus(app: *App, window: *Window) void {
    if (win32.GetForegroundWindow() != window.hwnd) return;
    if (takeRestoreTarget(app, window, .explicit)) |hwnd| {
        if (win32.SetForegroundWindow(hwnd) != 0) return;
    }
    _ = win32.SetFocus(null);
}

fn applyExStyle(app: *App, window: *Window) void {
    const current: u32 = @truncate(@as(usize, @bitCast(win32.GetWindowLongPtrW(window.hwnd, win32.GWL_EXSTYLE))));
    const wanted: u32 = @bitCast(exStyle(app.config, @bitCast(current)));
    if (current == wanted) return;
    _ = win32.SetWindowLongPtrW(window.hwnd, win32.GWL_EXSTYLE, @bitCast(@as(usize, wanted)));
}

fn place(app: *App, window: *Window) bool {
    const work = workArea(app.quick_terminal.monitor) orelse {
        log.warn("quick terminal monitor unavailable", .{});
        return false;
    };
    const rect = frame(
        app.config.@"quick-terminal-position",
        app.config.@"quick-terminal-size",
        work,
    );
    if (win32.SetWindowPos(
        window.hwnd,
        win32.HWND_TOPMOST,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        .{ .NOACTIVATE = 1 },
    ) == 0) {
        log.warn("SetWindowPos(quick terminal) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }
    return true;
}

fn selectMonitor(screen: Config.QuickTerminalScreen) ?win32.HMONITOR {
    switch (screen) {
        .mouse => {
            var point: win32.POINT = .{ .x = 0, .y = 0 };
            if (win32.GetCursorPos(&point) != 0) {
                return win32.MonitorFromPoint(point, win32.MONITOR_DEFAULTTONEAREST);
            }
            log.warn("GetCursorPos failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        },
        // Windows has no menu bar screen; follow Linux and use the main one.
        .main, .@"macos-menu-bar" => {},
    }
    return win32.MonitorFromPoint(.{ .x = 0, .y = 0 }, win32.MONITOR_DEFAULTTOPRIMARY);
}

fn monitorValid(monitor: ?win32.HMONITOR) bool {
    return workArea(monitor) != null;
}

fn workArea(monitor: ?win32.HMONITOR) ?win32.RECT {
    const handle = monitor orelse return null;
    var info: win32.MONITORINFO = .{
        .cbSize = @sizeOf(win32.MONITORINFO),
        .rcMonitor = std.mem.zeroes(win32.RECT),
        .rcWork = std.mem.zeroes(win32.RECT),
        .dwFlags = 0,
    };
    if (win32.GetMonitorInfoW(handle, &info) == 0) return null;
    return info.rcWork;
}

/// The quick terminal rectangle inside a monitor work area. Sizes are device
/// pixels; the result is clamped to the work area.
pub fn frame(
    position: Config.QuickTerminalPosition,
    size: Config.QuickTerminalSize,
    work: win32.RECT,
) win32.RECT {
    const work_width = @max(work.right - work.left, 1);
    const work_height = @max(work.bottom - work.top, 1);
    const dims = size.calculate(position, .{
        .width = @intCast(work_width),
        .height = @intCast(work_height),
    });
    const width: i32 = @intCast(std.math.clamp(dims.width, 1, @as(u32, @intCast(work_width))));
    const height: i32 = @intCast(std.math.clamp(dims.height, 1, @as(u32, @intCast(work_height))));
    const center_x = work.left + @divTrunc(work_width - width, 2);
    const center_y = work.top + @divTrunc(work_height - height, 2);
    const origin: win32.POINT = switch (position) {
        .top => .{ .x = center_x, .y = work.top },
        .bottom => .{ .x = center_x, .y = work.bottom - height },
        .left => .{ .x = work.left, .y = center_y },
        .right => .{ .x = work.right - width, .y = center_y },
        .center => .{ .x = center_x, .y = center_y },
    };
    return .{
        .left = origin.x,
        .top = origin.y,
        .right = origin.x + width,
        .bottom = origin.y + height,
    };
}

test "Win32 quick terminal frame uses the monitor work area" {
    const testing = std.testing;
    // A secondary monitor left of the primary, with a 40 px taskbar on top.
    const work: win32.RECT = .{ .left = -1920, .top = 40, .right = 0, .bottom = 1080 };

    const top = frame(.top, .{}, work);
    try testing.expectEqual(win32.RECT{ .left = -1920, .top = 40, .right = 0, .bottom = 440 }, top);

    const bottom = frame(.bottom, .{ .primary = .{ .percentage = 50 } }, work);
    try testing.expectEqual(win32.RECT{ .left = -1920, .top = 560, .right = 0, .bottom = 1080 }, bottom);

    const right = frame(.right, .{ .primary = .{ .pixels = 600 }, .secondary = .{ .percentage = 50 } }, work);
    try testing.expectEqual(win32.RECT{ .left = -600, .top = 300, .right = 0, .bottom = 820 }, right);

    // Upstream calculate() uses width as the centered primary axis on a
    // landscape work area.
    const center = frame(.center, .{ .primary = .{ .percentage = 50 } }, work);
    try testing.expectEqual(win32.RECT{ .left = -1440, .top = 360, .right = -480, .bottom = 760 }, center);
}

test "Win32 quick terminal frame clamps oversized and empty sizes" {
    const testing = std.testing;
    const work: win32.RECT = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };

    const oversized = frame(.left, .{ .primary = .{ .pixels = 5000 }, .secondary = .{ .pixels = 5000 } }, work);
    try testing.expectEqual(win32.RECT{ .left = 0, .top = 0, .right = 800, .bottom = 600 }, oversized);

    const empty = frame(.top, .{ .primary = .{ .pixels = 0 } }, work);
    try testing.expectEqual(win32.RECT{ .left = 0, .top = 0, .right = 800, .bottom = 1 }, empty);

    const degenerate = frame(.center, .{}, .{ .left = 10, .top = 10, .right = 10, .bottom = 10 });
    try testing.expectEqual(win32.RECT{ .left = 10, .top = 10, .right = 11, .bottom = 11 }, degenerate);
}
