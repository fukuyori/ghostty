//! Versioned persistence for Win32 window, tab, split, and working-directory
//! state. Terminal processes and scrollback are deliberately not serialized.

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../../global.zig");

pub const schema_version: u32 = 1;
pub const max_windows = 16;
pub const max_tabs_per_window = 64;
pub const max_panes_per_tab = 64;
pub const max_tree_depth = 32;
pub const max_state_bytes = 4 * 1024 * 1024;

pub const State = struct {
    schema: u32 = schema_version,
    windows: []const Window = &.{},
    active_window: usize = 0,
};

pub const Window = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    maximized: bool = false,
    active_tab: usize = 0,
    tabs: []const Tab,
};

pub const Tab = struct {
    title_override: ?[]const u8 = null,
    focused_pane: usize = 0,
    root: Node,
};

pub const Direction = enum { horizontal, vertical };

pub const Node = union(enum) {
    leaf: Leaf,
    split: Split,
};

pub const Leaf = struct {
    working_directory: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

pub const Split = struct {
    direction: Direction,
    ratio: f32 = 0.5,
    children: []const Node,
};

pub fn validate(state: State) error{InvalidState}!void {
    if (state.schema != schema_version or state.windows.len == 0 or
        state.windows.len > max_windows or state.active_window >= state.windows.len)
        return error.InvalidState;

    var remaining: usize = max_windows * max_tabs_per_window * (2 * max_panes_per_tab - 1);
    for (state.windows) |window| {
        if (window.width < 160 or window.height < 120 or
            window.width > 32768 or window.height > 32768 or
            window.x < -1_000_000 or window.x > 1_000_000 or
            window.y < -1_000_000 or window.y > 1_000_000 or
            window.tabs.len == 0 or window.tabs.len > max_tabs_per_window or
            window.active_tab >= window.tabs.len)
            return error.InvalidState;

        for (window.tabs) |tab| {
            var leaves: usize = 0;
            try validateNode(tab.root, 0, &remaining, &leaves);
            if (leaves == 0 or leaves > max_panes_per_tab or
                tab.focused_pane >= leaves or
                (tab.title_override != null and tab.title_override.?.len > 32768))
                return error.InvalidState;
        }
    }
}

fn validateNode(
    node: Node,
    depth: usize,
    remaining: *usize,
    leaves: *usize,
) error{InvalidState}!void {
    if (depth > max_tree_depth or remaining.* == 0) return error.InvalidState;
    remaining.* -= 1;
    switch (node) {
        .leaf => |leaf| {
            leaves.* += 1;
            if (leaf.working_directory) |path| {
                if (path.len == 0 or path.len > 32768) return error.InvalidState;
            }
            if (leaf.title) |title| if (title.len > 32768) return error.InvalidState;
        },
        .split => |split| {
            if (split.children.len != 2 or !std.math.isFinite(split.ratio) or
                split.ratio < 0 or split.ratio > 1)
                return error.InvalidState;
            try validateNode(split.children[0], depth + 1, remaining, leaves);
            try validateNode(split.children[1], depth + 1, remaining, leaves);
        },
    }
}

pub fn encode(alloc: Allocator, state: State) ![]u8 {
    try validate(state);
    return try std.json.Stringify.valueAlloc(alloc, state, .{ .whitespace = .indent_2 });
}

pub fn decode(alloc: Allocator, bytes: []const u8) !std.json.Parsed(State) {
    if (bytes.len == 0 or bytes.len > max_state_bytes) return error.InvalidState;
    const parsed = try std.json.parseFromSlice(State, alloc, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

pub fn load(alloc: Allocator, path: []const u8) !?std.json.Parsed(State) {
    const file = std.Io.Dir.openFileAbsolute(global.io(), path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(global.io());

    const stat = try file.stat(global.io());
    if (stat.size == 0 or stat.size > max_state_bytes) return error.InvalidState;
    const bytes = try alloc.alloc(u8, @intCast(stat.size));
    defer alloc.free(bytes);
    if (try file.readPositionalAll(global.io(), bytes, 0) != bytes.len)
        return error.TruncatedState;
    return try decode(alloc, bytes);
}

pub fn save(alloc: Allocator, path: []const u8, state: State) !void {
    const contents = try encode(alloc, state);
    defer alloc.free(contents);

    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidStatePath;
    const basename = std.fs.path.basename(path);
    try std.Io.Dir.cwd().createDirPath(global.io(), dir_path);
    var dir = try std.Io.Dir.cwd().openDir(global.io(), dir_path, .{});
    defer dir.close(global.io());

    var atomic = try dir.createFileAtomic(global.io(), basename, .{
        .permissions = .default_file,
        .replace = true,
    });
    defer atomic.deinit(global.io());
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(global.io(), &buffer);
    try writer.interface.writeAll(contents);
    try writer.flush();
    try atomic.replace(global.io());
}

test "session state round trips nested splits and Unicode paths" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const children = [_]Node{
        .{ .leaf = .{ .working_directory = "C:\\Users\\レモン" } },
        .{ .split = .{
            .direction = .vertical,
            .ratio = 0.4,
            .children = &.{
                .{ .leaf = .{} },
                .{ .leaf = .{ .working_directory = "D:\\work" } },
            },
        } },
    };
    const state: State = .{
        .active_window = 0,
        .windows = &.{.{
            .x = -1200,
            .y = 80,
            .width = 1200,
            .height = 800,
            .active_tab = 0,
            .tabs = &.{.{
                .title_override = "日本語",
                .focused_pane = 2,
                .root = .{ .split = .{
                    .direction = .horizontal,
                    .ratio = 0.6,
                    .children = &children,
                } },
            }},
        }},
    };
    const encoded = try encode(alloc, state);
    defer alloc.free(encoded);
    var decoded = try decode(alloc, encoded);
    defer decoded.deinit();

    try testing.expectEqualStrings("日本語", decoded.value.windows[0].tabs[0].title_override.?);
    try testing.expectEqualStrings(
        "C:\\Users\\レモン",
        decoded.value.windows[0].tabs[0].root.split.children[0].leaf.working_directory.?,
    );
    try testing.expectEqual(@as(usize, 2), decoded.value.windows[0].tabs[0].focused_pane);
}

test "session state rejects invalid schema, ratios, and pane indices" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const invalid = [_][]const u8{
        "{\"schema\":2,\"windows\":[{}],\"active_window\":0}",
        "{\"schema\":1,\"active_window\":0,\"windows\":[{\"x\":0,\"y\":0,\"width\":800,\"height\":600,\"maximized\":false,\"active_tab\":0,\"tabs\":[{\"title_override\":null,\"focused_pane\":0,\"root\":{\"split\":{\"direction\":\"horizontal\",\"ratio\":1.5,\"children\":[{\"leaf\":{}},{\"leaf\":{}}]}}}]}]}",
    };
    for (invalid) |bytes| {
        const parsed = decode(alloc, bytes);
        if (parsed) |value| {
            var state = value;
            state.deinit();
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "session state save replaces a complete file and load restores it" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var placeholder = try tmp.dir.createFile(testing.io, "session.json", .{});
    placeholder.close(testing.io);
    const path = try tmp.dir.realPathFileAlloc(testing.io, "session.json", alloc);
    defer alloc.free(path);

    const state: State = .{
        .windows = &.{.{
            .x = -800,
            .y = 40,
            .width = 800,
            .height = 600,
            .tabs = &.{.{ .root = .{ .leaf = .{ .working_directory = "C:\\work" } } }},
        }},
    };
    try save(alloc, path, state);
    var loaded = (try load(alloc, path)) orelse return error.TestExpectedFile;
    defer loaded.deinit();
    try testing.expectEqualStrings(
        "C:\\work",
        loaded.value.windows[0].tabs[0].root.leaf.working_directory.?,
    );
}
