//! Terminal mouse input, capture, wheel handling, and system cursors.
const std = @import("std");
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const App = @import("App.zig");
const ContextMenu = @import("ContextMenu.zig");
const Keyboard = @import("Keyboard.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const win32 = @import("win32").everything;
const terminal = @import("../../terminal/main.zig");
const Surface = @import("Surface.zig");
const log = std.log.scoped(.win32);

/// Shared system cursors follow the user's pointer theme and size. Shapes
/// without a Windows equivalent use the nearest available system cursor.
pub fn cursor(shape: terminal.MouseShape) ?win32.HCURSOR {
    return win32.LoadCursorW(null, switch (shape) {
        .default, .context_menu, .alias, .copy, .zoom_in, .zoom_out => win32.IDC_ARROW,
        .help => win32.IDC_HELP,
        .pointer, .grab, .grabbing => win32.IDC_HAND,
        .progress => win32.IDC_APPSTARTING,
        .wait => win32.IDC_WAIT,
        .cell, .crosshair => win32.IDC_CROSS,
        .text, .vertical_text => win32.IDC_IBEAM,
        .move, .all_scroll => win32.IDC_SIZEALL,
        .no_drop, .not_allowed => win32.IDC_NO,
        .col_resize, .e_resize, .w_resize, .ew_resize => win32.IDC_SIZEWE,
        .row_resize, .n_resize, .s_resize, .ns_resize => win32.IDC_SIZENS,
        .ne_resize, .sw_resize, .nesw_resize => win32.IDC_SIZENESW,
        .nw_resize, .se_resize, .nwse_resize => win32.IDC_SIZENWSE,
    });
}

pub fn apply(surface: *Surface) void {
    _ = win32.SetCursor(if (surface.mouse_visible) cursor(surface.mouse_shape) else null);
}

/// Refresh only while the pointer belongs to this pane. Never alter the
/// process-wide ShowCursor counter or hide the cursor over native controls.
pub fn refresh(surface: *Surface) void {
    var point: win32.POINT = undefined;
    if (win32.GetCursorPos(&point) == 0 or win32.WindowFromPoint(point) != surface.hwnd) return;
    _ = win32.SendMessageW(surface.hwnd, win32.WM_SETCURSOR, @intFromPtr(surface.hwnd), win32.HTCLIENT);
}

pub fn setShape(target: apprt.Target, value: apprt.Action.Value(.mouse_shape)) bool {
    const surface = App.targetSurface(target) orelse return false;
    surface.mouse_shape = value;
    refresh(surface);
    return true;
}

pub fn setVisibility(target: apprt.Target, value: apprt.Action.Value(.mouse_visibility)) bool {
    const surface = App.targetSurface(target) orelse return false;
    surface.mouse_visible = value == .visible;
    refresh(surface);
    return true;
}

pub const MouseButtonEvent = struct {
    button: input.MouseButton,
    state: input.MouseButtonState,
    bit: u8,
    xbutton: bool = false,
};

pub fn mouseButtonEvent(msg: u32, wparam: win32.WPARAM) ?MouseButtonEvent {
    return switch (msg) {
        win32.WM_LBUTTONDOWN => .{ .button = .left, .state = .press, .bit = 1 << 0 },
        win32.WM_LBUTTONUP => .{ .button = .left, .state = .release, .bit = 1 << 0 },
        win32.WM_RBUTTONDOWN => .{ .button = .right, .state = .press, .bit = 1 << 1 },
        win32.WM_RBUTTONUP => .{ .button = .right, .state = .release, .bit = 1 << 1 },
        win32.WM_MBUTTONDOWN => .{ .button = .middle, .state = .press, .bit = 1 << 2 },
        win32.WM_MBUTTONUP => .{ .button = .middle, .state = .release, .bit = 1 << 2 },
        win32.WM_XBUTTONDOWN, win32.WM_XBUTTONUP => x: {
            const xbutton: u16 = @truncate(wparam >> 16);
            const state: input.MouseButtonState = if (msg == win32.WM_XBUTTONDOWN)
                .press
            else
                .release;
            break :x switch (xbutton) {
                1 => .{ .button = .four, .state = state, .bit = 1 << 3, .xbutton = true },
                2 => .{ .button = .five, .state = state, .bit = 1 << 4, .xbutton = true },
                else => null,
            };
        },
        else => null,
    };
}

pub fn signedLowWord(value: usize) i16 {
    return @bitCast(@as(u16, @truncate(value)));
}

pub fn signedHighWord(value: usize) i16 {
    return @bitCast(@as(u16, @truncate(value >> 16)));
}

pub fn mousePoint(lparam: win32.LPARAM) apprt.CursorPos {
    const bits: usize = @bitCast(lparam);
    return .{
        .x = @floatFromInt(signedLowWord(bits)),
        .y = @floatFromInt(signedHighWord(bits)),
    };
}

pub fn mouseClientPoint(lparam: win32.LPARAM) win32.POINT {
    const bits: usize = @bitCast(lparam);
    return .{
        .x = signedLowWord(bits),
        .y = signedHighWord(bits),
    };
}

pub fn wheelDelta(wparam: win32.WPARAM) i16 {
    return signedHighWord(wparam);
}

fn accumulateWheelTicks(remainder: *i32, delta: i16) i32 {
    remainder.* += delta;
    const wheel_delta: i32 = @intCast(win32.WHEEL_DELTA);
    const ticks = @divTrunc(remainder.*, wheel_delta);
    remainder.* -= ticks * wheel_delta;
    return ticks;
}

pub fn updateCursorPosition(
    surface: *Surface,
    pos: apprt.CursorPos,
    mods: input.Mods,
    force: bool,
) void {
    const previous = surface.cursor_pos;
    surface.cursor_pos = pos;
    if (!force and previous.x == pos.x and previous.y == pos.y) return;

    const core = surface.core_surface orelse return;
    core.cursorPosCallback(pos, mods) catch |err| {
        log.err("cursor position callback error: {}", .{err});
    };
}

pub fn trackMouseLeave(surface: *Surface, hwnd: win32.HWND) void {
    if (surface.tracking_mouse_leave) return;

    var event: win32.TRACKMOUSEEVENT = .{
        .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
        .dwFlags = win32.TME_LEAVE,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    if (win32.TrackMouseEvent(&event) == 0) {
        log.warn("TrackMouseEvent failed: err={d}", .{@backingInt(win32.GetLastError())});
        return;
    }
    surface.tracking_mouse_leave = true;
}

pub fn handleMouseButton(
    surface: *Surface,
    hwnd: win32.HWND,
    event: MouseButtonEvent,
    lparam: win32.LPARAM,
) win32.LRESULT {
    const mods = Keyboard.getModifiers();
    updateCursorPosition(surface, mousePoint(lparam), mods, true);

    if (event.state == .press) {
        // Child windows never take keyboard focus on their own. Without this,
        // clicking an unfocused split leaves typing in the previously focused
        // pane, which makes the clicked pane look unresponsive. The surface
        // WM_SETFOCUS handler updates the window's active tab and focused
        // surface, so the tab bar follows along.
        // A quick terminal with keyboard interactivity `none` never takes
        // keyboard focus.
        const keep_focus = if (surface.rtApp().windowForSurface(surface)) |window|
            QuickTerminal.keyboardDisabled(surface.rtApp(), window)
        else
            false;
        if (!keep_focus and win32.GetFocus() != hwnd) _ = win32.SetFocus(hwnd);

        if (surface.mouse_buttons_down == 0) _ = win32.SetCapture(hwnd);
        surface.mouse_buttons_down |= event.bit;
    } else {
        surface.mouse_buttons_down &= ~event.bit;
    }

    if (surface.core_surface) |core| {
        const consumed = core.mouseButtonCallback(event.state, event.button, mods) catch |err| consumed: {
            log.err("mouse button callback error: {}", .{err});
            break :consumed true;
        };

        // The core leaves a right press unconsumed when right-click-action
        // is context-menu and the program is not capturing the mouse. Like
        // other Windows applications, open the menu on release.
        if (event.button == .right and event.state == .press) {
            surface.context_menu_pending = !consumed;
        }
    }

    if (event.state == .release and surface.mouse_buttons_down == 0 and
        win32.GetCapture() == hwnd)
    {
        if (win32.ReleaseCapture() == 0) {
            log.warn("ReleaseCapture failed: err={d}", .{@backingInt(win32.GetLastError())});
        }
    }

    if (event.state == .release and event.button == .right and surface.context_menu_pending) {
        surface.context_menu_pending = false;
        if (surface.core_surface) |core| {
            // The menu may close this surface, so nothing touches it afterwards.
            ContextMenu.show(surface.rtApp().alloc, hwnd, core, mouseClientPoint(lparam));
        }
        return 0;
    }

    // XBUTTON messages require TRUE to prevent further processing.
    return if (event.xbutton) 1 else 0;
}

pub fn releaseMouseButtons(surface: *Surface) void {
    const down = surface.mouse_buttons_down;
    if (down == 0) return;
    // Capture was taken away mid-click, so the right release that would open
    // the context menu is never coming.
    surface.context_menu_pending = false;
    surface.mouse_buttons_down = 0;

    const buttons = [_]struct { u8, input.MouseButton }{
        .{ 1 << 0, .left },
        .{ 1 << 1, .right },
        .{ 1 << 2, .middle },
        .{ 1 << 3, .four },
        .{ 1 << 4, .five },
    };
    const core = surface.core_surface orelse return;
    const mods = Keyboard.getModifiers();
    for (buttons) |entry| {
        if (down & entry[0] == 0) continue;
        _ = core.mouseButtonCallback(.release, entry[1], mods) catch |err| {
            log.err("mouse capture release callback error: {}", .{err});
        };
    }
}

fn updateWheelCursorPosition(
    surface: *Surface,
    hwnd: win32.HWND,
    lparam: win32.LPARAM,
    mods: input.Mods,
) void {
    const screen_pos = mousePoint(lparam);
    var point: win32.POINT = .{
        .x = @intFromFloat(screen_pos.x),
        .y = @intFromFloat(screen_pos.y),
    };
    if (win32.ScreenToClient(hwnd, &point) == 0) {
        log.warn("ScreenToClient failed: err={d}", .{@backingInt(win32.GetLastError())});
        return;
    }
    updateCursorPosition(surface, .{
        .x = @floatFromInt(point.x),
        .y = @floatFromInt(point.y),
    }, mods, true);
}

pub fn handleMouseWheel(
    surface: *Surface,
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) void {
    const mods = Keyboard.getModifiers();
    updateWheelCursorPosition(surface, hwnd, lparam, mods);

    const core = surface.core_surface orelse return;
    const delta: i32 = wheelDelta(wparam);
    if (msg == win32.WM_MOUSEWHEEL) {
        if (surface.scrollbar) |bar| bar.reveal();
        const ticks = @as(f64, @floatFromInt(delta)) /
            @as(f64, @floatFromInt(win32.WHEEL_DELTA));
        core.scrollCallback(0, ticks, .{}) catch |err| {
            log.err("vertical scroll callback error: {}", .{err});
        };
        return;
    }

    const ticks = accumulateWheelTicks(&surface.horizontal_wheel_remainder, @intCast(delta));
    if (ticks == 0) return;
    core.scrollCallback(@floatFromInt(ticks), 0, .{}) catch |err| {
        log.err("horizontal scroll callback error: {}", .{err});
    };
}

test "decode Win32 mouse coordinates and wheel delta" {
    const point = mousePoint(@bitCast(@as(usize, 0xFFEC_000A)));
    try std.testing.expectEqual(@as(f32, 10), point.x);
    try std.testing.expectEqual(@as(f32, -20), point.y);

    try std.testing.expectEqual(@as(i16, 120), wheelDelta(@as(usize, 120) << 16));
    try std.testing.expectEqual(@as(i16, -120), wheelDelta(@as(usize, 0xFF88) << 16));
}

test "map Win32 mouse buttons" {
    const left = mouseButtonEvent(win32.WM_LBUTTONDOWN, 0).?;
    try std.testing.expectEqual(input.MouseButton.left, left.button);
    try std.testing.expectEqual(input.MouseButtonState.press, left.state);

    const x2 = mouseButtonEvent(win32.WM_XBUTTONUP, @as(usize, 2) << 16).?;
    try std.testing.expectEqual(input.MouseButton.five, x2.button);
    try std.testing.expectEqual(input.MouseButtonState.release, x2.state);
    try std.testing.expect(x2.xbutton);
}

test "accumulate partial Win32 horizontal wheel ticks" {
    var remainder: i32 = 0;
    try std.testing.expectEqual(@as(i32, 0), accumulateWheelTicks(&remainder, 30));
    try std.testing.expectEqual(@as(i32, 30), remainder);
    try std.testing.expectEqual(@as(i32, 0), accumulateWheelTicks(&remainder, 60));
    try std.testing.expectEqual(@as(i32, 90), remainder);
    try std.testing.expectEqual(@as(i32, 1), accumulateWheelTicks(&remainder, 30));
    try std.testing.expectEqual(@as(i32, 0), remainder);
    try std.testing.expectEqual(@as(i32, -2), accumulateWheelTicks(&remainder, -240));
    try std.testing.expectEqual(@as(i32, 0), remainder);
}
