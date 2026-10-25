//! Removal of the old product's terminal variables from a child environment.
//!
//! A renamed build started from inside the old Ghostty inherits the
//! variables that Ghostty set for its own shell, such as
//! `GHOSTTY_RESOURCES_DIR` (pointing at the old installation) and
//! `GHOSTTY_SURFACE_ID` (a surface of the old terminal). Tools that still
//! read the old names would act on them, so they are removed before the
//! renamed terminal starts its child. Variables the user sets for the old
//! product, such as `GHOSTTY_LOG` or `GHOSTTY_PAGER`, are kept.
//!
//! With the names in src/brand.zig unchanged, the old and new prefixes are
//! the same and nothing is removed.

const std = @import("std");
const brand = @import("brand.zig");

/// Prefix of the variables set by the product before the rename.
const old_prefix = "GHOSTTY_";

/// Suffixes of the variables the terminal and its shell integration set for
/// the child shell (src/termio, src/Surface.zig, src/apprt/win32 and the
/// scripts under src/shell-integration).
const terminal_names = [_][]const u8{
    "BASH_ENV",
    "BASH_INJECT",
    "BASH_RCFILE",
    "BASH_UNEXPORT_HISTFILE",
    "BIN_DIR",
    "QUICK_TERMINAL",
    "RESOURCES_DIR",
    "SAVE_PS",
    "SHELL_FEATURES",
    "SHELL_INTEGRATION_POWERSHELL",
    "SHELL_INTEGRATION_XDG_DIR",
    "SURFACE_ID",
    "ZSH_ZDOTDIR",
};

/// Removes the old product's terminal variables from `env`.
pub fn removeOldTerminalVars(env: *std.process.Environ.Map) void {
    removeTerminalVars(env, old_prefix, brand.env_prefix);
}

fn removeTerminalVars(
    env: *std.process.Environ.Map,
    comptime old: []const u8,
    comptime new: []const u8,
) void {
    if (comptime std.mem.eql(u8, old, new)) return;
    inline for (terminal_names) |name| _ = env.orderedRemove(old ++ name);
}

test "old terminal variables are removed after a rename" {
    const testing = std.testing;
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("GHOSTTY_RESOURCES_DIR", "C:\\old\\share\\ghostty");
    try env.put("GHOSTTY_SURFACE_ID", "0x1");
    try env.put("GHOSTTY_SHELL_INTEGRATION_POWERSHELL", "old.ps1");
    try env.put("GHOSTTY_LOG", "stderr");
    try env.put("NEWTERM_SURFACE_ID", "0x2");

    removeTerminalVars(&env, "GHOSTTY_", "NEWTERM_");

    try testing.expect(env.get("GHOSTTY_RESOURCES_DIR") == null);
    try testing.expect(env.get("GHOSTTY_SURFACE_ID") == null);
    try testing.expect(env.get("GHOSTTY_SHELL_INTEGRATION_POWERSHELL") == null);
    try testing.expectEqualStrings("stderr", env.get("GHOSTTY_LOG").?);
    try testing.expectEqualStrings("0x2", env.get("NEWTERM_SURFACE_ID").?);
}

test "nothing is removed with the unchanged names" {
    const testing = std.testing;
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("GHOSTTY_RESOURCES_DIR", "C:\\share\\ghostty");

    removeTerminalVars(&env, "GHOSTTY_", "GHOSTTY_");

    try testing.expectEqualStrings("C:\\share\\ghostty", env.get("GHOSTTY_RESOURCES_DIR").?);
}
