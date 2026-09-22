//! A modeless native search bar owned by one terminal pane. The common core
//! owns matching, scrollback navigation, and renderer highlights.
const Self = @This();
const std = @import("std");
const win32 = @import("win32").everything;
const Surface = @import("Surface.zig");
const input = @import("../../input.zig");
const log = std.log.scoped(.win32_search);

surface: *Surface,
hwnd: ?win32.HWND = null,
active: bool = false,
total: ?usize = null,
selected: ?usize = null,

const edit_id = 1101;
const status_id = 1102;
const previous_id = 1103;

pub fn init(self: *Self, surface: *Surface) !void {
    self.* = .{ .surface = surface };
    self.hwnd = win32.CreateDialogParamW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(104),
        surface.windowHwnd(),
        dialogProc,
        @bitCast(@intFromPtr(self)),
    ) orelse return error.CreateSearchBarFailed;
    errdefer self.deinit();
    // Opaque layered children can render native GDI controls independently
    // of the D3D11 parent's no-redirection surface (Windows 8 and newer).
    if (win32.SetLayeredWindowAttributes(self.hwnd.?, 0, 255, .{ .ALPHA = 1 }) == 0)
        return error.CreateSearchBarFailed;
}

pub fn deinit(self: *Self) void {
    self.active = false;
    if (self.hwnd) |hwnd| {
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
        _ = win32.DestroyWindow(hwnd);
    }
    self.hwnd = null;
}

pub fn start(self: *Self, needle: [:0]const u8) !void {
    self.active = true;
    if (needle.len > 0) {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(self.surface.rtApp().alloc, needle);
        defer self.surface.rtApp().alloc.free(wide);
        _ = win32.SetDlgItemTextW(self.hwnd.?, edit_id, wide.ptr);
    } else {
        // Reopening a closed bar restarts matching for its retained text.
        self.changed();
    }
}

pub fn focus(self: *Self) void {
    const edit = win32.GetDlgItem(self.hwnd.?, edit_id);
    _ = win32.SetFocus(edit);
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 0, -1);
}

pub fn stop(self: *Self) void {
    self.active = false;
    self.total = null;
    self.selected = null;
    _ = win32.ShowWindow(self.hwnd.?, win32.SW_HIDE);
    _ = win32.SetFocus(self.surface.hwnd);
}

pub fn updateStatus(self: *Self) void {
    var buffer: [96]u8 = undefined;
    const text = if (self.total) |total|
        std.fmt.bufPrintZ(&buffer, "{d} / {d}", .{ if (self.selected) |n| n + 1 else 0, total }) catch return
    else
        "";
    var wide: [96:0]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&wide, text) catch return;
    wide[len] = 0;
    _ = win32.SetDlgItemTextW(self.hwnd.?, status_id, &wide);
}

/// Return the space reserved above this pane. Controls use the window's
/// current DPI, including when it moves between monitors.
pub fn layout(self: *Self, x: i32, y: i32, width: i32, height: i32, dpi: u32) i32 {
    if (!self.active) return 0;
    const scale = @as(f64, @floatFromInt(dpi)) / 96.0;
    const bar_height = @min(height, px(36, scale));
    _ = win32.SetWindowPos(self.hwnd.?, null, x, y, width, bar_height, .{ .NOZORDER = 1, .NOACTIVATE = 1, .SHOWWINDOW = 1 });
    const margin = px(4, scale);
    const label_width = px(30, scale);
    const button_width = @min(px(62, scale), @divTrunc(@max(0, width - label_width - 4 * margin), 5));
    const status_width = button_width;
    const edit_width = @max(0, width - label_width - 3 * button_width - status_width - 7 * margin);
    var offset = margin;
    for ([_]struct { id: i32, width: i32 }{
        .{ .id = 1100, .width = label_width },
        .{ .id = edit_id, .width = edit_width },
        .{ .id = status_id, .width = status_width },
        .{ .id = previous_id, .width = button_width },
        .{ .id = 1, .width = button_width },
        .{ .id = 2, .width = button_width },
    }) |item| {
        _ = win32.SetWindowPos(win32.GetDlgItem(self.hwnd.?, item.id), null, offset, margin, item.width, @max(0, bar_height - 2 * margin), .{ .NOZORDER = 1, .NOACTIVATE = 1 });
        offset += item.width + margin;
    }
    // Moving controls on a layered child can otherwise retain pixels from
    // their old positions in its redirection bitmap.
    _ = win32.RedrawWindow(self.hwnd.?, null, null, .{ .INVALIDATE = 1, .ERASE = 1, .ALLCHILDREN = 1, .UPDATENOW = 1 });
    return bar_height;
}

