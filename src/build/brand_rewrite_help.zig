//! The `help` profile of brand_rewrite.zig: the generated help strings
//! (src/helpgen.zig output, imported as `help_strings`), which carry the
//! upstream configuration and action documentation. Action `--help`,
//! `+explain-config`, `+show-config --docs` and the fish completion
//! descriptions all print from it.
//!
//! The input is Zig source. Only the contents of `\\` string lines are
//! rewritten; declarations stay as they are. Upstream edits these docs
//! often, so names are renamed by default and only listed exceptions are
//! kept (owner decisions, 2026-10-25, docs/windows-port-log.md):
//!
//! - whole entries of options and actions that only exist on other
//!   platforms;
//! - phrases: statements about macOS, GTK, Linux, Wayland or KWin behavior,
//!   upstream version history ("since Ghostty 1.3.0"), the Ghostty website,
//!   the `window-theme` value `ghostty`, macOS and GTK identifiers, URLs.
//!
//! The guard (`guard`) rewrites with substitute names and fails when a
//! Ghostty name is left outside the kept entries and phrases, when a kept
//! entry or phrase no longer matches (the list went stale after an
//! upstream change), or when a renamed form that the docs always contain is
//! missing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Names = @import("brand_rewrite.zig").Names;

/// Entries copied verbatim, by struct and entry name.
const kept_entries = [_][2][]const u8{
    .{ "Config", "language" },
    .{ "Config", "class" },
    .{ "Config", "quit-after-last-window-closed-delay" },
    .{ "Config", "async-backend" },
    .{ "Config", "auto-update" },
    .{ "Config", "auto-update-channel" },
    .{ "Config", "app-notifications" },
    .{ "Action", "new-window" },
    .{ "Action", "toggle-quick-terminal" },
    .{ "KeybindAction", "toggle_tab_overview" },
    .{ "KeybindAction", "toggle_secure_input" },
    .{ "KeybindAction", "toggle_visibility" },
    .{ "KeybindAction", "undo" },
};

/// Config entries with these prefixes are copied verbatim.
const kept_config_prefixes = [_][]const u8{ "macos-", "gtk-", "linux-", "x11-" };

/// Phrases kept as written wherever they occur in a renamed entry.
const kept_phrases = [_][]const u8{
    // Platform statements.
    "On macOS, Ghostty",
    "therefore also Ghostty's",
    "Ghostty.app/Contents/Resources/ghostty/themes",
    "On macOS, changing this configuration requires restarting Ghostty",
    "On Wayland, Ghostty",
    "if Ghostty can detect it is launched from launchd",
    "On Linux with GTK, if Ghostty can detect",
    "to Ghostty. When a `global:` keybind is specified and Ghostty is launched",
    "or reloaded, Ghostty will attempt to request these permissions.",
    "On Linux, if this is `true`, Ghostty",
    "not chosen by Ghostty.",
    "Ghostty uses the compositor-reported",
    "instances of applications. If Ghostty",
    "If Ghostty is compiled with debug optimizations,",
    "On GTK, D-Bus activation must be properly configured. Ghostty does not need",
    "a new Ghostty window to edit the configuration file. GTK only.",
    "version can be found by running `ghostty +version`.",
    "plugin in the plugin list. Ghostty would then need to be restarted",
    "~/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
    "com.mitchellh.ghostty",
    // Upstream's website and configuration values.
    "Ghostty website",
    "`ghostty` - Use the background",
    "window-theme is set to ghostty",
};

const Rule = struct { from: []const u8, to: []const u8 };

