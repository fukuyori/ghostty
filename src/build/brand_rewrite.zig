//! Build-time rewrite of installed files whose contents carry the product
//! name: the shell integration scripts and the generated completions and
//! editor files. The repository copies and the upstream generators stay as
//! upstream has them; the build copies their output through these rules
//! (docs/windows-rebranding-plan.md, Section 1.1 rule 2). With the names in
//! src/brand.zig unchanged, every rule maps a name to itself.
//!
//! Each profile is a list of exact substring rules applied in order, plus
//! lines that are copied verbatim (upstream attribution). A guard rewrites
//! every file a second time with substitute names and counts the Ghostty
//! names left over: it must equal the profile's expected count of kept
//! names, so a new upstream occurrence or a rule that hits a kept value
//! fails the build instead of shipping a half-renamed file.
//!
//! This file imports only std: the build helper tests compile it alone, and
//! build.zig passes the names from src/brand.zig on the command line.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Names = struct {
    /// Product name shown to people (`brand.display_name`).
    display: []const u8,
    /// Lowercase identifier (`brand.identifier`). The executable has the
    /// same name (`brand.exe_name`); brand.zig enforces that.
    identifier: []const u8,
    /// Environment variable prefix (`brand.env_prefix`).
    env_prefix: []const u8,
    /// Configuration directory name (`brand.config_dir_name`).
    config_dir: []const u8,
    /// Configuration file extension, the part of `brand.config_file_name`
    /// after `config.`.
    config_ext: []const u8,
    /// Directory under `share/` (`brand.resources_dir_name`).
    resources_dir: []const u8,
    /// Terminfo entry name (`brand.terminfo_name`).
    terminfo: []const u8,
};

const help = @import("brand_rewrite_help.zig");

test {
    _ = help;
}

pub const Profile = enum {
    /// Everything installed from src/shell-integration.
    shell,
    bash_completion,
    zsh_completion,
    fish_completion,
    /// Each of the four Vim/Neovim files.
    vim,
    sublime,
    /// The generated help strings (brand_rewrite_help.zig). Its guard does
    /// not use `expectedResidual`.
    help,

    /// Ghostty names that stay after the rewrite of one file: upstream URLs,
    /// the upstream `window-theme = ghostty` value, the Vim attribution line
    /// and, for fish, option descriptions that come from the CLI help.
    pub fn expectedResidual(self: Profile) usize {
        return switch (self) {
            .shell => 0,
            // `dark ghostty` and the ghostty-org/ghostty URL.
            .bash_completion => 3,
            // `dark ghostty`.
            .zsh_completion => 1,
            // `dark ghostty`. The option descriptions come from the help
            // strings; the help guard covers them and this one skips them.
            .fish_completion => 1,
            // The Maintainer line: `Ghostty <...ghostty-org/ghostty>`.
            .vim => 3,
            .sublime => 0,
            .help => 0,
        };
    }
};

const Rule = struct { from: []const u8, to: []const u8 };

/// Lines that contain one of these are copied verbatim.
fn keptLines(profile: Profile) []const []const u8 {
    return switch (profile) {
        .vim => &.{"\" Maintainer: Ghostty <"},
        else => &.{},
    };
}

