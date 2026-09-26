//! Native command palette for the Win32 runtime. The dialog keeps a snapshot
//! of configured actions so config reloads cannot invalidate an open list.
const Self = @This();
const std = @import("std");
const win32 = @import("win32").everything;
const Config = @import("../../config/Config.zig");
const input = @import("../../input.zig");
const Surface = @import("Surface.zig");

const edit_id = 1201;
const list_id = 1202;
const description_id = 1203;
const dialog_id: usize = 106;

pub const Jump = struct {
    surface: *Surface,
    id: u64,
    title: []const u8,
};

pub const Entry = struct {
    title: []const u8,
    description: []const u8,
    shortcut: []const u8 = "",
    kind: union(enum) {
        action: input.Binding.Action,
        jump: struct { surface: *Surface, id: u64 },
    },
};

arena: std.heap.ArenaAllocator,
entries: std.ArrayListUnmanaged(Entry) = .empty,
visible: std.ArrayListUnmanaged(usize) = .empty,
selected: ?usize = null,
original_edit_proc: ?win32.WNDPROC = null,

pub fn init(alloc: std.mem.Allocator, config: *const Config, jumps: []const Jump) !Self {
    var self: Self = .{ .arena = std.heap.ArenaAllocator.init(alloc) };
    errdefer self.deinit();
    const a = self.arena.allocator();
    for (config.@"command-palette-entry".value.items) |command| {
        if (!supported(command.action)) continue;
        const shortcut = if (config.keybind.set.getTrigger(command.action)) |trigger|
            try std.fmt.allocPrint(a, "{f}", .{trigger})
        else
            "";
        try self.entries.append(a, .{
            .title = try a.dupe(u8, command.title),
            .description = try a.dupe(u8, command.description),
            .shortcut = shortcut,
            .kind = .{ .action = try command.action.clone(a) },
        });
    }
    for (jumps) |jump| {
        try self.entries.append(a, .{
            .title = try std.fmt.allocPrint(a, "Focus: {s}", .{jump.title}),
            .description = "Switch to this terminal pane",
            .kind = .{ .jump = .{ .surface = jump.surface, .id = jump.id } },
        });
    }
    std.mem.sort(Entry, self.entries.items, {}, lessThan);
    return self;
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Returns a snapshot entry index. The caller must check that a surface is
/// still owned by the app before dereferencing either a jump or action target.
pub fn show(self: *Self, parent: win32.HWND) ?usize {
    const resource: [*:0]const u16 = @ptrFromInt(dialog_id);
    const result = win32.DialogBoxParamW(
        win32.GetModuleHandleW(null),
        resource,
        parent,
        dialogProc,
        @bitCast(@intFromPtr(self)),
    );
    if (result == -1) return null;
    return self.selected;
}

fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
    // Match the upstream colon ordering used for "Focus: ..." entries.
    for (0..@min(lhs.title.len, rhs.title.len)) |i| {
        const l = std.ascii.toLower(if (lhs.title[i] == ':') '\t' else lhs.title[i]);
        const r = std.ascii.toLower(if (rhs.title[i] == ':') '\t' else rhs.title[i]);
        if (l != r) return l < r;
    }
    return lhs.title.len < rhs.title.len;
}

fn supported(action: input.Binding.Action) bool {
    return switch (action) {
        .paste_from_selection,
        .move_tab_to_new_window,
        .toggle_tab_overview,
        .prompt_surface_title,
        .prompt_window_title,
        .inspector,
        .show_on_screen_keyboard,
        .toggle_window_float_on_top,
        .toggle_secure_input,
        .toggle_background_opacity,
        .toggle_quick_terminal,
        .check_for_updates,
        .redo,
        .undo,
        .show_gtk_inspector,
        => false,
        .copy_to_clipboard => |format| format != .html and format != .mixed,
        else => true,
    };
}

fn matches(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    for (haystack) |byte| {
        if (std.ascii.toLower(byte) == std.ascii.toLower(needle[i])) {
            i += 1;
            if (i == needle.len) return true;
        }
    }
    return false;
}