fn rules(arena: Allocator, n: Names) Allocator.Error![]const Rule {
    const cat = struct {
        fn f(a: Allocator, parts: []const []const u8) Allocator.Error![]const u8 {
            return std.mem.concat(a, u8, parts);
        }
    }.f;
    const x = n.identifier;
    const config_file = try cat(arena, &.{ "config.", n.config_ext });
    return arena.dupe(Rule, &.{
        .{ .from = "GHOSTTY_", .to = n.env_prefix },
        .{ .from = "xterm-ghostty", .to = n.terminfo },
        .{ .from = "keyprotocol=ghostty:", .to = try cat(arena, &.{ "keyprotocol=", n.identifier, ":" }) },
        .{ .from = "$XDG_CONFIG_HOME/ghostty/", .to = try cat(arena, &.{ "$XDG_CONFIG_HOME/", n.config_dir, "/" }) },
        .{ .from = "~/.config/ghostty/", .to = try cat(arena, &.{ "~/.config/", n.config_dir, "/" }) },
        .{ .from = "config.ghostty", .to = config_file },
        .{ .from = "share/ghostty/", .to = try cat(arena, &.{ "share/", n.resources_dir, "/" }) },
        .{ .from = "ghostty +", .to = try cat(arena, &.{ x, " +" }) },
        .{ .from = "ghostty --", .to = try cat(arena, &.{ x, " --" }) },
        .{ .from = "`ghostty -e", .to = try cat(arena, &.{ "`", x, " -e" }) },
        .{ .from = "`ghostty`", .to = try cat(arena, &.{ "`", x, "`" }) },
        .{ .from = "Ghostty", .to = n.display },
    });
}

pub const Stats = struct {
    /// How often each kept entry and phrase matched.
    entries: [kept_entries.len]usize = @splat(0),
    phrases: [kept_phrases.len]usize = @splat(0),
    /// Ghostty names left in renamed lines outside kept phrases, with the
    /// first such line for the diagnostic.
    unexplained: usize = 0,
    first_unexplained: ?[]const u8 = null,
};

/// Rewrite the generated help source. With `stats`, also record what the
/// guard needs; residual names are counted only then.
pub fn rewrite(gpa: Allocator, n: Names, input: []const u8, stats: ?*Stats) Allocator.Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = try rules(arena, n);

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| try lines.append(arena, line);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var struct_name: []const u8 = "";
    var entry: []const u8 = "";
    for (lines.items, 0..) |line, i| {
        if (i > 0) try out.append(gpa, '\n');
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "pub const ")) {
            const name = declName(trimmed["pub const ".len..]);
            if (std.mem.endsWith(u8, trimmed, "= struct {")) {
                struct_name = name;
                entry = "";
            } else {
                entry = name;
            }
            try out.appendSlice(gpa, line);
            continue;
        }
        if (!std.mem.startsWith(u8, trimmed, "\\\\") or keptEntry(struct_name, entry, stats)) {
            try out.appendSlice(gpa, line);
            continue;
        }

        // Protect kept text behind placeholders, apply the rules, restore.
        var protected: std.ArrayList([]const u8) = .empty;
        var text: []const u8 = line;
        for (kept_phrases, 0..) |phrase, p| {
            const count = std.mem.count(u8, text, phrase);
            if (count == 0) continue;
            if (stats) |s| s.phrases[p] += count;
            text = try std.mem.replaceOwned(u8, arena, text, phrase, try placeholder(arena, &protected, phrase));
        }
        text = try protectUrls(arena, text, &protected);
        text = try protectVersions(arena, text, nextContent(lines.items, i), &protected);
        for (list) |rule| text = try std.mem.replaceOwned(u8, arena, text, rule.from, rule.to);

        if (stats) |s| {
            const left = residual(text);
            if (left > 0) {
                s.unexplained += left;
                if (s.first_unexplained == null) s.first_unexplained = try gpa.dupe(u8, std.mem.trim(u8, line, " "));
            }
        }
        for (protected.items, 0..) |original, p| {
            text = try std.mem.replaceOwned(u8, arena, text, try token(arena, p), original);
        }
        try out.appendSlice(gpa, text);
    }
    return out.toOwnedSlice(gpa);
}

fn declName(rest: []const u8) []const u8 {
    if (std.mem.startsWith(u8, rest, "@\"")) {
        const end = std.mem.indexOfScalarPos(u8, rest, 2, '"') orelse return rest;
        return rest[2..end];
    }
    const end = std.mem.indexOfAny(u8, rest, ": =") orelse rest.len;
    return rest[0..end];
}

