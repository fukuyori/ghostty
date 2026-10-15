//! Win32 window appearance policy and theme refresh. Composition objects
//! remain in Backdrop; App, Window, and Surface retain their state.

const std = @import("std");
const win32 = @import("win32").everything;
const build_config = @import("../../build_config.zig");
const Config = @import("../../config/Config.zig");
const App = @import("App.zig");
const WndProc = @import("WndProc.zig");
const TabBarController = @import("TabBarController.zig");
const WindowLayout = @import("WindowLayout.zig");
const Backdrop = @import("Backdrop.zig");
const Surface = @import("Surface.zig");
const SplitDivider = @import("SplitDivider.zig");
const Titlebar = @import("Titlebar.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

pub fn highContrastEnabled() bool {
    var contrast: win32.HIGHCONTRASTW = .{
        .cbSize = @sizeOf(win32.HIGHCONTRASTW),
        .dwFlags = .{},
        .lpszDefaultScheme = null,
    };
    if (win32.SystemParametersInfoW(
        win32.SPI_GETHIGHCONTRAST,
        @sizeOf(win32.HIGHCONTRASTW),
        &contrast,
        .{},
    ) == 0) return false;
    return contrast.dwFlags.HIGHCONTRASTON != 0;
}

pub fn refreshTheme(hwnd: win32.HWND) win32.LRESULT {
    if (WndProc.getSurface(hwnd)) |surface| {
        if (hwnd == surface.windowHwnd()) {
            const app = surface.rtApp();
            if (app.windowForHwnd(hwnd)) |window| {
                app.high_contrast = highContrastEnabled();
                Titlebar.apply(hwnd, app.config, app.high_contrast);
                var bars = window.surfaceIterator();
                while (bars.next()) |candidate| {
                    if (candidate.scrollbar) |bar| bar.setAppearance(app.config.background, app.high_contrast);
                }
                WindowLayout.layoutWindow(app, window);
                TabBarController.invalidate(window);
                SplitDivider.invalidate(window);
            }
        }
    }
    return 0;
}

/// Keep the native backdrop synchronized with the renderer's background
/// opacity and requested blur strength. Native backdrop composition is only
/// used with D3D11; OpenGL retains its existing transparent behavior.
pub fn updateWindowBackgroundBlur(surface: *Surface, config: *const Config) void {
    const radius = windowBackgroundBlurRadius(config);
    const app = surface.rtApp();
    const window = app.windowForSurface(surface) orelse {
        log.warn("background blur targeted an unowned surface", .{});
        return;
    };

    const value = radius orelse {
        disableWindowBackgroundBlur(window);
        return;
    };

    // A fixed DWM backdrop has no adjustable radius. It remains the fallback
    // for this window until blur is disabled and enabled again.
    if (window.dwm_backdrop_active) return;

    if (!window.host_backdrop_active) {
        Backdrop.setHostBackdrop(window.hwnd, true) catch |err| {
            log.warn("failed to enable Win32 host backdrop: {}", .{err});
            enableFallbackBackdrop(window);
            return;
        };
        window.host_backdrop_active = true;
    }

    var surfaces = window.surfaceIterator();
    while (surfaces.next()) |candidate| {
        if (candidate.background_blur) |*backdrop| {
            backdrop.setRadius(value) catch |err| {
                log.warn("failed to update Win32 background blur: {}", .{err});
                fallbackFromGaussianBackdrop(window);
                return;
            };
            continue;
        }

        candidate.background_blur = Backdrop.init(
            candidate.hwnd,
            value,
            &app.backdrop_runtime,
        ) catch |err| {
            log.warn("failed to apply Win32 background blur: {}", .{err});
            fallbackFromGaussianBackdrop(window);
            return;
        };
    }
}

fn releaseSurfaceBackdrops(window: *Window) void {
    var surfaces = window.surfaceIterator();
    while (surfaces.next()) |surface| {
        if (surface.background_blur) |*backdrop| backdrop.deinit();
        surface.background_blur = null;
    }
}

fn disableHostBackdrop(window: *Window) void {
    if (!window.host_backdrop_active) return;
    Backdrop.setHostBackdrop(window.hwnd, false) catch |err| {
        log.warn("failed to disable Win32 host backdrop: {}", .{err});
        return;
    };
    window.host_backdrop_active = false;
}

fn enableFallbackBackdrop(window: *Window) void {
    if (window.dwm_backdrop_active) return;
    Backdrop.setSystemBackdrop(window.hwnd, .transient_window) catch |err| {
        log.warn("failed to apply fixed Win32 Acrylic fallback: {}", .{err});
        return;
    };
    window.dwm_backdrop_active = true;
    log.warn("using fixed Win32 Acrylic because Gaussian backdrop is unavailable", .{});
}

fn fallbackFromGaussianBackdrop(window: *Window) void {
    releaseSurfaceBackdrops(window);
    disableHostBackdrop(window);
    enableFallbackBackdrop(window);
}

pub fn disableWindowBackgroundBlur(window: *Window) void {
    releaseSurfaceBackdrops(window);
    disableHostBackdrop(window);
    if (!window.dwm_backdrop_active) return;
    Backdrop.setSystemBackdrop(window.hwnd, .none) catch |err| {
        log.warn("failed to remove fixed Win32 Acrylic fallback: {}", .{err});
        return;
    };
    window.dwm_backdrop_active = false;
}

fn windowBackgroundBlurRadius(config: *const Config) ?u8 {
    if (build_config.renderer != .d3d11 or
        config.@"background-opacity" >= 1) return null;

    return switch (config.@"background-blur") {
        .false => null,
        .true, .@"macos-glass-regular", .@"macos-glass-clear" => 20,
        .radius => |value| if (value > 0) value else null,
    };
}

test "Win32 background blur requires D3D11 and transparent background" {
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();

    config.@"background-opacity" = 0.75;
    config.@"background-blur" = .true;
    try std.testing.expectEqual(
        if (build_config.renderer == .d3d11) @as(?u8, 20) else null,
        windowBackgroundBlurRadius(&config),
    );

    config.@"background-opacity" = 1;
    try std.testing.expectEqual(@as(?u8, null), windowBackgroundBlurRadius(&config));

    config.@"background-opacity" = 0.75;
    config.@"background-blur" = .false;
    try std.testing.expectEqual(@as(?u8, null), windowBackgroundBlurRadius(&config));

    config.@"background-blur" = .{ .radius = 0 };
    try std.testing.expectEqual(@as(?u8, null), windowBackgroundBlurRadius(&config));

    config.@"background-blur" = .{ .radius = 12 };
    try std.testing.expectEqual(
        if (build_config.renderer == .d3d11) @as(?u8, 12) else null,
        windowBackgroundBlurRadius(&config),
    );
}
