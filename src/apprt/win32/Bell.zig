//! BEL handling for the Win32 runtime, following `bell-features`:
//!
//! - `system`: the Windows default sound (MessageBeep).
//! - `attention`: flash the taskbar button until the window comes to the
//!   foreground, when the window is not already in front.
//! - `title`: a bell emoji before the tab and window title until the pane is
//!   focused or typed in.
//!
//! `audio` and `border` are not supported on Windows.
const std = @import("std");
const win32 = @import("win32").everything;
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const TabBarController = @import("TabBarController.zig");

/// Prefix shown before the title of a tab with a ringing bell.
pub const title_prefix = "🔔 ";

pub fn ring(app: *App, surface: *Surface) void {
    const features = app.config.@"bell-features";
    const window = app.windowForSurface(surface) orelse return;
    const foreground = win32.GetForegroundWindow() == window.hwnd;

    if (features.system) _ = win32.MessageBeep(0); // MB_OK: default sound

    if (features.attention and !foreground) {
        var info: win32.FLASHWINFO = .{
            .cbSize = @sizeOf(win32.FLASHWINFO),
            .hwnd = window.hwnd,
            // FLASHW_TRAY | FLASHW_TIMERNOFG
            .dwFlags = @bitCast(@as(u32, 0x0E)),
            .uCount = 0,
            .dwTimeout = 0,
        };
        _ = win32.FlashWindowEx(&info);
    }

    if (features.title and !(foreground and win32.GetFocus() == surface.hwnd) and !surface.bell_ringing) {
        surface.bell_ringing = true;
        refresh(app, surface);
    }
}

/// Remove the bell from the title, after focus or typing in the pane.
pub fn clear(surface: *Surface) void {
    if (!surface.bell_ringing) return;
    surface.bell_ringing = false;
    refresh(surface.rtApp(), surface);
}

fn refresh(app: *App, surface: *Surface) void {
    const window = app.windowForSurface(surface) orelse return;
    TabBarController.invalidate(window);
    window.focusedSurface().syncTitle();
}

/// The title with the bell prefix, or `title` itself when not ringing.
/// The caller frees a prefixed result.
pub fn decorate(alloc: std.mem.Allocator, title: [:0]const u8, ringing: bool) ![:0]const u8 {
    if (!ringing) return title;
    return std.mem.concatWithSentinel(alloc, u8, &.{ title_prefix, title }, 0);
}

test "Win32 bell title prefix" {
    const testing = std.testing;
    const plain = try decorate(testing.allocator, "pwsh", false);
    try testing.expectEqualStrings("pwsh", plain);
    const ringing = try decorate(testing.allocator, "pwsh", true);
    defer testing.allocator.free(ringing);
    try testing.expectEqualStrings("🔔 pwsh", ringing);
}