fn keptEntry(struct_name: []const u8, entry: []const u8, stats: ?*Stats) bool {
    for (kept_entries, 0..) |kept, i| {
        if (std.mem.eql(u8, kept[0], struct_name) and std.mem.eql(u8, kept[1], entry)) {
            if (stats) |s| s.entries[i] += 1;
            return true;
        }
    }
    if (!std.mem.eql(u8, struct_name, "Config")) return false;
    for (kept_config_prefixes) |prefix| {
        if (std.mem.startsWith(u8, entry, prefix)) return true;
    }
    return false;
}

/// Placeholders use control bytes, which neither the docs nor any rule
/// contain.
fn token(arena: Allocator, index: usize) Allocator.Error![]const u8 {
    return arena.print("\x01{d}\x02", .{index});
}

fn placeholder(arena: Allocator, protected: *std.ArrayList([]const u8), original: []const u8) Allocator.Error![]const u8 {
    try protected.append(arena, original);
    return token(arena, protected.items.len - 1);
}

fn protectUrls(arena: Allocator, text: []const u8, protected: *std.ArrayList([]const u8)) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const start = std.mem.indexOfPos(u8, text, i, "http") orelse break;
        const rest = text[start..];
        if (!std.mem.startsWith(u8, rest, "https://") and !std.mem.startsWith(u8, rest, "http://")) {
            try out.appendSlice(arena, text[i .. start + 4]);
            i = start + 4;
            continue;
        }
        const end = std.mem.indexOfAnyPos(u8, text, start, " `)>\"'") orelse text.len;
        try out.appendSlice(arena, text[i..start]);
        try out.appendSlice(arena, try placeholder(arena, protected, text[start..end]));
        i = end;
    }
    try out.appendSlice(arena, text[i..]);
    return out.toOwnedSlice(arena);
}

/// Upstream version history: "Ghostty 1.2.0", including a version that
/// wraps to the next line ("introduced in Ghostty" / "1.2.1.").
fn protectVersions(
    arena: Allocator,
    text: []const u8,
    next: []const u8,
    protected: *std.ArrayList([]const u8),
) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "Ghostty")) |at| {
        const after = text[at + 7 ..];
        const versioned = (after.len >= 2 and after[0] == ' ' and std.ascii.isDigit(after[1])) or
            (std.mem.trimEnd(u8, after, " ").len == 0 and next.len > 0 and std.ascii.isDigit(next[0]));
        try out.appendSlice(arena, text[i..at]);
        if (versioned) {
            try out.appendSlice(arena, try placeholder(arena, protected, "Ghostty"));
        } else {
            try out.appendSlice(arena, "Ghostty");
        }
        i = at + 7;
    }
    try out.appendSlice(arena, text[i..]);
    return out.toOwnedSlice(arena);
}

/// The text of the next line after its `\\`, for wrapped version numbers.
fn nextContent(lines: []const []const u8, i: usize) []const u8 {
    if (i + 1 >= lines.len) return "";
    const next = std.mem.trimStart(u8, lines[i + 1], " ");
    if (!std.mem.startsWith(u8, next, "\\\\")) return "";
    return next[2..];
}

fn residual(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + 7 <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i..][0..7], "ghostty")) count += 1;
    }
    return count;
}

pub const GuardError = error{UnexpectedGhosttyNames} || Allocator.Error;

/// See the file comment. Diagnostics go to the build log.
pub fn guard(gpa: Allocator, substitute: Names, input: []const u8) GuardError!void {
    var stats: Stats = .{};
    const out = try rewrite(gpa, substitute, input, &stats);
    defer gpa.free(out);
    defer if (stats.first_unexplained) |line| gpa.free(line);

    var failed = false;
    if (stats.unexplained > 0) {
        std.log.err("help: {d} Ghostty name(s) not covered by a rule or kept phrase, first in: {s}", .{ stats.unexplained, stats.first_unexplained.? });
        failed = true;
    }
    for (stats.entries, kept_entries) |count, kept| {
        if (count == 0) {
            std.log.err("help: kept entry {s}.{s} no longer exists", .{ kept[0], kept[1] });
            failed = true;
        }
    }
    for (stats.phrases, kept_phrases) |count, phrase| {
        if (count == 0) {
            std.log.err("help: kept phrase no longer matches: {s}", .{phrase});
            failed = true;
        }
    }
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const required = [_][]const u8{
        try arena.print("{s} +list-fonts", .{substitute.identifier}),
        try arena.print("{s}RESOURCES_DIR", .{substitute.env_prefix}),
        substitute.terminfo,
        try arena.print("share/{s}/themes", .{substitute.resources_dir}),
        try arena.print("{s}/config.{s}", .{ substitute.config_dir, substitute.config_ext }),
        substitute.display,
    };
    for (required) |pattern| {
        if (std.mem.indexOf(u8, out, pattern) == null) {
            std.log.err("help: renamed form missing from the output: {s}", .{pattern});
            failed = true;
        }
    }
    if (failed) return error.UnexpectedGhosttyNames;
}

