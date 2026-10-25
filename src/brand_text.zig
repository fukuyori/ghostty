//! Compile-time rewrite of multi-line CLI and terminal messages that carry
//! the product name, so an upstream message block changes only where it is
//! wrapped: `brand_text.cli(\\... , &.{kept phrases})`. With the names in
//! src/brand.zig unchanged, the result equals the input.
//!
//! The rules match docs/windows-rebranding-plan.md, Section 2: commands
//! follow the executable name, the product name follows the display name,
//! and phrases that describe other platforms are kept. Single-line messages
//! concatenate `brand` values directly instead.

const std = @import("std");
const brand = @import("brand.zig");

/// `text` with the names from src/brand.zig. `keep` lists phrases copied as
/// written.
pub fn cli(comptime text: []const u8, comptime keep: []const []const u8) []const u8 {
    return comptime rewrite(text, keep, brand.display_name, brand.exe_name);
}

fn rewrite(
    comptime text: []const u8,
    comptime keep: []const []const u8,
    comptime display: []const u8,
    comptime exe: []const u8,
) []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out = text;
        for (keep, 0..) |phrase, i| {
            if (std.mem.indexOf(u8, out, phrase) == null) {
                @compileError("brand_text: kept phrase not found: " ++ phrase);
            }
            out = replace(out, phrase, token(i));
        }
        out = replace(out, "Usage: ghostty ", "Usage: " ++ exe ++ " ");
        out = replace(out, "`ghostty ", "`" ++ exe ++ " ");
        out = replace(out, "Ghostty", display);
        for (keep, 0..) |phrase, i| out = replace(out, token(i), phrase);
        return out;
    }
}

fn token(comptime i: usize) []const u8 {
    return std.fmt.comptimePrint("\x01{d}\x02", .{i});
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

test "brand text is unchanged with the Ghostty names" {
    const text =
        \\Usage: ghostty [+action] [options]
        \\Run the Ghostty terminal emulator. `ghostty -e top` runs top.
        \\Use `open -na Ghostty.app` on macOS.
    ;
    try std.testing.expectEqualStrings(text, comptime rewrite(text, &.{"open -na Ghostty.app"}, "Ghostty", "ghostty"));
}

test "brand text with substitute names keeps listed phrases" {
    const out = comptime rewrite(
        \\Usage: ghostty [+action] [options]
        \\Run the Ghostty terminal emulator. `ghostty -e top` runs top.
        \\Use `open -na Ghostty.app` or `open -na ghostty.app --args`.
    , &.{ "open -na Ghostty.app", "open -na ghostty.app" }, "Subst", "subst");
    try std.testing.expectEqualStrings(
        \\Usage: subst [+action] [options]
        \\Run the Subst terminal emulator. `subst -e top` runs top.
        \\Use `open -na Ghostty.app` or `open -na ghostty.app --args`.
    , out);
}
