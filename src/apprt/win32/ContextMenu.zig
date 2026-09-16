//! The right-click context menu for a terminal surface.
//!
//! The items mirror the GTK context menu, minus the entries the Windows
//! runtime does not support yet (surface and window title prompts, and
//! notify on next command finish).
const std = @import("std");
const win32 = @import("win32").everything;

const CoreSurface = @import("../../Surface.zig");
const input = @import("../../input.zig");

const log = std.log.scoped(.win32_context_menu);

const Item = struct {
    label: []const u8,
    action: input.Binding.Action,
};

/// Menu command IDs are indexes into this table plus one, because
/// TrackPopupMenuEx returns zero when the menu is dismissed.
const items = [_]Item{
    .{ .label = "&Copy", .action = .{ .copy_to_clipboard = .mixed } },
    .{ .label = "&Paste", .action = .paste_from_clipboard },
    .{ .label = "C&lear", .action = .clear_screen },
    .{ .label = "&Reset", .action = .reset },
    .{ .label = "Split &Up", .action = .{ .new_split = .up } },
    .{ .label = "Split &Down", .action = .{ .new_split = .down } },
    .{ .label = "Split &Left", .action = .{ .new_split = .left } },
    .{ .label = "Split &Right", .action = .{ .new_split = .right } },
    .{ .label = "&Close Split", .action = .close_surface },
    .{ .label = "Change Tab &Title\u{2026}", .action = .prompt_tab_title },
    .{ .label = "&New Tab", .action = .new_tab },
    .{ .label = "&Close Tab", .action = .{ .close_tab = .this } },
    .{ .label = "&New Window", .action = .new_window },
    .{ .label = "&Close Window", .action = .close_window },
    .{ .label = "Open Configuration in OS &Editor", .action = .{ .open_config = .os_open } },
    .{ .label = "Open Configuration in New &Window", .action = .{ .open_config = .new_window } },
    .{ .label = "&Reload Configuration", .action = .reload_config },
};

const Entry = union(enum) {
    item: usize,
    separator,
    submenu: struct { label: []const u8, entries: []const Entry },
};

const layout = [_]Entry{
    .{ .item = 0 },
    .{ .item = 1 },
    .separator,
    .{ .item = 2 },
    .{ .item = 3 },
    .separator,
    .{ .submenu = .{ .label = "&Split", .entries = &.{
        .{ .item = 4 },
        .{ .item = 5 },
        .{ .item = 6 },
        .{ .item = 7 },
        .separator,
        .{ .item = 8 },
    } } },
    .{ .submenu = .{ .label = "&Tab", .entries = &.{
        .{ .item = 9 },
        .separator,
        .{ .item = 10 },
        .{ .item = 11 },
    } } },
    .{ .submenu = .{ .label = "&Window", .entries = &.{
        .{ .item = 12 },
        .{ .item = 13 },
    } } },
    .separator,
    .{ .submenu = .{ .label = "C&onfig", .entries = &.{
        .{ .item = 14 },
        .{ .item = 15 },
        .separator,
        .{ .item = 16 },
    } } },
};

/// Shows the menu at `point` (client coordinates of `hwnd`) and performs the
/// chosen action on `core`. Blocks in the menu's modal loop until the menu
/// is dismissed.
pub fn show(
    alloc: std.mem.Allocator,
    hwnd: win32.HWND,
    core: *CoreSurface,
    point: win32.POINT,
) void {
    const menu = win32.CreatePopupMenu() orelse {
        log.warn("CreatePopupMenu failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return;
    };
    defer _ = win32.DestroyMenu(menu);

    const has_selection = core.hasSelection();
    appendEntries(alloc, menu, &layout, has_selection) catch |err| {
        log.warn("building context menu failed: {}", .{err});
        return;
    };

    var screen = point;
    _ = win32.ClientToScreen(hwnd, &screen);

    const flags: win32.TRACK_POPUP_MENU_FLAGS = .{
        .RIGHTBUTTON = 1,
        .NONOTIFY = 1,
        .RETURNCMD = 1,
    };
    const command = win32.TrackPopupMenuEx(menu, @bitCast(flags), screen.x, screen.y, hwnd, null);
    if (command <= 0) return;

    const index: usize = @intCast(command - 1);
    if (index >= items.len) return;
    _ = core.performBindingAction(items[index].action) catch |err| {
        log.err("context menu action failed: {}", .{err});
    };
}

fn appendEntries(
    alloc: std.mem.Allocator,
    menu: win32.HMENU,
    entries: []const Entry,
    has_selection: bool,
) !void {
    for (entries) |entry| switch (entry) {
        .separator => try append(menu, win32.MF_SEPARATOR, 0, null),
        .item => |index| {
            var flags = win32.MF_STRING;
            if (items[index].action == .copy_to_clipboard and !has_selection) flags.GRAYED = 1;
            const label = try std.unicode.utf8ToUtf16LeAllocZ(alloc, items[index].label);
            defer alloc.free(label);
            try append(menu, flags, index + 1, label);
        },
        .submenu => |submenu| {
            const child = win32.CreatePopupMenu() orelse return error.Win32Error;
            appendEntries(alloc, child, submenu.entries, has_selection) catch |err| {
                _ = win32.DestroyMenu(child);
                return err;
            };
            const label = try std.unicode.utf8ToUtf16LeAllocZ(alloc, submenu.label);
            defer alloc.free(label);
            // Once attached, the child is destroyed together with its parent.
            append(menu, win32.MF_POPUP, @intFromPtr(child), label) catch |err| {
                _ = win32.DestroyMenu(child);
                return err;
            };
        },
    };
}

fn append(menu: win32.HMENU, flags: win32.MENU_ITEM_FLAGS, id: usize, label: ?[*:0]const u16) !void {
    if (win32.AppendMenuW(menu, flags, id, label) == 0) {
        log.warn("AppendMenuW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }
}

test "context menu layout references every item once" {
    var seen = [_]bool{false} ** items.len;
    markSeen(&layout, &seen);
    for (seen) |s| try std.testing.expect(s);
}

fn markSeen(entries: []const Entry, seen: []bool) void {
    for (entries) |entry| switch (entry) {
        .item => |index| {
            std.debug.assert(!seen[index]);
            seen[index] = true;
        },
        .separator => {},
        .submenu => |submenu| markSeen(submenu.entries, seen),
    };
}