fn px(value: i32, scale: f64) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(value)) * scale));
}

/// Called before TranslateMessage so Enter/Escape never reach the terminal.
pub fn filterMessage(self: *Self, msg: *win32.MSG) bool {
    if (!self.active or win32.IsWindowVisible(self.hwnd.?) == 0) return false;
    if (msg.hwnd != self.hwnd and win32.IsChild(self.hwnd.?, msg.hwnd) == 0) return false;
    // Let the edit's IME finish or cancel its composition before treating
    // Enter/Escape as search shortcuts.
    if (win32.ImmGetContext(msg.hwnd)) |context| {
        defer _ = win32.ImmReleaseContext(msg.hwnd, context);
        if (win32.ImmGetCompositionStringW(context, win32.GCS_COMPSTR, null, 0) > 0) return false;
    }
    if (msg.hwnd == win32.GetDlgItem(self.hwnd.?, edit_id) and
        msg.message == win32.WM_KEYDOWN and msg.wParam == @intFromEnum(win32.VK_RETURN))
    {
        self.navigate(win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0);
        return true;
    }
    return win32.IsDialogMessageW(self.hwnd.?, msg) != 0;
}

fn binding(self: *Self, action: input.Binding.Action) void {
    if (self.surface.core_surface) |core| {
        _ = core.performBindingAction(action) catch |err| {
            log.warn("search action failed: {}", .{err});
        };
    }
}

fn navigate(self: *Self, previous: bool) void {
    self.binding(.{ .navigate_search = if (previous) .previous else .next });
}

fn changed(self: *Self) void {
    if (!self.active) return;
    const alloc = self.surface.rtApp().alloc;
    const edit = win32.GetDlgItem(self.hwnd.?, edit_id);
    const size: usize = @intCast(@max(0, win32.GetWindowTextLengthW(edit)));
    const wide = alloc.allocSentinel(u16, size + 1, 0) catch return;
    defer alloc.free(wide);
    const len = win32.GetWindowTextW(edit, wide.ptr, @intCast(wide.len));
    const text = std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..@intCast(@max(0, len))]) catch return;
    defer alloc.free(text);
    // Let the search engine publish result changes. It deliberately keeps
    // an unchanged (case-insensitive) query, so clearing counters here would
    // lose them when an already-open bar is focused again.
    self.binding(.{ .search = text });
}

fn dialogProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    if (msg == win32.WM_INITDIALOG) {
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, lparam);
        _ = win32.SendDlgItemMessageW(hwnd, edit_id, win32.EM_SETLIMITTEXT, 32767, 0);
        return 0;
    }
    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return 0;
    const self: *Self = @ptrFromInt(@as(usize, @bitCast(ptr)));
    if (msg == win32.WM_COMMAND) {
        const id: u16 = @truncate(wparam);
        const notification: u16 = @truncate(wparam >> 16);
        switch (id) {
            edit_id => {
                if (notification == win32.EN_CHANGE) self.changed();
                if (notification == win32.EN_SETFOCUS) self.surface.rtApp().focusSearchPane(self.surface);
            },
            previous_id => self.navigate(true),
            1 => self.navigate(false),
            2 => self.binding(.end_search),
            else => return 0,
        }
        return 1;
    }
    return 0;
}
