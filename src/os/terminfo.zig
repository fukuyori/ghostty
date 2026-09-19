//! Registration of Ghostty's terminfo entry in the running user's home
//! directory.
//!
//! Ghostty points TERMINFO at the database it ships, but on Windows that is a
//! Windows-style path, and the ncurses that comes with Git for Windows cannot
//! resolve it from a working directory on any drive other than the one
//! Ghostty is installed on. Every program that reads terminfo then reports
//!
//!     'xterm-ghostty': unknown terminal type.
//!
//! That the outcome turns on the current drive is measured, with ncurses 6.6
//! from Git for Windows. The mechanism is not: dropping the drive letter and
//! taking the rest from the root of the current drive would explain what was
//! seen, but that has not been confirmed.
//!
//! ncurses searches $HOME/.terminfo whatever TERMINFO holds, so an entry
//! there is found from any drive. Placing it is Ghostty's job rather than the
//! installer's: a machine-wide install runs as whoever elevated it, while
//! every user reaches this code as themselves.
//!
//! This covers the environments that take their home directory from the
//! Windows profile, which is what Git for Windows does (`db_home: env
//! windows` in its nsswitch.conf). Cygwin and MSYS2 proper keep their home
//! inside their own installation root and still need the one-time tic step in
//! docs/windows.md, as does anyone who points HOME somewhere else.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = @import("windows.zig");
const osfile = @import("file.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.terminfo);

/// ncurses on Windows keeps an entry under the hex form of its first
/// character, so xterm-ghostty lives in 78 rather than in x. An entry written
/// to x\ is not found.
const subdir = "78";
const entry_name = "xterm-ghostty";

/// A compiled entry is a few kilobytes. The bound only keeps a wrong
/// terminfo_dir from turning into a large allocation.
const max_entry_bytes = 1024 * 1024;

/// Copy the compiled xterm-ghostty entry out of `terminfo_dir` into the
/// running user's `.terminfo` unless something is already there.
///
/// `terminfo_dir` is the database Ghostty ships, the same directory that goes
/// into TERMINFO. This is a no-op off Windows, where TERMINFO is enough.
///
/// Failure is never fatal. The terminal starts either way, and the reason
/// goes to the log, which scripts/run-windows-diagnostics.ps1 captures.
pub fn ensureUserEntry(
    gpa: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    terminfo_dir: []const u8,
) void {
    if (comptime builtin.os.tag != .windows) return;

    register(gpa, io, environ_map, terminfo_dir) catch |err| log.warn(
        "unable to register the terminfo entry for this user err={t}",
        .{err},
    );
}

fn register(
    gpa: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    terminfo_dir: []const u8,
) !void {
    // Where Git for Windows puts $HOME. A HOME set to somewhere else is out
    // of scope; see the comment at the top of this file.
    const profile = environ_map.get("USERPROFILE") orelse
        return error.NoUserProfile;
    if (profile.len == 0) return error.NoUserProfile;

    const dest_dir = try std.fs.path.join(
        gpa,
        &.{ profile, ".terminfo", subdir },
    );
    defer gpa.free(dest_dir);
    const src = try std.fs.path.join(
        gpa,
        &.{ terminfo_dir, subdir, entry_name },
    );
    defer gpa.free(src);

    try install(gpa, io, src, dest_dir);
}

/// Copy `src` to `dest_dir`, named for the entry, unless `dest_dir` already
/// holds an entry by that name. Both paths are absolute.
fn install(
    gpa: Allocator,
    io: std.Io,
    src: []const u8,
    dest_dir: []const u8,
) !void {
    const dest = try std.fs.path.join(gpa, &.{ dest_dir, entry_name });
    defer gpa.free(dest);

    // The usual case once this has run once, and the case where the user
    // compiled their own entry with tic. Either way it is left as it is.
    if (std.Io.Dir.accessAbsolute(io, dest, .{})) |_| return else |_| {}

    const src_file = try std.Io.Dir.openFileAbsolute(io, src, .{});
    defer src_file.close(io);
    const stat = try src_file.stat(io);
    if (stat.size > max_entry_bytes) return error.EntryTooLarge;
    const data = try gpa.alloc(u8, @intCast(stat.size));
    defer gpa.free(data);
    // A short read means the file shrank between the stat and here, which
    // makes the entry we hold incomplete. Do not write a partial one.
    if (try src_file.readPositionalAll(io, data, 0) != data.len) {
        return error.EntryTruncated;
    }

    try std.Io.Dir.cwd().createDirPath(io, dest_dir);

    // The entry is written beside its destination and then moved onto it, so
    // that nothing ever observes a half-written file at the final path: the
    // check above finds either a complete entry or none at all. Writing the
    // final path directly would leave a Ghostty that starts alongside this
    // one, or one that starts after this one was killed mid-write, treating
    // an incomplete entry as registered, and nothing would repair it.
    const tmp_name = try std.fmt.allocPrint(
        gpa,
        "{s}.{d}.tmp",
        .{ entry_name, windows.GetCurrentProcessId() },
    );
    defer gpa.free(tmp_name);
    const tmp = try std.fs.path.join(gpa, &.{ dest_dir, tmp_name });
    defer gpa.free(tmp);

    // Deliberately not exclusive: a temporary file abandoned by an earlier
    // process that happened to hold this same pid would otherwise block
    // every future attempt.
    const tmp_file = try std.Io.Dir.createFileAbsolute(io, tmp, .{});
    errdefer std.Io.Dir.deleteFileAbsolute(io, tmp) catch {};
    {
        defer tmp_file.close(io);
        try tmp_file.writePositionalAll(io, data, 0);
    }

    moveNoReplace(gpa, tmp, dest) catch |err| switch (err) {
        // Another Ghostty got there while this copy was being written. Its
        // entry is as good as this one.
        error.PathAlreadyExists => {
            std.Io.Dir.deleteFileAbsolute(io, tmp) catch {};
            return;
        },
        else => return err,
    };
    log.info("registered the terminfo entry for this user path={s}", .{dest});
}

/// Move `from` onto `to`, failing rather than replacing an existing `to`.
///
/// std.Io.Dir.rename always replaces, and replacing is exactly what must not
/// happen here: the destination may be an entry the user compiled themselves.
fn moveNoReplace(gpa: Allocator, from: []const u8, to: []const u8) !void {
    const from_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, from);
    defer gpa.free(from_w);
    const to_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, to);
    defer gpa.free(to_w);

    if (windows.exp.kernel32.MoveFileExW(from_w, to_w, 0) != windows.FALSE) {
        return;
    }
    return switch (windows.GetLastError()) {
        .ALREADY_EXISTS, .FILE_EXISTS => error.PathAlreadyExists,
        else => |err| windows.unexpectedError(err),
    };
}

