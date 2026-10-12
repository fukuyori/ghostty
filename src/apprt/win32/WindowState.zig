//! Window state for the Win32 runtime: maximize, fullscreen, decorations,
//! always-on-top, and window sizing. Window-level state lives on the window's
//! state surface (see `App.windowStateSurface`).

const std = @import("std");
const win32 = @import("win32").everything;
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const TabBar = @import("TabBar.zig");

const log = std.log.scoped(.win32);

pub fn toggleMaximize(target: apprt.Target) bool {
    const target_surface = App.targetSurface(target) orelse {
        log.warn("toggle_maximize targeted the application", .{});
        return false;
    };
    const surface = App.windowStateSurface(target_surface);
    if (surface.fullscreen) return true;
    const hwnd = surface.windowHwnd();

    _ = win32.ShowWindow(
        hwnd,
        if (win32.IsZoomed(hwnd) != 0)
            win32.SW_RESTORE
        else
            win32.SW_MAXIMIZE,
    );
    return true;
}

pub fn toggleFullscreen(
    target: apprt.Target,
    mode: apprt.action.Fullscreen,
) bool {
    _ = mode;
    const target_surface = App.targetSurface(target) orelse {
        log.warn("toggle_fullscreen targeted the application", .{});
        return false;
    };
    const surface = App.windowStateSurface(target_surface);
    return setFullscreen(surface, !surface.fullscreen);
}

pub fn setFullscreen(surface: *Surface, enabled: bool) bool {
    if (surface.fullscreen == enabled) return true;
    return if (enabled)
        enterFullscreen(surface)
    else
        leaveFullscreen(surface);
}

