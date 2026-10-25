//! Build steps that pass a file or directory through src/build/brand_rewrite.zig
//! with the names from src/brand.zig. GhosttyResources.zig uses them for the
//! installed shell integration, completions and editor files, and
//! HelpStrings.zig for the generated help strings.

const std = @import("std");
const brand = @import("../brand.zig");

/// One host executable per build.
var exe_cache: ?*std.Build.Step.Compile = null;

fn exe(b: *std.Build) *std.Build.Step.Compile {
    if (exe_cache) |cached| return cached;
    const compiled = b.addExecutable(.{
        .name = "ghostty-brand-rewrite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/brand_rewrite.zig"),
            .target = b.graph.host,
        }),
    });
    exe_cache = compiled;
    return compiled;
}

/// The configuration file extension: `brand.config_file_name` after `config.`.
const config_ext = blk: {
    const prefix = "config.";
    if (!std.mem.startsWith(u8, brand.config_file_name, prefix)) {
        @compileError("brand.config_file_name must start with " ++ prefix);
    }
    break :blk brand.config_file_name[prefix.len..];
};

fn addNames(run: *std.Build.Step.Run) void {
    run.addArgs(&.{
        brand.display_name,
        brand.identifier,
        brand.env_prefix,
        brand.config_dir_name,
        config_ext,
        brand.resources_dir_name,
        brand.terminfo_name,
    });
}

/// `input` rewritten with a brand_rewrite.zig profile.
pub fn file(b: *std.Build, profile: []const u8, input: std.Build.LazyPath) std.Build.LazyPath {
    const run = b.addRunArtifact(exe(b));
    run.addArgs(&.{ "file", profile });
    run.addFileArg(input);
    const out = run.addOutputFileArg("rewritten");
    addNames(run);
    return out;
}

/// A directory tree rewritten with the shell profile, files renamed.
pub fn dir(b: *std.Build, input: std.Build.LazyPath, name: []const u8) std.Build.LazyPath {
    const run = b.addRunArtifact(exe(b));
    run.addArg("dir");
    run.addDirectoryArg(input);
    const out = run.addOutputDirectoryArg(name);
    addNames(run);
    // The input is a directory, whose contents the run step does not hash;
    // always rerun so edited files are installed.
    run.has_side_effects = true;
    return out;
}