/// An absolute path to a directory that does not exist yet. The caller owns
/// the memory and is responsible for deleting the tree.
fn testDir(gpa: Allocator) ![]u8 {
    const root = try osfile.allocTmpDir(gpa, global.environ());
    defer osfile.freeTmpDir(gpa, root);

    var name_buf: [osfile.random_basename_len:0]u8 = undefined;
    const base = try osfile.randomBasename(&name_buf);
    return try std.fs.path.join(gpa, &.{ root, "ghostty-terminfo-test", base });
}

/// How many entries `dir` holds, so that a test can show that nothing was
/// left behind beside the entry itself.
fn testCount(io: std.Io, dir: []const u8) !usize {
    var handle = try std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true });
    defer handle.close(io);
    var it = handle.iterate();
    var count: usize = 0;
    while (try it.next(io)) |_| count += 1;
    return count;
}

test "install writes the entry when the directory is empty" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();

    const root = try testDir(alloc);
    defer alloc.free(root);
    defer cwd.deleteTree(io, root) catch {};

    const src = try std.fs.path.join(alloc, &.{ root, "src" });
    defer alloc.free(src);
    try cwd.createDirPath(io, root);
    try cwd.writeFile(io, .{ .sub_path = src, .data = "compiled entry" });

    const dest_dir = try std.fs.path.join(alloc, &.{ root, subdir });
    defer alloc.free(dest_dir);

    try install(alloc, io, src, dest_dir);

    const dest = try std.fs.path.join(alloc, &.{ dest_dir, entry_name });
    defer alloc.free(dest);
    const got = try cwd.readFileAlloc(io, dest, alloc, .limited(64));
    defer alloc.free(got);
    try testing.expectEqualStrings("compiled entry", got);

    // The temporary file it was written through is gone.
    try testing.expectEqual(@as(usize, 1), try testCount(io, dest_dir));
}

test "install never replaces an entry that is already there" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    // What a second Ghostty starting alongside the first one runs into, and
    // what protects an entry the user compiled with tic.
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();

    const root = try testDir(alloc);
    defer alloc.free(root);
    defer cwd.deleteTree(io, root) catch {};

    const src = try std.fs.path.join(alloc, &.{ root, "src" });
    defer alloc.free(src);
    try cwd.createDirPath(io, root);
    try cwd.writeFile(io, .{ .sub_path = src, .data = "compiled entry" });

    const dest_dir = try std.fs.path.join(alloc, &.{ root, subdir });
    defer alloc.free(dest_dir);
    try cwd.createDirPath(io, dest_dir);
    const dest = try std.fs.path.join(alloc, &.{ dest_dir, entry_name });
    defer alloc.free(dest);
    try cwd.writeFile(io, .{ .sub_path = dest, .data = "the user's own" });

    try install(alloc, io, src, dest_dir);

    const got = try cwd.readFileAlloc(io, dest, alloc, .limited(64));
    defer alloc.free(got);
    try testing.expectEqualStrings("the user's own", got);
    try testing.expectEqual(@as(usize, 1), try testCount(io, dest_dir));
}

test "install works with a temporary file left by an earlier run" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    // What a Ghostty killed part way through a write leaves behind. The name
    // carries the pid, so a later process can meet its own.
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();

    const root = try testDir(alloc);
    defer alloc.free(root);
    defer cwd.deleteTree(io, root) catch {};

    const src = try std.fs.path.join(alloc, &.{ root, "src" });
    defer alloc.free(src);
    try cwd.createDirPath(io, root);
    try cwd.writeFile(io, .{ .sub_path = src, .data = "compiled entry" });

    const dest_dir = try std.fs.path.join(alloc, &.{ root, subdir });
    defer alloc.free(dest_dir);
    try cwd.createDirPath(io, dest_dir);

    const stale_name = try std.fmt.allocPrint(
        alloc,
        "{s}.{d}.tmp",
        .{ entry_name, windows.GetCurrentProcessId() },
    );
    defer alloc.free(stale_name);
    const stale = try std.fs.path.join(alloc, &.{ dest_dir, stale_name });
    defer alloc.free(stale);
    try cwd.writeFile(io, .{ .sub_path = stale, .data = "half a" });

    try install(alloc, io, src, dest_dir);

    const dest = try std.fs.path.join(alloc, &.{ dest_dir, entry_name });
    defer alloc.free(dest);
    const got = try cwd.readFileAlloc(io, dest, alloc, .limited(64));
    defer alloc.free(got);
    try testing.expectEqualStrings("compiled entry", got);
    try testing.expectEqual(@as(usize, 1), try testCount(io, dest_dir));
}
