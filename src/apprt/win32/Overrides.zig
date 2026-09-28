const std = @import("std");
const Allocator = std.mem.Allocator;

const cli = @import("../../cli.zig");
const configpkg = @import("../../config.zig");

const log = std.log.scoped(.win32_overrides);

const Overrides = @This();

command: ?configpkg.Command = null,
shell_integration: ?configpkg.Config.ShellIntegration = null,
working_directory: ?[:0]const u8 = null,
title: ?[:0]const u8 = null,

pub fn parse(arena_alloc: Allocator, arguments: []const [:0]const u8) !Overrides {
    var command_args: std.ArrayList([:0]const u8) = .empty;
    var result: Overrides = .{};
    var parsed_shell_integration: struct {
        @"shell-integration": ?configpkg.Config.ShellIntegration = null,
    } = .{};
    var e_seen = false;

    for (arguments, 0..) |arg, i| {
        if (e_seen) {
            try command_args.append(arena_alloc, try arena_alloc.dupeZ(u8, arg));
            continue;
        }

        if (std.mem.eql(u8, arg, "-e")) {
            e_seen = true;
            continue;
        }

        if (std.mem.cutPrefix(u8, arg, "--command=")) |value| {
            var command: configpkg.Command = undefined;
            command.parseCLI(arena_alloc, value) catch |err| {
                log.warn("unable to parse command argument {d}: {t}", .{ i, err });
                return err;
            };
            result.command = command;
            continue;
        }

        if (std.mem.cutPrefix(u8, arg, "--shell-integration=")) |value| {
            cli.args.parseIntoField(
                @TypeOf(parsed_shell_integration),
                arena_alloc,
                &parsed_shell_integration,
                "shell-integration",
                std.mem.trim(u8, value, &std.ascii.whitespace),
            ) catch |err| {
                log.warn("unable to parse shell integration {s}: {t}", .{ value, err });
                continue;
            };
            continue;
        }

        if (std.mem.cutPrefix(u8, arg, "--working-directory=")) |value| {
            result.working_directory = try arena_alloc.dupeZ(
                u8,
                std.mem.trim(u8, value, &std.ascii.whitespace),
            );
            continue;
        }

        if (std.mem.cutPrefix(u8, arg, "--title=")) |value| {
            result.title = try arena_alloc.dupeZ(
                u8,
                std.mem.trim(u8, value, &std.ascii.whitespace),
            );
        }
    }

    if (command_args.items.len > 0) {
        result.command = .{ .direct = command_args.items };
    }
    result.shell_integration = parsed_shell_integration.@"shell-integration";
    return result;
}

test "parse Win32 new-tab overrides" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try parse(arena.allocator(), &.{
        "--working-directory=C:\\tmp",
        "--shell-integration=none",
        "--title=IPC tab",
        "-e",
        "powershell.exe",
        "-NoProfile",
        "-Command",
        "Write-Output ok",
    });

    try testing.expectEqualStrings("C:\\tmp", result.working_directory.?);
    try testing.expectEqualStrings("IPC tab", result.title.?);
    try testing.expectEqual(configpkg.Config.ShellIntegration.none, result.shell_integration.?);
    const direct = result.command.?.direct;
    try testing.expectEqual(@as(usize, 4), direct.len);
    try testing.expectEqualStrings("powershell.exe", direct[0]);
    try testing.expectEqualStrings("Write-Output ok", direct[3]);
}

test "invalid Win32 shell integration is ignored" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try parse(arena.allocator(), &.{
        "--shell-integration=not-a-mode",
        "--title=still parsed",
    });
    try testing.expectEqual(@as(?configpkg.Config.ShellIntegration, null), result.shell_integration);
    try testing.expectEqualStrings("still parsed", result.title.?);
}
