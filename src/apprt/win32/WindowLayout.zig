//! Win32 pane, search, scrollbar, and tab-bar placement, plus size and DPI
//! changes. SplitDivider owns divider placement; TabBarController manages
//! the tab-bar viewport and invalidation.

const std = @import("std");
const win32 = @import("win32").everything;
const apprt = @import("../../apprt.zig");
const Config = @import("../../config.zig").Config;
const App = @import("App.zig");
const WndProc = @import("WndProc.zig");
const TabBarController = @import("TabBarController.zig");
const Surface = @import("Surface.zig");
const SplitDivider = @import("SplitDivider.zig");
const TabBar = @import("TabBar.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

pub fn layoutWindow(self: *App, window: *Window) void {
    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(window.hwnd, &client) == 0) {
        log.warn("GetClientRect for window layout failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return;
    }

    const client_width = @max(0, client.right - client.left);
    const tab_height = if (tabBarVisible(self, window))
        TabBar.heightForDpi(windowDpi(window.hwnd))
    else
        0;
    TabBarController.updateViewport(window, client_width, tab_height);

    if (window.tab_bar_hwnd) |tab_bar| {
        if (tab_height > 0) {
            var origin: win32.POINT = .{ .x = 0, .y = 0 };
            if (win32.ClientToScreen(window.hwnd, &origin) == 0) {
                log.warn("ClientToScreen(tab bar) failed: err={d}", .{
                    @intFromEnum(win32.GetLastError()),
                });
                return;
            }
            if (win32.SetWindowPos(
                tab_bar,
                null,
                origin.x,
                origin.y,
                client_width,
                tab_height,
                .{ .NOZORDER = 1, .NOACTIVATE = 1, .SHOWWINDOW = 1 },
            ) == 0) {
                log.warn("SetWindowPos(tab bar) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            }
            TabBarController.invalidate(window);
        } else {
            _ = win32.ShowWindow(tab_bar, win32.SW_HIDE);
        }
    }

    const rects = self.alloc.alloc(Window.LeafRect, window.activeSurfaceCount()) catch |err| {
        log.warn("failed to allocate window layout: {}", .{err});
        return;
    };
    defer self.alloc.free(rects);

    const content_bounds = windowContentBounds(self, window, client);
    const divider_gap = SplitDivider.gap(window);
    const count = window.layout(
        content_bounds,
        divider_gap,
        rects,
    );
    for (rects[0..count]) |entry| {
        const search_height = if (entry.view.search_bar) |bar|
            bar.layout(entry.rect.x, entry.rect.y, entry.rect.width, entry.rect.height, windowDpi(window.hwnd))
        else
            0;
        if (win32.SetWindowPos(
            entry.view.hwnd,
            null,
            entry.rect.x,
            entry.rect.y + search_height,
            entry.rect.width,
            entry.rect.height - search_height,
            .{ .NOZORDER = 1, .NOACTIVATE = 1 },
        ) == 0) {
            log.warn("SetWindowPos(surface layout) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
        if (entry.view.scrollbar) |bar| {
            bar.layout(entry.rect.x, entry.rect.y + search_height, entry.rect.width, entry.rect.height - search_height, true);
        }
    }

    var surfaces = window.surfaceIterator();
    while (surfaces.next()) |surface| {
        var visible = false;
        for (rects[0..count]) |entry| {
            if (entry.view == surface) {
                visible = true;
                break;
            }
        }
        _ = win32.ShowWindow(
            surface.hwnd,
            if (visible) win32.SW_SHOWNA else win32.SW_HIDE,
        );
        if (surface.search_bar) |bar| {
            _ = win32.ShowWindow(bar.hwnd.?, if (visible and bar.active) win32.SW_SHOWNA else win32.SW_HIDE);
        }
        if (!visible) {
            if (surface.scrollbar) |bar| bar.hide();
        }
    }

    SplitDivider.layout(self, window, content_bounds, divider_gap);
}

pub fn tabBarVisible(self: *const App, window: *const Window) bool {
    // Auxiliary HWND creation can fail while the terminal remains usable.
    // Reserve no strip that would otherwise have no window to paint it.
    if (window.tab_bar_hwnd == null) return false;
    return tabBarVisibleForMode(
        self.config.@"window-show-tab-bar",
        window.tabCount(),
        window.activeTabIsZoomed(),
    );
}

fn tabBarVisibleForMode(
    mode: Config.WindowShowTabBar,
    tab_count: usize,
    zoomed: bool,
) bool {
    return switch (mode) {
        .always => true,
        .auto => tab_count > 1 or zoomed,
        .never => false,
    };
}

pub fn windowContentBounds(
    self: *const App,
    window: *const Window,
    client: win32.RECT,
) Window.Rect {
    const tab_height = if (tabBarVisible(self, window))
        TabBar.heightForDpi(windowDpi(window.hwnd))
    else
        0;
    return .{
        .x = 0,
        .y = tab_height,
        .width = @max(0, client.right - client.left),
        .height = @max(0, client.bottom - client.top - tab_height),
    };
}

pub fn windowDpi(hwnd: win32.HWND) u32 {
    const dpi = win32.GetDpiForWindow(hwnd);
    return if (dpi == 0) 96 else dpi;
}

pub fn currentWindowContentBounds(
    app: *const App,
    window: *const Window,
) ?Window.Rect {
    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(window.hwnd, &client) == 0) {
        log.warn("GetClientRect(split pointer) failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
        return null;
    }
    return windowContentBounds(app, window, client);
}

fn dpiScale(wparam: win32.WPARAM) apprt.ContentScale {
    const default_dpi: f32 = @floatFromInt(win32.USER_DEFAULT_SCREEN_DPI);
    const x: u16 = @truncate(wparam);
    const y: u16 = @truncate(wparam >> 16);
    return .{
        .x = @as(f32, @floatFromInt(x)) / default_dpi,
        .y = @as(f32, @floatFromInt(y)) / default_dpi,
    };
}

fn handleDpiChanged(
    surface: *Surface,
    hwnd: win32.HWND,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) void {
    if (surface.core_surface) |core| {
        core.contentScaleCallback(dpiScale(wparam)) catch |err| {
            log.err("content scale callback error: {}", .{err});
        };
    }

    if (lparam == 0) return;
    const rect: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (win32.SetWindowPos(
        hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        .{ .NOZORDER = 1, .NOACTIVATE = 1 },
    ) == 0) {
        log.warn("SetWindowPos for DPI change failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    }
}

pub fn sizeChanged(hwnd: win32.HWND, lparam: win32.LPARAM) win32.LRESULT {
    if (WndProc.getSurface(hwnd)) |surface| {
        const width: u32 = @intCast(lparam & 0xFFFF);
        const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
        if (width > 0 and height > 0) {
            if (hwnd == surface.windowHwnd()) {
                const app = surface.rtApp();
                if (app.windowForHwnd(hwnd)) |window| layoutWindow(app, window);
            } else if (hwnd == surface.hwnd) {
                surface.width = width;
                surface.height = height;
                if (surface.core_surface) |core| {
                    core.sizeCallback(.{
                        .width = width,
                        .height = height,
                    }) catch |err| {
                        log.err("size callback error: {}", .{err});
                    };
                }
            }
        }
    }
    return 0;
}

pub fn moved(hwnd: win32.HWND) win32.LRESULT {
    if (WndProc.getSurface(hwnd)) |surface| {
        if (hwnd == surface.windowHwnd()) {
            const app = surface.rtApp();
            if (app.windowForHwnd(hwnd)) |window| {
                layoutWindow(app, window);
            }
        }
    }
    return 0;
}

pub fn dpiChanged(hwnd: win32.HWND, wparam: win32.WPARAM, lparam: win32.LPARAM) win32.LRESULT {
    if (WndProc.getSurface(hwnd)) |surface| {
        if (hwnd == surface.windowHwnd()) {
            const app = surface.rtApp();
            if (app.windowForHwnd(hwnd)) |window| {
                var surfaces = window.surfaceIterator();
                while (surfaces.next()) |candidate| {
                    if (candidate == surface) continue;
                    if (candidate.core_surface) |core| {
                        core.contentScaleCallback(dpiScale(wparam)) catch |err| {
                            log.err("content scale callback error: {}", .{err});
                        };
                    }
                }
                handleDpiChanged(surface, hwnd, wparam, lparam);
                layoutWindow(app, window);
                return 0;
            }
        }
    }
    return 0;
}

test "Win32 automatic tab bar exposes split zoom state" {
    try std.testing.expect(!tabBarVisibleForMode(.auto, 1, false));
    try std.testing.expect(tabBarVisibleForMode(.auto, 2, false));
    try std.testing.expect(tabBarVisibleForMode(.auto, 1, true));
    try std.testing.expect(!tabBarVisibleForMode(.never, 2, true));
    try std.testing.expect(tabBarVisibleForMode(.always, 1, false));
}

test "decode Win32 DPI scale" {
    const wparam = @as(usize, 192) << 16 | 144;
    try std.testing.expectEqual(
        apprt.ContentScale{ .x = 1.5, .y = 2.0 },
        dpiScale(wparam),
    );
}
