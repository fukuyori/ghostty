//! Windows path checks used before handing a path to the file system.

const std = @import("std");

/// Longest name component NTFS accepts, in UTF-16 code units.
const max_component_len = 255;

/// Longest whole path accepted, in UTF-16 code units. std converts the path
/// into a fixed 32767-unit buffer with an NT prefix and does not bounds-check
/// it, so stay well below that.
const max_path_len = 32000;

/// Whether `path` can be given to `std.Io.Dir.access` without reaching an
/// NT status that Zig's std treats as a programmer bug. In Debug builds std
/// panics on `OBJECT_NAME_INVALID`, so a path built from arbitrary terminal
/// text (a URL joined to the pwd, for example) must be rejected first.
///
/// This rejects the cases known to reach that status: `:` after an optional
/// drive (`C:`) or device (`\\?\`, `\\.\`) prefix, the other characters NTFS
/// does not allow in names, control characters, a component longer than 255
/// UTF-16 code units, a path too long for std's conversion buffer, and text
/// that is not valid WTF-8. It is not a full validation of Windows paths.
/// Rejecting `:` also rejects alternate data streams (`file.txt:stream`).
pub fn isCheckable(path: []const u8) bool {
    const path_len = std.unicode.calcWtf16LeLen(path) catch return false;
    if (path_len > max_path_len) return false;

    var rest = path;
    if (std.mem.startsWith(u8, rest, "\\\\?\\") or
        std.mem.startsWith(u8, rest, "\\\\.\\"))
    {
        rest = rest[4..];
    }
    if (rest.len >= 2 and std.ascii.isAlphabetic(rest[0]) and rest[1] == ':') {
        rest = rest[2..];
    }

    for (rest) |c| switch (c) {
        0...0x1F, ':', '<', '>', '"', '|', '?', '*' => return false,
        else => {},
    };

    var components = std.mem.tokenizeAny(u8, rest, "\\/");
    while (components.next()) |component| {
        const len = std.unicode.calcWtf16LeLen(component) catch return false;
        if (len > max_component_len) return false;
    }
    return true;
}

test "Windows paths that can be checked" {
    const testing = std.testing;
    try testing.expect(isCheckable("C:\\Users\\test\\file.txt"));
    try testing.expect(isCheckable("C:\\Users\\test\\dir\\..\\file.txt"));
    try testing.expect(isCheckable("\\\\server\\share\\file.txt"));
    try testing.expect(isCheckable("\\\\?\\C:\\long\\path.txt"));
    try testing.expect(isCheckable("relative\\file.txt"));
    try testing.expect(isCheckable("C:\\" ++ repeatForTest("a", max_component_len)));
    // Non-ASCII names are counted in UTF-16 code units, not bytes.
    try testing.expect(isCheckable("C:\\" ++ repeatForTest("\u{3042}", max_component_len)));
}

test "Windows paths that cannot be checked" {
    const testing = std.testing;
    // A URL joined to the pwd, as resolvePathForOpening builds it.
    try testing.expect(!isCheckable("C:\\Users\\test\\http:\\127.0.0.1:65530"));
    try testing.expect(!isCheckable("C:\\Users\\test\\mailto:user@example.com"));
    try testing.expect(!isCheckable("C:\\Users\\test\\a?b"));
    try testing.expect(!isCheckable("C:\\Users\\test\\a*b"));
    try testing.expect(!isCheckable("C:\\Users\\test\\a\"b"));
    try testing.expect(!isCheckable("C:\\Users\\test\\a\x01b"));
    try testing.expect(!isCheckable("C:\\Users\\test\\file.txt:stream"));
    try testing.expect(!isCheckable("C:\\" ++ repeatForTest("a", max_component_len + 1)));
    try testing.expect(!isCheckable("C:\\" ++ (repeatForTest("a\\", max_path_len / 2 + 1))));
    try testing.expect(!isCheckable("C:\\Users\\\xff"));
}

fn repeatForTest(comptime text: []const u8, comptime count: usize) [text.len * count]u8 {
    var result: [text.len * count]u8 = undefined;
    for (0..count) |i| @memcpy(result[i * text.len ..][0..text.len], text);
    return result;
}
