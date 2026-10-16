//! Opt-in, observation-only tracing for partial IME commits (#48).
//! Requires -Dwin32-test-hooks=true and GHOSTTY_TEST_IME_TRACE=1.
//! Records sizes and positions, never composition text or WM_CHAR values.
const std = @import("std");
const win32 = @import("win32").everything;
const build_config = @import("../../build_config.zig");
const global = @import("../../global.zig");
const Surface = @import("Surface.zig");
const log = std.log.scoped(.win32_ime_trace);

// This timer belongs to the terminal child, not the app's wakeup window.
const timer_id = 0x494D45;
/// Test-only snapshot request. wParam is an integer correlation ID.
pub const WM_QUERY = win32.WM_USER + 113;
var enabled = false;

pub const State = struct {
    active: bool = false,
    last: ?Snapshot = null,
};

const Snapshot = struct {
    tracking: bool,
    column: u16,
    row: u16,
    x: i32,
    y: i32,
    form_valid: bool,
    style: u32,
    form_x: i32,
    form_y: i32,
    composition_bytes: i32,
    result_bytes: i32,
};

pub fn init(value: bool) void {
    enabled = build_config.win32_test_hooks and value;
}

pub fn stop(surface: *Surface) void {
    if (comptime !build_config.win32_test_hooks) return;
    if (!surface.ime_diagnostics.active) return;
    _ = win32.KillTimer(surface.hwnd, timer_id);
    surface.ime_diagnostics = .{};
}

/// Observe messages before normal dispatch. All IME messages still go to
/// DefWindowProc; this module never changes the composition or its position.
pub fn message(surface: *Surface, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
    if (comptime !build_config.win32_test_hooks) return;
    if (!enabled) return;
    const event: []const u8 = switch (msg) {
        win32.WM_IME_STARTCOMPOSITION => event: {
            surface.ime_diagnostics = .{ .active = true };
            if (win32.SetTimer(surface.hwnd, timer_id, 16, null) == 0)
                log.warn("could not start cursor observation timer", .{});
            break :event "start";
        },
        win32.WM_IME_COMPOSITION => "composition",
        win32.WM_IME_ENDCOMPOSITION => "end",
        win32.WM_CHAR => "char",
        win32.WM_KILLFOCUS => "focus-lost",
        WM_QUERY => "query",
        win32.WM_TIMER => if (wparam == timer_id and surface.ime_diagnostics.active) "cursor-poll" else return,
        else => return,
    };
    record(surface, event, if (msg == win32.WM_IME_COMPOSITION) @bitCast(lparam) else if (msg == WM_QUERY) wparam else 0, msg == win32.WM_TIMER);
    if (msg == win32.WM_IME_ENDCOMPOSITION or msg == win32.WM_KILLFOCUS) stop(surface);
}

fn record(surface: *Surface, event: []const u8, flags: usize, changed_only: bool) void {
    const core = surface.core_surface orelse return;
    const cursor = cursor: {
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        const cursor = core.renderer_state.terminal.screens.active.cursor;
        break :cursor .{ .x = cursor.x, .y = cursor.y };
    };
    const context = win32.ImmGetContext(surface.hwnd) orelse return;
    defer _ = win32.ImmReleaseContext(surface.hwnd, context);
    var form = std.mem.zeroes(win32.COMPOSITIONFORM);
    const form_valid = win32.ImmGetCompositionWindow(context, &form) != 0;
    const snapshot: Snapshot = .{
        .tracking = surface.ime_composing,
        .column = cursor.x,
        .row = cursor.y,
        .x = @intCast(cursor.x * core.size.cell.width + core.size.padding.left),
        .y = @intCast(cursor.y * core.size.cell.height + core.size.padding.top),
        .form_valid = form_valid,
        .style = form.dwStyle,
        .form_x = form.ptCurrentPos.x,
        .form_y = form.ptCurrentPos.y,
        .composition_bytes = win32.ImmGetCompositionStringW(context, win32.GCS_COMPSTR, null, 0),
        .result_bytes = win32.ImmGetCompositionStringW(context, win32.GCS_RESULTSTR, null, 0),
    };
    if (changed_only) {
        if (surface.ime_diagnostics.last) |last| {
            if (std.meta.eql(last, snapshot)) return;
        }
    }
    surface.ime_diagnostics.last = snapshot;
    log.info("tick={d} hwnd={x} event={s} flags=0x{x} cursor={d},{d} point={d},{d} form_valid={} style=0x{x} form={d},{d} comp_bytes={d} result_bytes={d} tracking={}", .{
        win32.GetTickCount64(),     @intFromPtr(surface.hwnd), event,             flags,
        snapshot.column,            snapshot.row,              snapshot.x,        snapshot.y,
        snapshot.form_valid,        snapshot.style,            snapshot.form_x,   snapshot.form_y,
        snapshot.composition_bytes, snapshot.result_bytes,     snapshot.tracking,
    });
}