fn refresh(self: *Self, hwnd: win32.HWND) void {
    var scratch = std.heap.ArenaAllocator.init(self.arena.child_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const edit = win32.GetDlgItem(hwnd, edit_id);
    const len: usize = @intCast(@max(0, win32.GetWindowTextLengthW(edit)));
    const wide = a.allocSentinel(u16, len + 1, 0) catch return;
    const actual = win32.GetWindowTextW(edit, wide.ptr, @intCast(wide.len));
    const utf8 = std.unicode.utf16LeToUtf8Alloc(a, wide[0..@intCast(@max(0, actual))]) catch return;
    const query = std.mem.trim(u8, utf8, " \t\r\n");
    self.visible.clearRetainingCapacity();
    _ = win32.SendDlgItemMessageW(hwnd, list_id, win32.LB_RESETCONTENT, 0, 0);
    for (self.entries.items, 0..) |entry, index| {
        if (!matches(entry.title, query) and !matches(entry.description, query)) continue;
        self.visible.append(self.arena.allocator(), index) catch return;
        const label = if (entry.shortcut.len > 0)
            std.fmt.allocPrint(a, "{s}    {s}", .{ entry.title, entry.shortcut }) catch return
        else
            entry.title;
        const label_wide = std.unicode.utf8ToUtf16LeAllocZ(a, label) catch return;
        _ = win32.SendDlgItemMessageW(hwnd, list_id, win32.LB_ADDSTRING, 0, @bitCast(@intFromPtr(label_wide.ptr)));
    }
    if (self.visible.items.len > 0) {
        _ = win32.SendDlgItemMessageW(hwnd, list_id, win32.LB_SETCURSEL, 0, 0);
    }
    self.updateDescription(hwnd);
}

fn updateDescription(self: *Self, hwnd: win32.HWND) void {
    const selected = win32.SendDlgItemMessageW(hwnd, list_id, win32.LB_GETCURSEL, 0, 0);
    const description = if (selected >= 0 and @as(usize, @intCast(selected)) < self.visible.items.len)
        self.entries.items[self.visible.items[@intCast(selected)]].description
    else
        "";
    const wide = std.unicode.utf8ToUtf16LeAllocZ(self.arena.child_allocator, description) catch return;
    defer self.arena.child_allocator.free(wide);
    _ = win32.SetDlgItemTextW(hwnd, description_id, wide.ptr);
}

fn accept(self: *Self, hwnd: win32.HWND) void {
    const selected = win32.SendDlgItemMessageW(hwnd, list_id, win32.LB_GETCURSEL, 0, 0);
    if (selected < 0 or @as(usize, @intCast(selected)) >= self.visible.items.len) return;
    self.selected = self.visible.items[@intCast(selected)];
    _ = win32.EndDialog(hwnd, 1);
}

fn moveSelection(self: *Self, hwnd: win32.HWND, direction: i32) void {
    const count = win32.SendDlgItemMessageW(hwnd, list_id, win32.LB_GETCOUNT, 0, 0);
    if (count <= 0) return;
    const current = win32.SendDlgItemMessageW(hwnd, list_id, win32.LB_GETCURSEL, 0, 0);
    const next = if (current < 0)
        @as(isize, 0)
    else
        std.math.clamp(current + direction, 0, count - 1);
    _ = win32.SendDlgItemMessageW(hwnd, list_id, win32.LB_SETCURSEL, @intCast(next), 0);
    self.updateDescription(hwnd);
}

/// Keep the search field focused while Up/Down moves the list selection.
fn editProc(edit: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    const dialog = win32.GetParent(edit) orelse return win32.DefWindowProcW(edit, msg, wparam, lparam);
    const self = context(dialog) orelse return win32.DefWindowProcW(edit, msg, wparam, lparam);
    const original = self.original_edit_proc orelse return win32.DefWindowProcW(edit, msg, wparam, lparam);
    if (msg == win32.WM_GETDLGCODE) {
        return win32.CallWindowProcW(original, edit, msg, wparam, lparam) | win32.DLGC_WANTARROWS;
    }
    if (msg == win32.WM_KEYDOWN) {
        if (wparam == @intFromEnum(win32.VK_UP)) {
            self.moveSelection(dialog, -1);
            return 0;
        }
        if (wparam == @intFromEnum(win32.VK_DOWN)) {
            self.moveSelection(dialog, 1);
            return 0;
        }
    }
    return win32.CallWindowProcW(original, edit, msg, wparam, lparam);
}

fn context(hwnd: win32.HWND) ?*Self {
    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn dialogProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_INITDIALOG => {
            const self: *Self = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, lparam);
            const edit = win32.GetDlgItem(hwnd, edit_id);
            const previous = win32.SetWindowLongPtrW(edit, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc)));
            if (previous != 0) {
                self.original_edit_proc = @ptrFromInt(@as(usize, @bitCast(previous)));
            }
            self.refresh(hwnd);
            _ = win32.SetFocus(edit);
            return 0;
        },
        win32.WM_COMMAND => {
            const self = context(hwnd) orelse return 0;
            const id: u16 = @truncate(wparam);
            const notification: u16 = @truncate(wparam >> 16);
            switch (id) {
                edit_id => if (notification == win32.EN_CHANGE) self.refresh(hwnd),
                list_id => {
                    if (notification == win32.LBN_SELCHANGE) self.updateDescription(hwnd);
                    if (notification == win32.LBN_DBLCLK) self.accept(hwnd);
                },
                1 => self.accept(hwnd),
                2 => _ = win32.EndDialog(hwnd, 2),
                else => return 0,
            }
            return 1;
        },
        else => {},
    }
    return 0;
}

test "palette query matches ordered letters" {
    try std.testing.expect(matches("Reload Configuration", "rld cfg"));
    try std.testing.expect(matches("Reload Configuration", "rlcf"));
    try std.testing.expect(!matches("Reload Configuration", "xyz"));
}
