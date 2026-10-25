//! The configuration template written when no configuration file exists,
//! with the product name from src/brand.zig. The template stays as upstream
//! has it (config-template); this rewrites it at compile time
//! (docs/windows-rebranding-plan.md, Section 2, "Configuration template").
//! With the names in brand.zig unchanged, the result equals the template.
//!
//! The template is a `print` format string, so the rewrite must not add `{`
//! or `}`; product names never contain them.

const std = @import("std");
const brand = @import("../brand.zig");

pub const text = rewrite(@embedFile("config-template"), brand.display_name, brand.exe_name);

/// The line pointing at upstream's documentation is kept verbatim: that
/// site documents Ghostty, and the URL stays.
const kept_line = "# on Ghostty's website, at https://ghostty.org/docs/config.";

fn rewrite(comptime input: []const u8, comptime display: []const u8, comptime exe: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(200_000);
        const at = std.mem.indexOf(u8, input, kept_line) orelse
            @compileError("config-template no longer has the upstream documentation line");
        const before = input[0..at];
        const after = input[at + kept_line.len ..];
        return renamed(before, display, exe) ++ kept_line ++ renamed(after, display, exe);
    }
}

fn renamed(comptime s: []const u8, comptime display: []const u8, comptime exe: []const u8) []const u8 {
    return replace(replace(s, "`ghostty +", "`" ++ exe ++ " +"), "Ghostty", display);
}

fn replace(comptime s: []const u8, comptime from: []const u8, comptime to: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var rest = s;
        while (std.mem.indexOf(u8, rest, from)) |i| {
            out = out ++ rest[0..i] ++ to;
            rest = rest[i + from.len ..];
        }
        return out ++ rest;
    }
}

test "config template is unchanged with the Ghostty names" {
    try std.testing.expectEqualStrings(@embedFile("config-template"), text);
}

test "config template rewrite with substitute names" {
    const out = comptime rewrite(@embedFile("config-template"), "Subst", "subst");
    // Kept: `Ghostty's website` and the ghostty.org URL on the kept line.
    var count: usize = 0;
    var i: usize = 0;
    while (i + 7 <= out.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(out[i..][0..7], "ghostty")) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(std.mem.indexOf(u8, out, "{[path]s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "`subst +show-config") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "configuration file for Subst.") != null);
}