const testing = std.testing;

const subst: Names = .{
    .display = "Subst",
    .identifier = "subst",
    .env_prefix = "SUBST_",
    .config_dir = "substdir",
    .config_ext = "substext",
    .resources_dir = "substres",
    .terminfo = "xterm-subst",
};

const sample =
    \\pub const Config = struct {
    \\pub const @"font-family": [:0]const u8 =
    \\    \\Run `ghostty +list-fonts` to list fonts. Ghostty uses them.
    \\    \\On macOS, Ghostty by default will always use emoji.
    \\    \\Specifying a prefix was introduced in Ghostty
    \\    \\1.2.1. Since Ghostty 1.4.0, it works. See https://ghostty.org/docs.
    \\    \\Set `GHOSTTY_RESOURCES_DIR` or `TERM=xterm-ghostty`; `ghostty -e fish`.
    \\    \\Themes in `$XDG_CONFIG_HOME/ghostty/themes` and `share/ghostty/themes`,
    \\    \\config in `$XDG_CONFIG_HOME/ghostty/config.ghostty`.
    \\    \\  * `ghostty` - Use the background colors. `:set keyprotocol=ghostty:kitty`
    \\;
    \\pub const @"macos-icon": [:0]const u8 =
    \\    \\The Ghostty icon on macOS.
    \\;
    \\};
    \\
;

test "help rewrite renames by default and keeps exceptions" {
    const out = try rewrite(testing.allocator, subst, sample, null);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\pub const Config = struct {
        \\pub const @"font-family": [:0]const u8 =
        \\    \\Run `subst +list-fonts` to list fonts. Subst uses them.
        \\    \\On macOS, Ghostty by default will always use emoji.
        \\    \\Specifying a prefix was introduced in Ghostty
        \\    \\1.2.1. Since Ghostty 1.4.0, it works. See https://ghostty.org/docs.
        \\    \\Set `SUBST_RESOURCES_DIR` or `TERM=xterm-subst`; `subst -e fish`.
        \\    \\Themes in `$XDG_CONFIG_HOME/substdir/themes` and `share/substres/themes`,
        \\    \\config in `$XDG_CONFIG_HOME/substdir/config.substext`.
        \\    \\  * `ghostty` - Use the background colors. `:set keyprotocol=subst:kitty`
        \\;
        \\pub const @"macos-icon": [:0]const u8 =
        \\    \\The Ghostty icon on macOS.
        \\;
        \\};
        \\
    , out);
}

test "help rewrite is the identity with the Ghostty names" {
    const ghostty: Names = .{
        .display = "Ghostty",
        .identifier = "ghostty",
        .env_prefix = "GHOSTTY_",
        .config_dir = "ghostty",
        .config_ext = "ghostty",
        .resources_dir = "ghostty",
        .terminfo = "xterm-ghostty",
    };
    const out = try rewrite(testing.allocator, ghostty, sample, null);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(sample, out);
}

test "help rewrite counts names it cannot explain" {
    var stats: Stats = .{};
    const out = try rewrite(testing.allocator, subst,
        \\pub const Config = struct {
        \\pub const title: [:0]const u8 =
        \\    \\Set by the ghostty process.
        \\;
        \\};
    , &stats);
    defer testing.allocator.free(out);
    defer if (stats.first_unexplained) |line| testing.allocator.free(line);
    try testing.expectEqual(@as(usize, 1), stats.unexplained);
}
