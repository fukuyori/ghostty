//! Shell-aware path formatting and native file-drop handling for Win32.
//! The window procedure retains ownership of HDROP and calls DragFinish.
const std = @import("std");
const win32 = @import("win32").everything;
const brand = @import("../../brand.zig");
const Surface = @import("Surface.zig");
const App = @import("App.zig");
const DeferredActions = @import("DeferredActions.zig");
const config = @import("../../config.zig");

pub const Shell = enum { cmd, powershell, unsupported };

pub fn handleDrop(surface: *Surface, drop: win32.HDROP) !void {
    const core = surface.core_surface orelse return;
    const alloc = surface.rtApp().alloc;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const temp = arena.allocator();

    const count = win32.DragQueryFileW(drop, 0xffffffff, null, 0);
    if (count == 0) return;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    for (0..count) |index| {
        const length = win32.DragQueryFileW(drop, @intCast(index), null, 0);
        if (length == 0) return error.InvalidPath;
        const wide = try temp.allocSentinel(u16, length, 0);
        const copied = win32.DragQueryFileW(drop, @intCast(index), wide.ptr, length + 1);
        if (copied != length) return error.InvalidPath;
        try paths.append(temp, try std.unicode.utf16LeToUtf8Alloc(temp, wide[0..length]));
    }
    const formatted = try formatPaths(temp, surface.file_drop_shell, paths.items);
    const owned = try alloc.dupe(u8, formatted);
    if (!DeferredActions.enqueue(surface.rtApp(), .{ .paste = .{ .id = core.id, .text = owned } }))
        return error.OutOfMemory;
}

pub fn pasteQueued(app: *App, id: u64, formatted: []const u8) !void {
    const surface = DeferredActions.resolve(app, id) orelse return;
    const core = surface.core_surface orelse return;
    core.pasteExternalText(formatted, false) catch |err| switch (err) {
        error.UnsafePaste => {
            const caption = std.unicode.utf8ToUtf16LeStringLiteral(brand.display_name ++ " File Drop");
            const message = std.unicode.utf8ToUtf16LeStringLiteral(
                "The dropped paths may contain unsafe text. Paste them into the terminal?",
            );
            const style: win32.MESSAGEBOX_STYLE = .{
                .YESNO = 1,
                .ICONQUESTION = 1,
                .DEFBUTTON2 = 1,
            };
            if (win32.MessageBoxW(surface.windowHwnd(), message, caption, style) != win32.IDYES) return;
            const live = DeferredActions.resolve(app, id) orelse return;
            try (live.core_surface orelse return).pasteExternalText(formatted, true);
        },
        else => return err,
    };
}

pub fn showWarning(surface: *Surface, message: []const u8) void {
    const app = surface.rtApp();
    const core = surface.core_surface orelse return;
    const text = app.alloc.dupe(u8, message) catch return;
    _ = DeferredActions.enqueue(app, .{ .warning = .{ .id = core.id, .text = text } });
}

pub fn showQueuedWarning(app: *App, id: u64, message: []const u8) void {
    const surface = DeferredActions.resolve(app, id) orelse return;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(app.alloc, message) catch return;
    defer app.alloc.free(wide);
    const caption = std.unicode.utf8ToUtf16LeStringLiteral(brand.display_name ++ " File Drop");
    const style: win32.MESSAGEBOX_STYLE = .{ .ICONHAND = 1 };
    _ = win32.MessageBoxW(surface.windowHwnd(), wide, caption, style);
}

pub fn classify(alloc: std.mem.Allocator, command: ?config.Command) !Shell {
    const configured = command orelse return .cmd;
    var args = try configured.argIterator(alloc);
    defer args.deinit();
    const executable = args.next() orelse return .unsupported;
    const name = std.fs.path.basename(executable);
    if (std.ascii.eqlIgnoreCase(name, "cmd") or
        std.ascii.eqlIgnoreCase(name, "cmd.exe")) return .cmd;
    if (std.ascii.eqlIgnoreCase(name, "pwsh") or
        std.ascii.eqlIgnoreCase(name, "pwsh.exe") or
        std.ascii.eqlIgnoreCase(name, "powershell") or
        std.ascii.eqlIgnoreCase(name, "powershell.exe")) return .powershell;
    return .unsupported;
}

/// Prepare paths as arguments only. A drop never includes Enter or a command.
pub fn formatPaths(alloc: std.mem.Allocator, shell: Shell, paths: []const []const u8) ![]u8 {
    if (shell == .unsupported) return error.UnsupportedShell;
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(alloc);
    for (paths, 0..) |path, index| {
        if (path.len == 0) return error.InvalidPath;
        if (index != 0) try output.append(alloc, ' ');
        for (path) |char| {
            if (char < 0x20 or char == 0x7f) return error.InvalidPath;
            if (shell == .cmd and (char == '%' or char == '!')) return error.CmdExpansion;
        }
        switch (shell) {
            .cmd => {
                if (std.mem.indexOfScalar(u8, path, '"') != null) return error.InvalidPath;
                try output.append(alloc, '"');
                try output.appendSlice(alloc, path);
                try output.append(alloc, '"');
            },
            .powershell => {
                try output.append(alloc, '\'');
                for (path) |char| {
                    try output.append(alloc, char);
                    if (char == '\'') try output.append(alloc, '\'');
                }
                try output.append(alloc, '\'');
            },
            .unsupported => unreachable,
        }
    }
    return output.toOwnedSlice(alloc);
}

test "file drop quotes PowerShell and cmd paths" {
    const testing = std.testing;
    const paths: []const []const u8 = &.{ "C:\\a b\\it's.txt", "D:\\other.txt" };
    const ps = try formatPaths(testing.allocator, .powershell, paths);
    defer testing.allocator.free(ps);
    try testing.expectEqualStrings("'C:\\a b\\it''s.txt' 'D:\\other.txt'", ps);
    const cmd = try formatPaths(testing.allocator, .cmd, paths);
    defer testing.allocator.free(cmd);
    try testing.expectEqualStrings("\"C:\\a b\\it's.txt\" \"D:\\other.txt\"", cmd);
    try testing.expectError(error.CmdExpansion, formatPaths(testing.allocator, .cmd, &.{"C:\\100%\\file"}));
    try testing.expectError(error.CmdExpansion, formatPaths(testing.allocator, .cmd, &.{"C:\\wow!\\file"}));
    try testing.expectError(error.InvalidPath, formatPaths(testing.allocator, .cmd, &.{"C:\\newline\nfile"}));
    try testing.expectError(error.InvalidPath, formatPaths(testing.allocator, .powershell, &.{"C:\\escape\x1b[201~file"}));
    const japanese = try formatPaths(testing.allocator, .powershell, &.{"C:\\資料\\日本語 & (1).txt"});
    defer testing.allocator.free(japanese);
    try testing.expectEqualStrings("'C:\\資料\\日本語 & (1).txt'", japanese);
}

test "file drop classifies configured startup shell" {
    const testing = std.testing;
    try testing.expectEqual(Shell.cmd, try classify(testing.allocator, null));
    try testing.expectEqual(Shell.powershell, try classify(testing.allocator, .{
        .shell = "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo",
    }));
    try testing.expectEqual(Shell.cmd, try classify(testing.allocator, .{
        .shell = "cmd.exe /k",
    }));
    try testing.expectEqual(Shell.unsupported, try classify(testing.allocator, .{
        .shell = "bash.exe",
    }));
}