fn rules(arena: Allocator, profile: Profile, n: Names) Allocator.Error![]const Rule {
    const id = n.identifier;
    const f = struct {
        fn cat(a: Allocator, parts: []const []const u8) Allocator.Error![]const u8 {
            return std.mem.concat(a, u8, parts);
        }
    }.cat;
    return switch (profile) {
        // No URL or configuration value occurs in the shell integration, so
        // after the explicit command paths every remaining name is renamed:
        // environment variables, internal function and variable names, file
        // and module names, and comments.
        .shell => try arena.dupe(Rule, &.{
            .{ .from = "GHOSTTY_", .to = n.env_prefix },
            .{ .from = "BIN_DIR/ghostty\"", .to = try f(arena, &.{ "BIN_DIR/", id, "\"" }) },
            .{ .from = "BIN_DIR/\"ghostty\"", .to = try f(arena, &.{ "BIN_DIR/\"", id, "\"" }) },
            .{ .from = "path join \"ghostty\"", .to = try f(arena, &.{ "path join \"", id, "\"" }) },
            .{ .from = "Ghostty", .to = n.display },
            .{ .from = "ghostty", .to = id },
        }),
        // Anchored rules only: `dark ghostty` is a window-theme value and the
        // completion carries an upstream URL.
        .bash_completion => try arena.dupe(Rule, &.{
            .{ .from = "-F _ghostty ghostty", .to = try f(arena, &.{ "-F _", id, " ", id }) },
            .{ .from = "_ghostty() {", .to = try f(arena, &.{ "_", id, "() {" }) },
            .{ .from = "local ghostty=\"$1\"", .to = try f(arena, &.{ "local ", id, "=\"$1\"" }) },
            .{ .from = "$ghostty +list-", .to = try f(arena, &.{ "$", id, " +list-" }) },
        }),
        .zsh_completion => try arena.dupe(Rule, &.{
            .{ .from = "#compdef ghostty", .to = try f(arena, &.{ "#compdef ", id }) },
            .{ .from = "$(ghostty +list-", .to = try f(arena, &.{ "$(", id, " +list-" }) },
            .{ .from = "_ghostty() {", .to = try f(arena, &.{ "_", id, "() {" }) },
            .{ .from = "_ghostty \"$@\"", .to = try f(arena, &.{ "_", id, " \"$@\"" }) },
        }),
        .fish_completion => try arena.dupe(Rule, &.{
            .{ .from = "complete -c ghostty ", .to = try f(arena, &.{ "complete -c ", id, " " }) },
            .{ .from = "(ghostty +list-", .to = try f(arena, &.{ "(", id, " +list-" }) },
        }),
        // After the attribution line (kept), every name is renamed. The
        // file-type patterns follow the configuration directory and file
        // extension before the plain identifier rule.
        .vim => try arena.dupe(Rule, &.{
            .{ .from = "*/ghostty/config,", .to = try f(arena, &.{ "*/", n.config_dir, "/config," }) },
            .{ .from = "*/ghostty/themes/*,", .to = try f(arena, &.{ "*/", n.config_dir, "/themes/*," }) },
            .{ .from = "*.ghostty setf", .to = try f(arena, &.{ "*.", n.config_ext, " setf" }) },
            .{ .from = "Ghostty", .to = n.display },
            .{ .from = "ghostty", .to = id },
        }),
        .sublime => try arena.dupe(Rule, &.{
            .{ .from = "  - ghostty\n", .to = try f(arena, &.{ "  - ", n.config_ext, "\n" }) },
            .{ .from = "Ghostty", .to = n.display },
            .{ .from = "ghostty", .to = id },
        }),
        .help => unreachable,
    };
}

/// Rewrite `input` with the profile's rules. The result is allocated with
/// `gpa`.
pub fn rewrite(gpa: Allocator, profile: Profile, n: Names, input: []const u8) Allocator.Error![]u8 {
    if (profile == .help) return help.rewrite(gpa, n, input, null);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = try rules(arena, profile, n);
    const kept = keptLines(profile);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, input, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        if (isKept(kept, line)) {
            try out.appendSlice(gpa, line);
            continue;
        }
        // Rules see the line with its newline so that a rule can anchor on
        // the end of a line.
        var text: []const u8 = try std.mem.concat(arena, u8, &.{ line, "\n" });
        for (list) |rule| {
            text = try std.mem.replaceOwned(u8, arena, text, rule.from, rule.to);
        }
        try out.appendSlice(gpa, text[0 .. text.len - 1]);
    }
    return out.toOwnedSlice(gpa);
}

fn isKept(kept: []const []const u8, line: []const u8) bool {
    for (kept) |marker| {
        if (std.mem.indexOf(u8, line, marker) != null) return true;
    }
    return false;
}

/// Occurrences of the Ghostty name, in any case.
pub fn residual(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + 7 <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i..][0..7], "ghostty")) count += 1;
    }
    return count;
}

