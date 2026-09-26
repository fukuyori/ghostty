const std = @import("std");
const config = @import("../../config.zig");

pub const Shell = enum { cmd, powershell, unsupported };

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
