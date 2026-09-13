//! Native Windows titlebar appearance derived from Ghostty configuration.

const std = @import("std");
const win32 = @import("win32").everything;
const Config = @import("../../config/Config.zig");

const log = std.log.scoped(.win32_titlebar);

const Appearance = struct {
    dark: bool,
    caption_color: u32 = dwm_color_default,
    text_color: u32 = dwm_color_default,
};

/// Apply the configured light/dark preference and optional Ghostty colors to
/// the native non-client area. Color attributes are supported by Windows 11;
/// older systems retain their native colors while still attempting dark mode.
pub fn apply(hwnd: win32.HWND, config: *const Config) void {
    const value = appearance(config);

    var dark: win32.BOOL = if (value.dark) win32.TRUE else win32.FALSE;
    setAttribute(hwnd, dwmwa_use_immersive_dark_mode, &dark) catch |err|
        log.debug("native titlebar theme unavailable: {}", .{err});

    var caption_color = value.caption_color;
    setAttribute(hwnd, dwmwa_caption_color, &caption_color) catch |err|
        log.debug("native titlebar caption color unavailable: {}", .{err});

    var text_color = value.text_color;
    setAttribute(hwnd, dwmwa_text_color, &text_color) catch |err|
        log.debug("native titlebar text color unavailable: {}", .{err});
}

fn appearance(config: *const Config) Appearance {
    const caption_background = config.@"window-titlebar-background" orelse
        config.background;
    const dark = switch (config.@"window-theme") {
        .auto => config.background
            .toTerminalRGB()
            .perceivedLuminance() <= 0.5,
        .ghostty => caption_background
            .toTerminalRGB()
            .perceivedLuminance() <= 0.5,
        // TRUE opts the frame into following the Windows dark-mode setting.
        .system => true,
        .dark => true,
        .light => false,
    };

    if (config.@"window-theme" != .ghostty) return .{ .dark = dark };

    return .{
        .dark = dark,
        .caption_color = colorRef(caption_background),
        .text_color = colorRef(
            config.@"window-titlebar-foreground" orelse config.foreground,
        ),
    };
}

fn colorRef(color: Config.Color) u32 {
    // COLORREF stores bytes in 0x00BBGGRR order.
    return @as(u32, color.r) |
        (@as(u32, color.g) << 8) |
        (@as(u32, color.b) << 16);
}

fn setAttribute(
    hwnd: win32.HWND,
    attribute: u32,
    value: *const anyopaque,
) error{SetWindowAttribute}!void {
    const result = DwmSetWindowAttribute(hwnd, attribute, value, @sizeOf(u32));
    if (!win32.SUCCEEDED(result)) return error.SetWindowAttribute;
}

const dwmwa_use_immersive_dark_mode: u32 = 20;
const dwmwa_caption_color: u32 = 35;
const dwmwa_text_color: u32 = 36;
const dwm_color_default: u32 = 0xFFFFFFFF;

extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: win32.HWND,
    attribute: u32,
    value: *const anyopaque,
    value_size: u32,
) callconv(.winapi) win32.HRESULT;

test "Win32 titlebar auto theme follows terminal background" {
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();

    config.@"window-theme" = .auto;
    config.background = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    try std.testing.expect(appearance(&config).dark);

    config.background = .{ .r = 0xEE, .g = 0xEE, .b = 0xEE };
    try std.testing.expect(!appearance(&config).dark);
}

test "Win32 Ghostty titlebar uses configured colors" {
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();

    config.@"window-theme" = .ghostty;
    config.background = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
    config.@"window-titlebar-background" = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
    config.@"window-titlebar-foreground" = .{ .r = 0xAB, .g = 0xCD, .b = 0xEF };

    const value = appearance(&config);
    try std.testing.expect(value.dark);
    try std.testing.expectEqual(@as(u32, 0x00563412), value.caption_color);
    try std.testing.expectEqual(@as(u32, 0x00EFCDAB), value.text_color);
}

test "Win32 native titlebar attributes match the DWM ABI" {
    try std.testing.expectEqual(@as(u32, 20), dwmwa_use_immersive_dark_mode);
    try std.testing.expectEqual(@as(u32, 35), dwmwa_caption_color);
    try std.testing.expectEqual(@as(u32, 36), dwmwa_text_color);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), dwm_color_default);
}