/// Names that share no letters with Ghostty, so the guard can tell what the
/// rules renamed from what they kept.
pub const substitute: Names = .{
    .display = "Subst",
    .identifier = "subst",
    .env_prefix = "SUBST_",
    .config_dir = "substdir",
    .config_ext = "substext",
    .resources_dir = "substres",
    .terminfo = "xterm-subst",
};

pub const GuardError = error{UnexpectedGhosttyNames} || Allocator.Error;

/// Fail when rewriting with substitute names leaves a different number of
/// Ghostty names than the profile keeps. A profile that renames every name
/// (shell, Sublime) expects none, so it cannot tell a newly added URL or
/// configuration value from a name to rename; those profiles rely on their
/// files having none today.
pub fn guard(gpa: Allocator, profile: Profile, input: []const u8) GuardError!void {
    if (profile == .help) return help.guard(gpa, substitute, input);
    const probe = try rewrite(gpa, profile, substitute, input);
    defer gpa.free(probe);
    const counted = if (profile == .fish_completion) try withoutDescriptions(gpa, probe) else probe;
    defer if (counted.ptr != probe.ptr) gpa.free(counted);
    if (residual(counted) != profile.expectedResidual()) return error.UnexpectedGhosttyNames;
}

/// A fish completion without its ` -d "..."` descriptions, which come from
/// the help strings.
fn withoutDescriptions(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, " -d \"")) |start| {
        try out.appendSlice(gpa, text[i..start]);
        var end = start + " -d \"".len;
        while (end < text.len and text[end] != '"') : (end += 1) {
            if (text[end] == '\\') end += 1;
        }
        i = @min(end + 1, text.len);
    }
    try out.appendSlice(gpa, text[i..]);
    return out.toOwnedSlice(gpa);
}

/// Installed path of a shell integration file: every `ghostty` in the path
/// becomes the identifier (`bash/ghostty.bash`, `zsh/ghostty-integration`,
/// `nushell/vendor/autoload/ghostty.nu`, ...).
pub fn shellPath(gpa: Allocator, n: Names, path: []const u8) Allocator.Error![]u8 {
    return std.mem.replaceOwned(u8, gpa, path, "ghostty", n.identifier);
}

/// Copied byte for byte: a vendored third-party file with an upstream
/// patch marker.
pub fn isVerbatim(path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(path), "bash-preexec.sh");
}

// Command line, used by GhosttyResources.zig:
//
//   brand_rewrite file <profile> <input> <output> <names...>
//   brand_rewrite dir <input dir> <output dir> <names...>
//
// where <names...> is display, identifier, env prefix, configuration
// directory, configuration extension, resources directory and terminfo name. `dir` applies the shell profile to
// a directory tree, skipping Markdown files.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.Usage;
    const is_file = std.mem.eql(u8, args[1], "file");
    if (!is_file and !std.mem.eql(u8, args[1], "dir")) return error.Usage;
    // file: profile, input, output; dir: input, output; then the names.
    const first_name: usize = if (is_file) 5 else 4;
    if (args.len != first_name + 7) return error.Usage;
    const n: Names = .{
        .display = args[first_name],
        .identifier = args[first_name + 1],
        .env_prefix = args[first_name + 2],
        .config_dir = args[first_name + 3],
        .config_ext = args[first_name + 4],
        .resources_dir = args[first_name + 5],
        .terminfo = args[first_name + 6],
    };
    const cwd = std.Io.Dir.cwd();

    if (is_file) {
        const profile = std.meta.stringToEnum(Profile, args[2]) orelse return error.Usage;
        const input = try cwd.readFileAlloc(io, args[3], arena, .unlimited);
        try checkedGuard(profile, args[3], input);
        const output = try rewrite(arena, profile, n, input);
        try cwd.writeFile(io, .{ .sub_path = args[4], .data = output });
        return;
    }

    var in_dir = try cwd.openDir(io, args[2], .{ .iterate = true });
    defer in_dir.close(io);
    try cwd.createDirPath(io, args[3]);
    var out_dir = try cwd.openDir(io, args[3], .{});
    defer out_dir.close(io);

    var walker = try in_dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.basename, ".md")) continue;
        const input = try in_dir.readFileAlloc(io, entry.path, arena, .unlimited);
        const out_path = try shellPath(arena, n, entry.path);
        if (std.fs.path.dirname(out_path)) |parent| try out_dir.createDirPath(io, parent);
        if (isVerbatim(entry.path)) {
            try out_dir.writeFile(io, .{ .sub_path = out_path, .data = input });
            continue;
        }
        try checkedGuard(.shell, entry.path, input);
        const output = try rewrite(arena, .shell, n, input);
        try out_dir.writeFile(io, .{ .sub_path = out_path, .data = output });
    }
}

