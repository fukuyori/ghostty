const std = @import("std");

const max_component = std.math.maxInt(u16);

/// Add the Windows resource file with a generated header containing the
/// application version. Windows stores four numeric 16-bit components, while
/// the string fields retain the complete semantic version. The fourth
/// component carries the fork's release sequence (see `buildComponent`) so
/// installers that compare numeric versions can tell previews apart.
pub fn add(
    b: *std.Build,
    module: *std.Build.Module,
    version: std.SemanticVersion,
    optimize: std.builtin.OptimizeMode,
) !void {
    const contents = try header(b.allocator, version, optimize);
    const generated = b.addWriteFiles().add(
        "ghostty-version.h",
        contents,
    );

    module.addWin32ResourceFile(.{
        .file = b.path("dist/windows/ghostty.rc"),
        .include_paths = &.{generated.dirname()},
    });
}

fn header(
    allocator: std.mem.Allocator,
    version: std.SemanticVersion,
    optimize: std.builtin.OptimizeMode,
) ![]u8 {
    if (version.major > max_component or
        version.minor > max_component or
        version.patch > max_component)
    {
        return error.WindowsVersionComponentTooLarge;
    }
    const build = try buildComponent(version);

    return std.fmt.allocPrint(
        allocator,
        \\#define GHOSTTY_VERSION_MAJOR {d}
        \\#define GHOSTTY_VERSION_MINOR {d}
        \\#define GHOSTTY_VERSION_PATCH {d}
        \\#define GHOSTTY_VERSION_BUILD {d}
        \\#define GHOSTTY_VERSION_DEBUG {d}
        \\#define GHOSTTY_VERSION_STRING "{f}"
        \\
    ,
        .{
            version.major,
            version.minor,
            version.patch,
            build,
            @intFromBool(optimize == .Debug),
            version,
        },
    );
}

/// Fourth numeric component for VERSIONINFO. Semantic versions have only
/// three numeric parts, so the fork's preview sequence is taken from the
/// pre-release: the last dot-separated identifier when it is purely numeric
/// (`1.3.2-windows.4` -> 4). Anything else, including plain `-dev` and the
/// branch-derived `-windows-` of ordinary git builds, yields 0.
fn buildComponent(version: std.SemanticVersion) !u16 {
    const pre = version.pre orelse return 0;
    var identifiers = std.mem.splitBackwardsScalar(u8, pre, '.');
    const last = identifiers.first();
    if (last.len == 0) return 0;
    for (last) |c| {
        if (!std.ascii.isDigit(c)) return 0;
    }
    return std.fmt.parseUnsigned(u16, last, 10) catch
        error.WindowsVersionComponentTooLarge;
}

test "header preserves a stable semantic version" {
    const allocator = std.testing.allocator;
    const contents = try header(
        allocator,
        try std.SemanticVersion.parse("1.2.3"),
        .ReleaseFast,
    );
    defer allocator.free(contents);

    try std.testing.expectEqualStrings(
        \\#define GHOSTTY_VERSION_MAJOR 1
        \\#define GHOSTTY_VERSION_MINOR 2
        \\#define GHOSTTY_VERSION_PATCH 3
        \\#define GHOSTTY_VERSION_BUILD 0
        \\#define GHOSTTY_VERSION_DEBUG 0
        \\#define GHOSTTY_VERSION_STRING "1.2.3"
        \\
    ,
        contents,
    );
}

test "header preserves prerelease and build metadata" {
    const allocator = std.testing.allocator;
    const contents = try header(
        allocator,
        try std.SemanticVersion.parse("1.3.2-windows-+abcdef0"),
        .Debug,
    );
    defer allocator.free(contents);

    try std.testing.expect(std.mem.endsWith(
        u8,
        contents,
        "#define GHOSTTY_VERSION_STRING \"1.3.2-windows-+abcdef0\"\n",
    ));
}

test "header maps the preview sequence to the fourth component" {
    const allocator = std.testing.allocator;
    const contents = try header(
        allocator,
        try std.SemanticVersion.parse("1.3.2-windows.4"),
        .ReleaseFast,
    );
    defer allocator.free(contents);

    try std.testing.expectEqualStrings(
        \\#define GHOSTTY_VERSION_MAJOR 1
        \\#define GHOSTTY_VERSION_MINOR 3
        \\#define GHOSTTY_VERSION_PATCH 2
        \\#define GHOSTTY_VERSION_BUILD 4
        \\#define GHOSTTY_VERSION_DEBUG 0
        \\#define GHOSTTY_VERSION_STRING "1.3.2-windows.4"
        \\
    ,
        contents,
    );
}

test "build component ignores non-numeric pre-release identifiers" {
    try std.testing.expectEqual(
        @as(u16, 0),
        try buildComponent(try std.SemanticVersion.parse("1.3.2-dev")),
    );
    try std.testing.expectEqual(
        @as(u16, 0),
        try buildComponent(try std.SemanticVersion.parse("1.3.2-windows-+abcdef0")),
    );
    try std.testing.expectEqual(
        @as(u16, 0),
        try buildComponent(try std.SemanticVersion.parse("1.3.2")),
    );
    try std.testing.expectEqual(
        @as(u16, 12),
        try buildComponent(try std.SemanticVersion.parse("1.3.2-rc.12")),
    );
    try std.testing.expectEqual(
        @as(u16, 65535),
        try buildComponent(try std.SemanticVersion.parse("1.3.2-windows.65535")),
    );
    try std.testing.expectError(
        error.WindowsVersionComponentTooLarge,
        buildComponent(try std.SemanticVersion.parse("1.3.2-windows.65536")),
    );
}

test "header rejects components that do not fit VERSIONINFO" {
    const version = try std.SemanticVersion.parse("65536.0.0");
    try std.testing.expectError(
        error.WindowsVersionComponentTooLarge,
        header(std.testing.allocator, version, .Debug),
    );
}
