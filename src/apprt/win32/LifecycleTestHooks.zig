//! Opt-in regression controls for lifecycle rollback and IPC ownership.
//! Compiled out unless -Dwin32-test-hooks=true; enabled only by
//! GHOSTTY_TEST_LIFECYCLE=1. Messages accept integers, never external pointers.
const std = @import("std");
const win32 = @import("win32").everything;
const build_config = @import("../../build_config.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tree = @import("SplitTree.zig").SplitTree(Surface);
const IpcHandler = @import("IpcHandler.zig");

pub const WM_CONTROL = win32.WM_USER + 112;
pub const Point = enum(u8) {
    none,
    parent_hwnd,
    child_hwnd,
    tab_bar_hwnd,
    surface_init,
    window_init,
    window_append,
    tab_insert,
    split_insert,
    core_alloc,
    core_register,
    core_config,
    core_init,
    core_ready,
    scrollbar_ready,
    window_owned,
    tab_owned,
    split_owned,
};

var enabled = false;
var armed: Point = .none;
var hits: usize = 0;

pub fn init(value: bool) void {
    if (comptime !build_config.win32_test_hooks) return;
    enabled = value;
    armed = .none;
    hits = 0;
}

pub fn fail(point: Point) error{TestLifecycleFailure}!void {
    if (comptime !build_config.win32_test_hooks) return;
    if (!enabled or armed != point) return;
    armed = .none; // Fail once; the same action must subsequently succeed.
    hits += 1;
    std.log.scoped(.win32_test).info("lifecycle failure point={s}", .{@tagName(point)});
    return error.TestLifecycleFailure;
}

fn hashValue(hash: *std.hash.Wyhash, value: anytype) void {
    hash.update(std.mem.asBytes(&value));
}

fn hashTree(hash: *std.hash.Wyhash, node: *const Tree.Node) void {
    switch (node.*) {
        .leaf => |surface| {
            hashValue(hash, @as(u8, 0));
            hashValue(hash, @intFromPtr(surface));
        },
        .split => |branch| {
            hashValue(hash, @as(u8, 1));
            hashValue(hash, @as(u8, @intFromEnum(branch.direction)));
            hashValue(hash, branch.ratio);
            for (branch.children) |child| hashTree(hash, child);
        },
    }
}

fn fingerprint(app: *App) u32 {
    var hash = std.hash.Wyhash.init(0);
    hashValue(&hash, @intFromPtr(win32.GetFocus()));
    hashValue(&hash, @intFromPtr(app.core_app.focused_surface));
    for (app.core_app.surfaces.items) |surface| hashValue(&hash, @intFromPtr(surface));
    for (app.windows.items) |window| {
        hashValue(&hash, @intFromPtr(window));
        hashValue(&hash, @intFromPtr(window.active_tab));
        hashValue(&hash, win32.GetWindowLongPtrW(window.hwnd, win32.GWLP_USERDATA));
        for (window.tabs.items) |tab| {
            hashValue(&hash, @intFromPtr(tab));
            hashValue(&hash, @intFromPtr(tab.focused_surface));
            hashValue(&hash, @intFromPtr(tab.tree.zoomed));
            for (tab.surfaces.items) |surface| hashValue(&hash, @intFromPtr(surface));
            hashTree(&hash, tab.tree.root);
        }
    }
    return @truncate(hash.final());
}

fn valid(app: *App) bool {
    var total: usize = 0;
    var core_focus_valid = app.core_app.focused_surface == null;
    for (app.windows.items) |window| {
        const parent = win32.GetWindowLongPtrW(window.hwnd, win32.GWLP_USERDATA);
        if (parent == 0 or win32.IsWindow(window.hwnd) == 0) return false;
        const owner: *Surface = @ptrFromInt(@as(usize, @bitCast(parent)));
        if (!window.contains(owner) or !window.active_tab.contains(window.focusedSurface())) return false;
        for (window.tabs.items) |tab| {
            if (!tab.contains(tab.focused_surface)) return false;
            for (tab.surfaces.items) |surface| {
                total += 1;
                if (win32.IsWindow(surface.hwnd) == 0 or surface.core_surface == null) return false;
                if (win32.GetWindowLongPtrW(surface.hwnd, win32.GWLP_USERDATA) != @as(isize, @bitCast(@intFromPtr(surface)))) return false;
                var found = false;
                for (app.core_app.surfaces.items) |registered| {
                    if (registered == surface) found = true;
                }
                if (!found) return false;
                if (app.core_app.focused_surface == surface.core_surface) core_focus_valid = true;
            }
        }
    }
    return core_focus_valid and total == app.core_app.surfaces.items.len;
}

pub fn control(hwnd: win32.HWND, wparam: win32.WPARAM, lparam: win32.LPARAM) win32.LRESULT {
    if (comptime !build_config.win32_test_hooks) return 0;
    if (!enabled) return 0;
    const surface = @import("WndProc.zig").getSurface(hwnd) orelse return 0;
    const app = surface.rtApp();
    return switch (wparam) {
        0 => 0x47484c54,
        1 => blk: {
            if (lparam < 0 or lparam > @intFromEnum(Point.split_owned)) break :blk -1;
            armed = @enumFromInt(lparam);
            break :blk 1;
        },
        2 => @intCast(app.core_app.surfaces.items.len),
        3 => @intCast(app.windows.items.len),
        4 => blk: {
            var count: usize = 0;
            for (app.windows.items) |window| count += window.tabCount();
            break :blk @intCast(count);
        },
        5 => @intCast(hits),
        6 => @intFromBool(valid(app)),
        7 => fingerprint(app),
        8 => blk: {
            IpcHandler.testHold(app, lparam != 0);
            break :blk 1;
        },
        9 => @intCast(IpcHandler.testPendingCount()),
        10 => @intCast(IpcHandler.testLiveCount()),
        11 => @bitCast(@intFromPtr(win32.GetFocus())),
        12 => @intCast(app.windowForSurface(surface).?.activeTabIndex()),
        13 => @bitCast(@intFromPtr(app.windowForSurface(surface).?.focusedSurface().hwnd)),
        14 => @bitCast(@intFromPtr(app.windowForSurface(surface).?.active_tab.tree.zoomed)),
        else => -1,
    };
}

test "Win32 lifecycle failure injection is opt-in and one-shot" {
    defer init(false);
    init(false);
    armed = .core_ready;
    try fail(.core_ready);
    try std.testing.expectEqual(@as(usize, 0), hits);
    if (comptime !build_config.win32_test_hooks) return;
    init(true);
    armed = .core_ready;
    try fail(.core_init);
    try std.testing.expectError(error.TestLifecycleFailure, fail(.core_ready));
    try fail(.core_ready);
    try std.testing.expectEqual(@as(usize, 1), hits);
}