fn checkedGuard(profile: Profile, path: []const u8, input: []const u8) !void {
    guard(std.heap.page_allocator, profile, input) catch |err| switch (err) {
        error.UnexpectedGhosttyNames => {
            std.log.err(
                "{s}: the {t} rewrite leaves an unexpected number of Ghostty names; " ++
                    "update src/build/brand_rewrite.zig for the upstream change",
                .{ path, profile },
            );
            return err;
        },
        else => return err,
    };
}

const testing = std.testing;

const ghostty: Names = .{
    .display = "Ghostty",
    .identifier = "ghostty",
    .env_prefix = "GHOSTTY_",
    .config_dir = "ghostty",
    .config_ext = "ghostty",
    .resources_dir = "ghostty",
    .terminfo = "xterm-ghostty",
};

fn expectRewrite(profile: Profile, n: Names, input: []const u8, expected: []const u8) !void {
    const out = try rewrite(testing.allocator, profile, n, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "brand rewrite with the Ghostty names is the identity" {
    const samples = [_]struct { Profile, []const u8 }{
        .{ .shell, "if [[ -n \"$GHOSTTY_BIN_DIR\" ]]; then\n  \"$GHOSTTY_BIN_DIR/ghostty\" +ssh\nfi\n__ghostty_precmd() { :; }\n# Ghostty\n" },
        .{ .bash_completion, "_ghostty() {\n  local ghostty=\"$1\"\n  $($ghostty +list-themes)\n}\ncomplete -o nospace -o bashdefault -F _ghostty ghostty\n" },
        .{ .vim, "\" Language: Ghostty config file\n\" Maintainer: Ghostty <https://github.com/ghostty-org/ghostty>\nau BufRead,BufNewFile */ghostty/config,*/*.ghostty/config,*/ghostty/themes/*,*.ghostty setf ghostty\n" },
    };
    for (samples) |s| try expectRewrite(s[0], ghostty, s[1], s[1]);
}

test "brand rewrite shell profile renames every name" {
    try expectRewrite(
        .shell,
        .{ .display = "Newterm", .identifier = "newterm", .env_prefix = "NEWTERM_", .config_dir = "newterm", .config_ext = "newterm", .resources_dir = "newterm", .terminfo = "xterm-newterm" },
        "builtin local features=\"$GHOSTTY_SHELL_FEATURES\"\n" ++
            "  \"$GHOSTTY_BIN_DIR/ghostty\" +ssh \"$@\"\n" ++
            "var ghostty = $E:GHOSTTY_BIN_DIR/\"ghostty\"\n" ++
            "let ghostty = ($env.GHOSTTY_BIN_DIR? | path join \"ghostty\")\n" ++
            "export module ghostty {\n" ++
            "_GHOSTTY_SAVE_PS1=\"$PS1\" # Ghostty prompt\n",
        "builtin local features=\"$NEWTERM_SHELL_FEATURES\"\n" ++
            "  \"$NEWTERM_BIN_DIR/newterm\" +ssh \"$@\"\n" ++
            "var newterm = $E:NEWTERM_BIN_DIR/\"newterm\"\n" ++
            "let newterm = ($env.NEWTERM_BIN_DIR? | path join \"newterm\")\n" ++
            "export module newterm {\n" ++
            "_NEWTERM_SAVE_PS1=\"$PS1\" # Newterm prompt\n",
    );
}

test "brand rewrite completions keep the window-theme value and URLs" {
    try expectRewrite(
        .bash_completion,
        substitute,
        "_ghostty() {\n" ++
            "  local ghostty=\"$1\"\n" ++
            "  --font-family) mapfile -t COMPREPLY < <( $ghostty +list-fonts );;\n" ++
            "  --window-theme) _compreply compgen -W \"auto system light dark ghostty\" -- \"$cur\";;\n" ++
            "  # see: https://github.com/ghostty-org/ghostty/discussions/2994\n" ++
            "}\n" ++
            "complete -o nospace -o bashdefault -F _ghostty ghostty\n",
        "_subst() {\n" ++
            "  local subst=\"$1\"\n" ++
            "  --font-family) mapfile -t COMPREPLY < <( $subst +list-fonts );;\n" ++
            "  --window-theme) _compreply compgen -W \"auto system light dark ghostty\" -- \"$cur\";;\n" ++
            "  # see: https://github.com/ghostty-org/ghostty/discussions/2994\n" ++
            "}\n" ++
            "complete -o nospace -o bashdefault -F _subst subst\n",
    );
    try expectRewrite(
        .zsh_completion,
        substitute,
        "#compdef ghostty\n  local font_list=$(ghostty +list-fonts)\n\"--window-theme=-:::(auto system light dark ghostty)\"\n_ghostty() {\n_ghostty \"$@\"\n",
        "#compdef subst\n  local font_list=$(subst +list-fonts)\n\"--window-theme=-:::(auto system light dark ghostty)\"\n_subst() {\n_subst \"$@\"\n",
    );
    try expectRewrite(
        .fish_completion,
        substitute,
        "complete -c ghostty -f -l font-family -r -f -a \"(ghostty +list-fonts | grep '^[A-Z]')\"\n" ++
            "complete -c ghostty -f -l window-theme -r -f -a \"auto system light dark ghostty\"\n",
        "complete -c subst -f -l font-family -r -f -a \"(subst +list-fonts | grep '^[A-Z]')\"\n" ++
            "complete -c subst -f -l window-theme -r -f -a \"auto system light dark ghostty\"\n",
    );
}

test "brand rewrite vim keeps the attribution and follows config names" {
    try expectRewrite(
        .vim,
        substitute,
        "\" Language: Ghostty config file\n" ++
            "\" Maintainer: Ghostty <https://github.com/ghostty-org/ghostty>\n" ++
            "au BufRead,BufNewFile */ghostty/config,*/*.ghostty/config,*/ghostty/themes/*,*.ghostty setf ghostty\n" ++
            "setlocal keywordprg=ghostty\\ +explain-config\n" ++
            "let b:current_syntax = 'ghostty'\n" ++
            "syn keyword ghosttyConfigKeyword\n",
        "\" Language: Subst config file\n" ++
            "\" Maintainer: Ghostty <https://github.com/ghostty-org/ghostty>\n" ++
            "au BufRead,BufNewFile */substdir/config,*/*.subst/config,*/substdir/themes/*,*.substext setf subst\n" ++
            "setlocal keywordprg=subst\\ +explain-config\n" ++
            "let b:current_syntax = 'subst'\n" ++
            "syn keyword substConfigKeyword\n",
    );
    try expectRewrite(
        .sublime,
        substitute,
        "name: Ghostty Config\nfile_extensions:\n  - ghostty\nscope: source.ghostty\n",
        "name: Subst Config\nfile_extensions:\n  - substext\nscope: source.subst\n",
    );
}

test "brand rewrite guard counts kept names" {
    try guard(testing.allocator, .zsh_completion, "#compdef ghostty\n(auto system light dark ghostty)\n");
    try testing.expectError(
        error.UnexpectedGhosttyNames,
        guard(testing.allocator, .zsh_completion, "#compdef ghostty\nghostty +new-thing\n(auto dark ghostty)\n"),
    );
}

test "brand rewrite shell paths" {
    const p = try shellPath(testing.allocator, substitute, "nushell/vendor/autoload/ghostty.nu");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("nushell/vendor/autoload/subst.nu", p);
    try testing.expect(isVerbatim("bash/bash-preexec.sh"));
    try testing.expect(!isVerbatim("bash/ghostty.bash"));
}
