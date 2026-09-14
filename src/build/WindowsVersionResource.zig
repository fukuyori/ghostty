const std = @import("std");

const max_component = std.math.maxInt(u16);

/// Add the Windows resource file with a generated header containing the
/// application version. Windows stores four numeric 16-bit components, while
/// the string fields retain the complete semantic version.
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

    return std.fmt.allocPrint(
        allocator,
        \\#define GHOSTTY_VERSION_MAJOR {d}
        \\#define GHOSTTY_VERSION_MINOR {d}
        \\#define GHOSTTY_VERSION_PATCH {d}
        \\#define GHOSTTY_VERSION_BUILD 0
        \\#define GHOSTTY_VERSION_DEBUG {d}
        \\#define GHOSTTY_VERSION_STRING "{f}"
        \\
    ,
        .{
            version.major,
            version.minor,
            version.patch,
            @intFromBool(optimize == .Debug),
            version,
        },
    );
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

test "header rejects components that do not fit VERSIONINFO" {
    const version = try std.SemanticVersion.parse("65536.0.0");
    try std.testing.expectError(
        error.WindowsVersionComponentTooLarge,
        header(std.testing.allocator, version, .Debug),
    );
}
