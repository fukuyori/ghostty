//! Win32 split-divider placement, painting, hit testing, pointer capture,
//! and drag handling. Window retains divider geometry and drag state.

const std = @import("std");
const win32 = @import("win32").everything;
const Config = @import("../../config.zig").Config;
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");
const Mouse = @import("Mouse.zig");
const NativeWindow = @import("NativeWindow.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const WindowLayout = @import("WindowLayout.zig");

const log = std.log.scoped(.win32);

const split_divider_logical_gap: i32 = 1;
const split_divider_high_contrast_logical_gap: i32 = 2;
const split_divider_hit_slop: i32 = 4;

pub fn layout(
    self: *App,
    window: *Window,
    bounds: Window.Rect,
    divider_gap: i32,
) void {
    const capacity = window.activeSurfaceCount() -| 1;
    const dividers = self.alloc.alloc(Window.Divider, capacity) catch |err| {
        log.warn("failed to allocate split divider layout: {}", .{err});
        hide(window, 0);
        return;
    };
    defer self.alloc.free(dividers);

    const count = window.dividers(bounds, divider_gap, dividers);
    window.split_dividers.clearRetainingCapacity();
    window.split_dividers.appendSlice(self.alloc, dividers[0..count]) catch |err| {
        log.warn("failed to retain split divider layout: {}", .{err});
        hide(window, 0);
        return;
    };

    while (window.split_divider_hwnds.items.len < count) {
        const hwnd = NativeWindow.createSplitDivider(window.hwnd) catch break;
        window.split_divider_hwnds.append(self.alloc, hwnd) catch |err| {
            log.warn("failed to retain split divider window: {}", .{err});
            _ = win32.DestroyWindow(hwnd);
            break;
        };
        _ = win32.SetWindowLongPtrW(
            hwnd,
            win32.GWLP_USERDATA,
            @bitCast(@intFromPtr(window)),
        );
    }

    var origin: win32.POINT = .{ .x = 0, .y = 0 };
    if (win32.ClientToScreen(window.hwnd, &origin) == 0) {
        log.warn("ClientToScreen(split dividers) failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
        hide(window, 0);
        return;
    }

    const visible_count = @min(count, window.split_divider_hwnds.items.len);
    for (window.split_divider_hwnds.items[0..visible_count], dividers[0..visible_count]) |hwnd, divider| {
        if (win32.SetWindowPos(
            hwnd,
            null,
            origin.x + divider.rect.x,
            origin.y + divider.rect.y,
            @max(1, divider.rect.width),
            @max(1, divider.rect.height),
            .{ .NOZORDER = 1, .NOACTIVATE = 1, .SHOWWINDOW = 1 },
        ) == 0) {
            log.warn("SetWindowPos(split divider) failed: err={d}", .{
                @intFromEnum(win32.GetLastError()),
            });
        }
        _ = win32.InvalidateRect(hwnd, null, win32.TRUE);
    }
    hide(window, visible_count);
}

pub fn hide(window: *const Window, first: usize) void {
    const start = @min(first, window.split_divider_hwnds.items.len);
    for (window.split_divider_hwnds.items[start..]) |hwnd| {
        _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
    }
}

fn splitDividerGapForDpi(dpi: u32, high_contrast: bool) i32 {
    const logical = if (high_contrast)
        split_divider_high_contrast_logical_gap
    else
        split_divider_logical_gap;
    return @intCast(@max(
        1,
        @divTrunc(@as(i64, logical) * dpi + 48, 96),
    ));
}

pub fn gap(window: *const Window) i32 {
    const app = window.focusedSurface().rtApp();
    return splitDividerGapForDpi(
        WindowLayout.windowDpi(window.hwnd),
        app.high_contrast,
    );
}

pub fn invalidate(window: *const Window) void {
    for (window.split_divider_hwnds.items) |hwnd| {
        if (win32.InvalidateRect(hwnd, null, win32.TRUE) != 0) {
            _ = win32.UpdateWindow(hwnd);
        }
    }
}

fn splitDividerColor(config: *const Config, hovered: bool, high_contrast: bool) u32 {
    if (high_contrast) {
        return win32.GetSysColor(if (hovered)
            win32.COLOR_HIGHLIGHT
        else
            win32.COLOR_WINDOWTEXT);
    }

    const foreground = config.@"window-titlebar-foreground" orelse config.foreground;
    const percent: u16 = if (hovered) 65 else 30;
    return colorRef(mixColor(config.background, foreground, percent));
}

fn mixColor(background: Config.Color, foreground: Config.Color, percent: u16) Config.Color {
    return .{
        .r = mixColorChannel(background.r, foreground.r, percent),
        .g = mixColorChannel(background.g, foreground.g, percent),
        .b = mixColorChannel(background.b, foreground.b, percent),
    };
}

fn mixColorChannel(background: u8, foreground: u8, percent: u16) u8 {
    return @intCast((@as(u16, background) * (100 - percent) +
        @as(u16, foreground) * percent) / 100);
}

fn colorRef(color: Config.Color) u32 {
    return @as(u32, color.r) |
        (@as(u32, color.g) << 8) |
        (@as(u32, color.b) << 16);
}

fn getSplitDividerWindow(hwnd: win32.HWND) ?*Window {
    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn paintSplitDivider(window: *Window, hwnd: win32.HWND, hdc: win32.HDC) void {
    const index = for (window.split_divider_hwnds.items, 0..) |candidate, value| {
        if (candidate == hwnd) break value;
    } else return;
    if (index >= window.split_dividers.items.len) return;

    const divider = window.split_dividers.items[index];
    const hovered = if (window.split_divider_hover) |value|
        value.split == divider.split
    else
        false;
    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(hwnd, &client) == 0) return;
    const app = window.focusedSurface().rtApp();
    const color = splitDividerColor(app.config, hovered, app.high_contrast);
    const brush = win32.CreateSolidBrush(color) orelse return;
    defer _ = win32.DeleteObject(brush);
    _ = win32.FillRect(hdc, &client, brush);
}

fn pointInWindowClient(
    surface: *Surface,
    source_hwnd: win32.HWND,
    local: win32.POINT,
) ?win32.POINT {
    var point = local;
    if (win32.ClientToScreen(source_hwnd, &point) == 0) {
        log.warn("ClientToScreen(split pointer) failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
        return null;
    }
    if (win32.ScreenToClient(surface.windowHwnd(), &point) == 0) {
        log.warn("ScreenToClient(split pointer) failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
        return null;
    }
    return point;
}

fn scaledSplitHitSlop(window: *const Window) i32 {
    const dpi: i64 = WindowLayout.windowDpi(window.hwnd);
    return @intCast(@max(
        1,
        @divTrunc(@as(i64, split_divider_hit_slop) * dpi + 95, 96),
    ));
}

fn splitMinimumExtent(
    window: *const Window,
    direction: Window.ResizeDirection,
) i32 {
    var result: i64 = 1;
    const surfaces = window.surfacesAt(window.activeTabIndex()) orelse return 1;
    for (surfaces) |surface| {
        const core = surface.core_surface orelse continue;
        const extent: i64 = switch (direction) {
            .horizontal => @as(i64, core.size.cell.width) * CoreSurface.min_window_width_cells +
                core.size.padding.left + core.size.padding.right,
            .vertical => @as(i64, core.size.cell.height) * CoreSurface.min_window_height_cells +
                core.size.padding.top + core.size.padding.bottom,
        };
        result = @max(result, extent);
    }
    return @intCast(@min(result, std.math.maxInt(i32)));
}

fn setSplitCursor(direction: Window.ResizeDirection) void {
    const cursor = win32.LoadCursorW(
        null,
        switch (direction) {
            .horizontal => win32.IDC_SIZEWE,
            .vertical => win32.IDC_SIZENS,
        },
    );
    if (cursor) |handle| _ = win32.SetCursor(handle);
}

fn dividerAtPoint(
    surface: *Surface,
    window: *Window,
    point: win32.POINT,
) ?Window.Divider {
    const app = surface.rtApp();
    const bounds = WindowLayout.currentWindowContentBounds(app, window) orelse return null;
    return window.dividerAt(
        bounds,
        gap(window),
        point.x,
        point.y,
        scaledSplitHitSlop(window),
    );
}

pub fn setHover(window: *Window, value: ?Window.Divider) void {
    if (std.meta.eql(window.split_divider_hover, value)) return;
    window.split_divider_hover = value;
    invalidate(window);
}

pub fn trackMouseLeave(window: *Window, hwnd: win32.HWND) void {
    if (window.split_divider_tracking_mouse_leave) return;
    var event: win32.TRACKMOUSEEVENT = .{
        .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
        .dwFlags = win32.TME_LEAVE,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    if (win32.TrackMouseEvent(&event) != 0) {
        window.split_divider_tracking_mouse_leave = true;
    }
}

pub fn updatePointer(
    surface: *Surface,
    hwnd: win32.HWND,
    lparam: win32.LPARAM,
) bool {
    const app = surface.rtApp();
    const window = app.windowForSurface(surface) orelse return false;
    const point = pointInWindowClient(
        surface,
        hwnd,
        Mouse.mouseClientPoint(lparam),
    ) orelse return false;

    if (window.split_divider_drag) |*drag| {
        if (drag.capture_hwnd != hwnd) return false;
        const delta = switch (drag.divider.direction) {
            .horizontal => point.x - drag.last_x,
            .vertical => point.y - drag.last_y,
        };
        drag.last_x = point.x;
        drag.last_y = point.y;
        if (delta != 0) {
            const bounds = WindowLayout.currentWindowContentBounds(app, window) orelse return true;
            if (window.resizeDivider(
                drag.divider,
                delta,
                bounds,
                gap(window),
                splitMinimumExtent(window, drag.divider.direction),
            )) WindowLayout.layoutWindow(app, window);
        }
        setSplitCursor(drag.divider.direction);
        return true;
    }

    setHover(window, dividerAtPoint(surface, window, point));
    if (window.split_divider_hover) |divider| {
        setSplitCursor(divider.direction);
        return true;
    }
    return false;
}

pub fn beginDrag(
    surface: *Surface,
    hwnd: win32.HWND,
    lparam: win32.LPARAM,
) bool {
    if (surface.mouse_buttons_down != 0) return false;
    const window = surface.rtApp().windowForSurface(surface) orelse return false;
    const point = pointInWindowClient(
        surface,
        hwnd,
        Mouse.mouseClientPoint(lparam),
    ) orelse return false;
    const divider = dividerAtPoint(surface, window, point) orelse return false;

    setHover(window, divider);
    window.split_divider_drag = .{
        .divider = divider,
        .last_x = point.x,
        .last_y = point.y,
        .capture_hwnd = hwnd,
    };
    _ = win32.SetCapture(hwnd);
    setSplitCursor(divider.direction);
    return true;
}

pub fn endDrag(
    surface: *Surface,
    hwnd: win32.HWND,
    lparam: win32.LPARAM,
) bool {
    const window = surface.rtApp().windowForSurface(surface) orelse return false;
    const drag = window.split_divider_drag orelse return false;
    if (drag.capture_hwnd != hwnd) return false;

    window.split_divider_drag = null;
    if (pointInWindowClient(surface, hwnd, Mouse.mouseClientPoint(lparam))) |point| {
        setHover(window, dividerAtPoint(surface, window, point));
    } else {
        setHover(window, null);
    }
    if (win32.GetCapture() == hwnd and win32.ReleaseCapture() == 0) {
        log.warn("ReleaseCapture(split divider) failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
    }
    return true;
}

pub fn cancelDrag(surface: *Surface, hwnd: win32.HWND) void {
    const window = surface.rtApp().windowForSurface(surface) orelse return;
    if (window.split_divider_drag) |drag| {
        if (drag.capture_hwnd != hwnd) return;
        window.split_divider_drag = null;
    }
    setHover(window, null);
}

pub fn clearPointer(window: *Window) void {
    const capture = if (window.split_divider_drag) |drag|
        drag.capture_hwnd
    else
        null;
    window.split_divider_drag = null;
    setHover(window, null);
    window.split_divider_tracking_mouse_leave = false;
    if (capture) |hwnd| {
        if (win32.GetCapture() == hwnd and win32.ReleaseCapture() == 0) {
            log.warn("ReleaseCapture(split reset) failed: err={d}", .{
                @intFromEnum(win32.GetLastError()),
            });
        }
    }
}

pub fn handleCursor(surface: *Surface) bool {
    const window = surface.rtApp().windowForSurface(surface) orelse return false;
    if (window.split_divider_drag) |drag| {
        setSplitCursor(drag.divider.direction);
        return true;
    }

    var point: win32.POINT = undefined;
    if (win32.GetCursorPos(&point) == 0 or
        win32.ScreenToClient(window.hwnd, &point) == 0)
    {
        return false;
    }
    setHover(window, dividerAtPoint(surface, window, point));
    if (window.split_divider_hover) |divider| {
        setSplitCursor(divider.direction);
        return true;
    }
    return false;
}

pub fn wndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_ERASEBKGND => return 1,
        win32.WM_NCHITTEST => return win32.HTTRANSPARENT,
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = std.mem.zeroes(win32.PAINTSTRUCT);
            const hdc = win32.BeginPaint(hwnd, &ps) orelse {
                _ = win32.EndPaint(hwnd, &ps);
                return 0;
            };
            if (getSplitDividerWindow(hwnd)) |window| {
                paintSplitDivider(window, hwnd, hdc);
            }
            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

test "Win32 split divider thickness follows DPI and high contrast" {
    try std.testing.expectEqual(@as(i32, 1), splitDividerGapForDpi(96, false));
    try std.testing.expectEqual(@as(i32, 2), splitDividerGapForDpi(144, false));
    try std.testing.expectEqual(@as(i32, 2), splitDividerGapForDpi(96, true));
    try std.testing.expectEqual(@as(i32, 3), splitDividerGapForDpi(144, true));
    try std.testing.expectEqual(@as(i32, 4), splitDividerGapForDpi(192, true));
}