pub fn enterFullscreen(surface: *Surface) bool {
    const hwnd = surface.windowHwnd();
    var placement: win32.WINDOWPLACEMENT = std.mem.zeroes(win32.WINDOWPLACEMENT);
    placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    if (win32.GetWindowPlacement(hwnd, &placement) == 0) {
        log.warn("GetWindowPlacement failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }
    const style = getWindowStyle(hwnd) orelse return false;

    const monitor = win32.MonitorFromWindow(
        hwnd,
        win32.MONITOR_DEFAULTTONEAREST,
    ) orelse {
        log.warn("MonitorFromWindow failed", .{});
        return false;
    };
    var info: win32.MONITORINFO = .{
        .cbSize = @sizeOf(win32.MONITORINFO),
        .rcMonitor = std.mem.zeroes(win32.RECT),
        .rcWork = std.mem.zeroes(win32.RECT),
        .dwFlags = 0,
    };
    if (win32.GetMonitorInfoW(monitor, &info) == 0) {
        log.warn("GetMonitorInfoW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }

    const fullscreen_style = styleWithDecorations(style, false);
    if (!setWindowStyle(hwnd, fullscreen_style)) return false;

    const rect = info.rcMonitor;
    if (win32.SetWindowPos(
        hwnd,
        if (surface.always_on_top) win32.HWND_TOPMOST else null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        .{ .NOOWNERZORDER = 1, .DRAWFRAME = 1 },
    ) == 0) {
        log.warn("SetWindowPos entering fullscreen failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        _ = setWindowStyle(hwnd, style);
        _ = win32.SetWindowPlacement(hwnd, &placement);
        _ = refreshWindowFrame(hwnd);
        return false;
    }

    surface.windowed_style = style;
    surface.windowed_placement = placement;
    surface.fullscreen = true;
    return true;
}

pub fn leaveFullscreen(surface: *Surface) bool {
    const hwnd = surface.windowHwnd();
    const saved_style = surface.windowed_style orelse {
        log.warn("fullscreen window has no saved style", .{});
        return false;
    };
    const placement = surface.windowed_placement orelse {
        log.warn("fullscreen window has no saved placement", .{});
        return false;
    };
    const current_style = getWindowStyle(hwnd) orelse return false;
    const restored_style = styleWithDecorations(
        saved_style,
        surface.decorated,
    );
    if (!setWindowStyle(hwnd, restored_style)) return false;

    if (win32.SetWindowPlacement(hwnd, &placement) == 0) {
        log.warn("SetWindowPlacement leaving fullscreen failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        _ = setWindowStyle(hwnd, current_style);
        return false;
    }
    if (!refreshWindowFrame(hwnd)) return false;

    surface.fullscreen = false;
    surface.windowed_style = null;
    surface.windowed_placement = null;
    return true;
}

pub fn toggleWindowDecorations(target: apprt.Target) bool {
    const target_surface = App.targetSurface(target) orelse {
        log.warn("toggle_window_decorations targeted the application", .{});
        return false;
    };
    const surface = App.windowStateSurface(target_surface);
    return setWindowDecorations(surface, !surface.decorated);
}

pub fn setWindowDecorations(surface: *Surface, decorated: bool) bool {
    if (surface.decorated == decorated) return true;

    // A fullscreen window is intentionally borderless. Remember the requested
    // state and apply it to the saved window style when fullscreen exits.
    if (surface.fullscreen) {
        surface.decorated = decorated;
        return true;
    }

    const hwnd = surface.windowHwnd();
    const old_style = getWindowStyle(hwnd) orelse return false;
    const new_style = styleWithDecorations(old_style, decorated);
    if (!setWindowStyle(hwnd, new_style)) return false;
    if (!refreshWindowFrame(hwnd)) {
        _ = setWindowStyle(hwnd, old_style);
        _ = refreshWindowFrame(hwnd);
        return false;
    }

    surface.decorated = decorated;
    return true;
}

pub fn styleWithDecorations(style: u32, decorated: bool) u32 {
    const mask: u32 = @bitCast(win32.WS_OVERLAPPEDWINDOW);
    return if (decorated) style | mask else style & ~mask;
}

pub fn getWindowStyle(hwnd: win32.HWND) ?u32 {
    win32.SetLastError(.NO_ERROR);
    const value = win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE);
    if (value == 0 and win32.GetLastError() != .NO_ERROR) {
        log.warn("GetWindowLongPtrW(GWL_STYLE) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return null;
    }
    return @truncate(@as(usize, @bitCast(value)));
}

fn setWindowStyle(hwnd: win32.HWND, style: u32) bool {
    win32.SetLastError(.NO_ERROR);
    const value = win32.SetWindowLongPtrW(
        hwnd,
        win32.GWL_STYLE,
        @bitCast(@as(usize, style)),
    );
    if (value == 0 and win32.GetLastError() != .NO_ERROR) {
        log.warn("SetWindowLongPtrW(GWL_STYLE) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }
    return true;
}

fn refreshWindowFrame(hwnd: win32.HWND) bool {
    if (win32.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        0,
        0,
        .{
            .NOMOVE = 1,
            .NOSIZE = 1,
            .NOZORDER = 1,
            .NOACTIVATE = 1,
            .DRAWFRAME = 1,
        },
    ) == 0) {
        log.warn("SetWindowPos refreshing frame failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }
    return true;
}

pub fn floatWindow(
    target: apprt.Target,
    mode: apprt.action.FloatWindow,
) bool {
    const target_surface = App.targetSurface(target) orelse {
        log.warn("float_window targeted the application", .{});
        return false;
    };
    const surface = App.windowStateSurface(target_surface);
    const enabled = switch (mode) {
        .on => true,
        .off => false,
        .toggle => !surface.always_on_top,
    };
    if (enabled == surface.always_on_top) return true;

    return setAlwaysOnTop(surface, enabled);
}

pub fn setAlwaysOnTop(surface: *Surface, enabled: bool) bool {
    if (win32.SetWindowPos(
        surface.windowHwnd(),
        if (enabled) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST,
        0,
        0,
        0,
        0,
        .{ .NOMOVE = 1, .NOSIZE = 1, .NOACTIVATE = 1 },
    ) == 0) {
        log.warn("SetWindowPos changing topmost state failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }

    surface.always_on_top = enabled;
    return true;
}

pub fn setInitialSize(
    target: apprt.Target,
    value: apprt.action.InitialSize,
) bool {
    const target_surface = App.targetSurface(target) orelse {
        log.warn("initial_size targeted the application", .{});
        return false;
    };
    if (value.width == 0 or value.height == 0) return false;

    const surface = App.windowStateSurface(target_surface);
    if (surface != target_surface) return true;

    surface.initial_client_size = value;
    if (!surface.shown) return resizeClientArea(surface, value);
    return true;
}

pub fn resetWindowSize(target: apprt.Target) bool {
    const target_surface = App.targetSurface(target) orelse {
        log.warn("reset_window_size targeted the application", .{});
        return false;
    };
    const surface = App.windowStateSurface(target_surface);
    if (surface.fullscreen) return false;

    if (surface.default_maximized) {
        _ = win32.ShowWindow(surface.windowHwnd(), win32.SW_MAXIMIZE);
        return true;
    }

    const size = surface.initial_client_size orelse return false;
    if (win32.IsZoomed(surface.windowHwnd()) != 0) {
        _ = win32.ShowWindow(surface.windowHwnd(), win32.SW_RESTORE);
    }
    return resizeClientArea(surface, size);
}

fn resizeClientArea(
    surface: *Surface,
    size: apprt.action.InitialSize,
) bool {
    const hwnd = surface.windowHwnd();
    const style_bits: u32 = @truncate(@as(
        usize,
        @bitCast(win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE)),
    ));
    const ex_style_bits: u32 = @truncate(@as(
        usize,
        @bitCast(win32.GetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE)),
    ));
    const style: win32.WINDOW_STYLE = @bitCast(style_bits);
    const ex_style: win32.WINDOW_EX_STYLE = @bitCast(ex_style_bits);

    const max_dimension: u32 = @intCast(std.math.maxInt(i32) / 2);
    var rect: win32.RECT = .{
        .left = 0,
        .top = 0,
        .right = @intCast(@min(size.width, max_dimension)),
        .bottom = @intCast(@min(size.height, max_dimension)),
    };
    const dpi = dpi: {
        const value = win32.GetDpiForWindow(hwnd);
        break :dpi if (value > 0) value else win32.USER_DEFAULT_SCREEN_DPI;
    };
    if (surface.rtApp().windowForSurface(surface)) |window| {
        if (surface.rtApp().tabBarVisible(window)) {
            rect.bottom = @min(
                std.math.maxInt(i32),
                rect.bottom + TabBar.heightForDpi(dpi),
            );
        }
    }
    if (win32.AdjustWindowRectExForDpi(
        &rect,
        style,
        0,
        ex_style,
        dpi,
    ) == 0) {
        log.warn("AdjustWindowRectExForDpi failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }

    return setWindowExtent(hwnd, .{
        .width = rect.right - rect.left,
        .height = rect.bottom - rect.top,
    });
}

/// Resize the window so that the target surface becomes the requested size,
/// as requested by the running program (CSI 8 t). See
/// `apprt.action.ResizeWindow`. Like the GTK runtime, this only resizes a
/// window whose only surface is the target, and only while the window is in
/// its normal state: not maximized, minimized, fullscreen, or snapped.
pub fn resizeWindow(
    target: apprt.Target,
    value: apprt.action.ResizeWindow,
) bool {
    const surface = App.targetSurface(target) orelse {
        log.warn("resize_window targeted the application", .{});
        return false;
    };
    const window = surface.rtApp().windowForSurface(surface) orelse return false;
    if (window.totalSurfaceCount() != 1) return false;
    if (surface.fullscreen) return false;

    const hwnd = surface.windowHwnd();
    if (win32.IsZoomed(hwnd) != 0 or win32.IsIconic(hwnd) != 0) return false;

    var rect: win32.RECT = undefined;
    if (win32.GetWindowRect(hwnd, &rect) == 0) {
        log.warn("GetWindowRect failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }
    const current: WindowExtent = .{
        .width = rect.right - rect.left,
        .height = rect.bottom - rect.top,
    };
    if (isSnapped(hwnd, current)) return false;

    // The requested size is in points of the surface's content scale. Resize
    // the window by the change in device pixels so the title bar, tab bar,
    // and borders keep their size.
    const scale = surface.getContentScale() catch return false;
    const size = surface.getSize() catch return false;
    return setWindowExtent(hwnd, .{
        .width = current.width + resizeDelta(value.width, scale.x, size.width),
        .height = current.height + resizeDelta(value.height, scale.y, size.height),
    });
}

/// Returns the change in device pixels from the current size to the
/// requested size in points, or zero if the requested size is zero.
fn resizeDelta(requested: u32, scale: f32, current: u32) i32 {
    if (requested == 0) return 0;
    const px = @as(f32, @floatFromInt(requested)) * scale;
    const max: f32 = @floatFromInt(std.math.maxInt(i32) / 2);
    return @as(i32, @intFromFloat(@round(@min(px, max)))) -
        @as(i32, @intCast(@min(current, std.math.maxInt(i32) / 2)));
}

/// Whether the window is snapped to a screen edge or into a snap layout.
/// A snapped window keeps its restore size in the placement, so its actual
/// size differs from it. `IsWindowArranged` would answer this directly but
/// is not available on every supported Windows 10 release.
fn isSnapped(hwnd: win32.HWND, current: WindowExtent) bool {
    var placement: win32.WINDOWPLACEMENT = std.mem.zeroes(win32.WINDOWPLACEMENT);
    placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    if (win32.GetWindowPlacement(hwnd, &placement) == 0) {
        log.warn("GetWindowPlacement failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return true;
    }
    const normal = placement.rcNormalPosition;
    return normal.right - normal.left != current.width or
        normal.bottom - normal.top != current.height;
}

/// Resize the window to the given outer size, limited to the work area of
/// its monitor, without moving it.
fn setWindowExtent(hwnd: win32.HWND, extent: WindowExtent) bool {
    var outer = extent;
    if (win32.MonitorFromWindow(
        hwnd,
        win32.MONITOR_DEFAULTTONEAREST,
    )) |monitor| {
        var info: win32.MONITORINFO = .{
            .cbSize = @sizeOf(win32.MONITORINFO),
            .rcMonitor = std.mem.zeroes(win32.RECT),
            .rcWork = std.mem.zeroes(win32.RECT),
            .dwFlags = 0,
        };
        if (win32.GetMonitorInfoW(monitor, &info) != 0) {
            outer = clampWindowExtent(outer, info.rcWork);
        } else {
            log.warn("GetMonitorInfoW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
    }

    if (win32.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        outer.width,
        outer.height,
        .{ .NOMOVE = 1, .NOZORDER = 1, .NOACTIVATE = 1 },
    ) == 0) {
        log.warn("SetWindowPos resizing the window failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }
    return true;
}

const WindowExtent = struct {
    width: i32,
    height: i32,
};

fn clampWindowExtent(extent: WindowExtent, work_area: win32.RECT) WindowExtent {
    const work_width = @max(work_area.right - work_area.left, 1);
    const work_height = @max(work_area.bottom - work_area.top, 1);
    return .{
        .width = std.math.clamp(extent.width, 1, work_width),
        .height = std.math.clamp(extent.height, 1, work_height),
    };
}

test "Win32 resize_window delta in device pixels" {
    try std.testing.expectEqual(@as(i32, 0), resizeDelta(0, 1.5, 900));
    try std.testing.expectEqual(@as(i32, 100), resizeDelta(800, 1.0, 700));
    try std.testing.expectEqual(@as(i32, -150), resizeDelta(400, 1.5, 750));
    try std.testing.expectEqual(@as(i32, 2), resizeDelta(668, 1.5, 1000));
}

test "clamp Win32 window size to monitor work area" {
    const work_area: win32.RECT = .{
        .left = 0,
        .top = 40,
        .right = 1920,
        .bottom = 1080,
    };

    try std.testing.expectEqual(
        WindowExtent{ .width = 800, .height = 600 },
        clampWindowExtent(.{ .width = 800, .height = 600 }, work_area),
    );
    try std.testing.expectEqual(
        WindowExtent{ .width = 1920, .height = 1040 },
        clampWindowExtent(.{ .width = 3000, .height = 2000 }, work_area),
    );
    try std.testing.expectEqual(
        WindowExtent{ .width = 1, .height = 1 },
        clampWindowExtent(.{ .width = 0, .height = -1 }, work_area),
    );
}

test "toggle Win32 decoration style bits" {
    const base: u32 = @bitCast(win32.WINDOW_STYLE{
        .VISIBLE = 1,
        .MAXIMIZE = 1,
        .BORDER = 1,
        .DLGFRAME = 1,
        .SYSMENU = 1,
        .THICKFRAME = 1,
        .GROUP = 1,
        .TABSTOP = 1,
    });
    const undecorated: win32.WINDOW_STYLE = @bitCast(
        styleWithDecorations(base, false),
    );
    try std.testing.expectEqual(@as(u1, 1), undecorated.VISIBLE);
    try std.testing.expectEqual(@as(u1, 1), undecorated.MAXIMIZE);
    try std.testing.expectEqual(@as(u1, 0), undecorated.BORDER);
    try std.testing.expectEqual(@as(u1, 0), undecorated.DLGFRAME);
    try std.testing.expectEqual(@as(u1, 0), undecorated.SYSMENU);
    try std.testing.expectEqual(@as(u1, 0), undecorated.THICKFRAME);

    const decorated: win32.WINDOW_STYLE = @bitCast(styleWithDecorations(
        @bitCast(undecorated),
        true,
    ));
    try std.testing.expectEqual(@as(u1, 1), decorated.VISIBLE);
    try std.testing.expectEqual(@as(u1, 1), decorated.MAXIMIZE);
    try std.testing.expectEqual(@as(u1, 1), decorated.BORDER);
    try std.testing.expectEqual(@as(u1, 1), decorated.DLGFRAME);
    try std.testing.expectEqual(@as(u1, 1), decorated.SYSMENU);
    try std.testing.expectEqual(@as(u1, 1), decorated.THICKFRAME);
}
