//! Win32 session save and restore orchestration.

const std = @import("std");
const win32 = @import("win32").everything;
const apprt = @import("../../apprt.zig");
const brand = @import("../../brand.zig");
const global = @import("../../global.zig");
const xdg = @import("../../os/xdg.zig");
const windows_path = @import("../../os/windows_path.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const WindowCommands = @import("WindowCommands.zig");
const WindowLayout = @import("WindowLayout.zig");
const WindowLifecycle = @import("WindowLifecycle.zig");
const State = @import("SessionState.zig");
const Tree = @import("SplitTree.zig").SplitTree(Surface);

const log = std.log.scoped(.win32_session);

pub fn statePath(alloc: std.mem.Allocator) ![]u8 {
    var environ = try global.environMap();
    defer environ.deinit();
    const state_dir = try xdg.state(global.io(), alloc, &environ, .{
        .subdir = brand.identifier,
    });
    defer alloc.free(state_dir);
    return try std.fs.path.join(alloc, &.{ state_dir, "windows", "session.json" });
}

pub fn restore(app: *App, path: []const u8) !bool {
    var parsed = (try State.load(app.alloc, path)) orelse return false;
    defer parsed.deinit();
    const session = parsed.value;

    for (session.windows) |saved_window| {
        const first_leaf = firstLeaf(saved_window.tabs[0].root);
        var first_options = try optionsForLeaf(app, first_leaf);
        defer deinitOptions(app.alloc, &first_options);
        try WindowLifecycle.createWindow(app, first_options);
        const window = app.windows.items[app.windows.items.len - 1];
        try restoreWindowTabs(app, window, saved_window);
        applyPlacement(window.hwnd, saved_window);
    }

    if (app.windows.items.len == 0) return false;
    const active_index = @min(session.active_window, app.windows.items.len - 1);
    const active_window = app.windows.items[active_index];
    _ = win32.SetForegroundWindow(active_window.hwnd);
    _ = win32.SetFocus(active_window.focusedSurface().hwnd);
    return true;
}

fn restoreWindowTabs(app: *App, window: *Window, saved: State.Window) !void {
    for (saved.tabs, 0..) |saved_tab, index| {
        if (index > 0) {
            const active = window.focusedSurface();
            var options = try optionsForLeaf(app, firstLeaf(saved_tab.root));
            defer deinitOptions(app.alloc, &options);
            if (!try WindowLifecycle.newTabWithOptions(
                app,
                .{ .surface = active.core_surface.? },
                options,
            )) return error.RestoreTabFailed;
        }

        const tab = window.active_tab;
        try restoreTabSplits(app, window, tab, saved_tab);
        const focus = tab.surfaces.items[saved_tab.focused_pane];
        tab.focused_surface = focus;
        if (saved_tab.title_override) |title| {
            try tab.setTitleOverride(app.alloc, title);
        }
    }

    window.active_tab = window.tabs.items[@min(saved.active_tab, window.tabs.items.len - 1)];
    WindowCommands.activateWindowTab(app, window);
}

fn restoreTabSplits(
    app: *App,
    window: *Window,
    tab: *Tab,
    saved: State.Tab,
) !void {
    const leaves = try collectLeaves(app.alloc, saved.root);
    defer app.alloc.free(leaves);
    std.debug.assert(leaves.len > 0);

    const anchor = tab.surfaces.items[0];
    for (leaves[1..]) |leaf| {
        var options = try optionsForLeaf(app, leaf);
        defer deinitOptions(app.alloc, &options);
        if (!try WindowLifecycle.newSplitWithOptions(
            app,
            .{ .surface = anchor.core_surface.? },
            .right,
            options,
        )) return error.RestoreSplitFailed;
    }

    var old_tree = tab.tree;
    var surface_index: usize = 0;
    const root = try buildTree(app.alloc, saved.root, tab.surfaces.items, &surface_index);
    old_tree.deinit(app.alloc);
    tab.tree = .{ .root = root, .zoomed = null };
    tab.focused_surface = tab.surfaces.items[saved.focused_pane];
    WindowLayout.layoutWindow(app, window);
}

fn optionsForLeaf(app: *App, leaf: State.Leaf) !WindowLifecycle.Options {
    const alloc = app.alloc;
    var result: WindowLifecycle.Options = .{};
    if (leaf.working_directory) |path| {
        if (directoryExists(path)) {
            result.working_directory = try alloc.dupeZ(u8, path);
        } else {
            log.warn("session working directory is unavailable; using configured default path={s}", .{path});
            if (app.config.@"working-directory") |configured_wd| {
                if (configured_wd.value()) |configured| {
                    if (directoryExists(configured)) result.working_directory = try alloc.dupeZ(u8, configured);
                }
            }
        }
    }
    errdefer deinitOptions(alloc, &result);
    if (leaf.title) |title| {
        result.title = try alloc.dupeZ(u8, title);
        result.dynamic_title = true;
    }
    return result;
}

fn deinitOptions(alloc: std.mem.Allocator, options: *WindowLifecycle.Options) void {
    if (options.working_directory) |path| alloc.free(path);
    if (options.title) |title| alloc.free(title);
}

fn directoryExists(path: []const u8) bool {
    // Paths come from a JSON file and may contain malformed Windows paths.
    // openDirAbsolute has debug assertions for paths that cannot be checked.
    if (!std.fs.path.isAbsolute(path) or !windows_path.isCheckable(path)) return false;
    var dir = std.Io.Dir.openDirAbsolute(global.io(), path, .{}) catch return false;
    dir.close(global.io());
    return true;
}

test "directoryExists rejects malformed or relative paths" {
    try std.testing.expect(!directoryExists("relative\\folder"));
    try std.testing.expect(!directoryExists("C:\\bad?path"));
    try std.testing.expect(!directoryExists("C:\\folder\\mailto:user@example.com"));
}

fn firstLeaf(node: State.Node) State.Leaf {
    return switch (node) {
        .leaf => |leaf| leaf,
        .split => |split| firstLeaf(split.children[0]),
    };
}

fn collectLeaves(alloc: std.mem.Allocator, root: State.Node) ![]State.Leaf {
    var list: std.ArrayListUnmanaged(State.Leaf) = .empty;
    errdefer list.deinit(alloc);
    try appendLeaves(alloc, &list, root);
    return try list.toOwnedSlice(alloc);
}

fn appendLeaves(
    alloc: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(State.Leaf),
    node: State.Node,
) !void {
    switch (node) {
        .leaf => |leaf| try list.append(alloc, leaf),
        .split => |split| {
            try appendLeaves(alloc, list, split.children[0]);
            try appendLeaves(alloc, list, split.children[1]);
        },
    }
}

fn buildTree(
    alloc: std.mem.Allocator,
    record: State.Node,
    surfaces: []*Surface,
    next: *usize,
) anyerror!*Tree.Node {
    const root = try buildTreeInner(alloc, record, surfaces, next);
    if (next.* != surfaces.len) {
        destroyTreeNode(alloc, root);
        return error.InvalidState;
    }
    return root;
}

fn buildTreeInner(
    alloc: std.mem.Allocator,
    record: State.Node,
    surfaces: []*Surface,
    next: *usize,
) !*Tree.Node {
    const node = try alloc.create(Tree.Node);
    errdefer alloc.destroy(node);
    switch (record) {
        .leaf => {
            if (next.* >= surfaces.len) return error.InvalidState;
            node.* = .{ .leaf = surfaces[next.*] };
            next.* += 1;
        },
        .split => |split| {
            const first = try buildTreeInner(alloc, split.children[0], surfaces, next);
            errdefer destroyTreeNode(alloc, first);
            const second = try buildTreeInner(alloc, split.children[1], surfaces, next);
            errdefer destroyTreeNode(alloc, second);
            node.* = .{ .split = .{
                .direction = switch (split.direction) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = split.ratio,
                .children = .{ first, second },
            } };
        },
    }
    return node;
}

fn destroyTreeNode(alloc: std.mem.Allocator, node: *Tree.Node) void {
    switch (node.*) {
        .leaf => {},
        .split => |split| {
            destroyTreeNode(alloc, split.children[0]);
            destroyTreeNode(alloc, split.children[1]);
        },
    }
    alloc.destroy(node);
}

fn applyPlacement(hwnd: win32.HWND, saved: State.Window) void {
    var rect: win32.RECT = .{
        .left = saved.x,
        .top = saved.y,
        .right = saved.x + saved.width,
        .bottom = saved.y + saved.height,
    };
    if (win32.MonitorFromRect(&rect, win32.MONITOR_DEFAULTTONEAREST)) |monitor| {
        var info: win32.MONITORINFO = .{
            .cbSize = @sizeOf(win32.MONITORINFO),
            .rcMonitor = std.mem.zeroes(win32.RECT),
            .rcWork = std.mem.zeroes(win32.RECT),
            .dwFlags = 0,
        };
        if (win32.GetMonitorInfoW(monitor, &info) != 0) clampRect(&rect, info.rcWork);
    }

    var placement: win32.WINDOWPLACEMENT = std.mem.zeroes(win32.WINDOWPLACEMENT);
    placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    placement.showCmd = if (saved.maximized) win32.SW_SHOWMAXIMIZED else win32.SW_SHOWNORMAL;
    placement.rcNormalPosition = rect;
    if (win32.SetWindowPlacement(hwnd, &placement) == 0) {
        log.warn("SetWindowPlacement(session restore) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    }
}

fn clampRect(rect: *win32.RECT, work: win32.RECT) void {
    const work_width = @max(work.right - work.left, 1);
    const work_height = @max(work.bottom - work.top, 1);
    const bounded_width = @min(@max(rect.right - rect.left, 160), work_width);
    const bounded_height = @min(@max(rect.bottom - rect.top, 120), work_height);
    rect.left = std.math.clamp(rect.left, work.left, work.right - bounded_width);
    rect.top = std.math.clamp(rect.top, work.top, work.bottom - bounded_height);
    rect.right = rect.left + bounded_width;
    rect.bottom = rect.top + bounded_height;
}

pub fn save(app: *App, path: []const u8) !void {
    if (app.windows.items.len == 0) {
        try clear(path);
        return;
    }
    if (app.windows.items.len > State.max_windows) return error.TooManyWindows;

    var arena: std.heap.ArenaAllocator = .init(app.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const windows = try alloc.alloc(State.Window, app.windows.items.len);
    var active_window: usize = 0;
    const foreground = win32.GetForegroundWindow();
    for (app.windows.items, 0..) |window, wi| {
        if (window.hwnd == foreground) active_window = wi;
        windows[wi] = try captureWindow(alloc, window);
    }
    try State.save(app.alloc, path, .{ .windows = windows, .active_window = active_window });
}

fn captureWindow(alloc: std.mem.Allocator, window: *Window) !State.Window {
    var placement: win32.WINDOWPLACEMENT = std.mem.zeroes(win32.WINDOWPLACEMENT);
    placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    if (win32.GetWindowPlacement(window.hwnd, &placement) == 0) return error.GetWindowPlacementFailed;
    const rect = placement.rcNormalPosition;
    const tabs = try alloc.alloc(State.Tab, window.tabs.items.len);
    for (window.tabs.items, 0..) |tab, ti| {
        var focused_pane: usize = 0;
        var pane_index: usize = 0;
        const root = try captureNode(alloc, tab.tree.root, tab.focused_surface, &focused_pane, &pane_index);
        tabs[ti] = .{
            .title_override = if (tab.title_override) |title| try alloc.dupe(u8, title) else null,
            .focused_pane = focused_pane,
            .root = root,
        };
    }
    return .{
        .x = rect.left,
        .y = rect.top,
        .width = @max(rect.right - rect.left, 160),
        .height = @max(rect.bottom - rect.top, 120),
        .maximized = win32.IsZoomed(window.hwnd) != 0,
        .active_tab = window.activeTabIndex(),
        .tabs = tabs,
    };
}

fn captureNode(
    alloc: std.mem.Allocator,
    node: anytype,
    focused: *Surface,
    focus_index: *usize,
    pane_index: *usize,
) !State.Node {
    return switch (node.*) {
        .leaf => |surface| blk: {
            if (surface == focused) focus_index.* = pane_index.*;
            pane_index.* += 1;
            const pwd = try surface.core().pwd(alloc);
            break :blk .{ .leaf = .{
                .working_directory = pwd,
                .title = if (surface.title) |title| try alloc.dupe(u8, title) else null,
            } };
        },
        .split => |split| .{ .split = .{
            .direction = switch (split.direction) {
                .horizontal => .horizontal,
                .vertical => .vertical,
            },
            .ratio = split.ratio,
            .children = try alloc.dupe(State.Node, &.{
                try captureNode(alloc, split.children[0], focused, focus_index, pane_index),
                try captureNode(alloc, split.children[1], focused, focus_index, pane_index),
            }),
        } },
    };
}

pub fn clear(path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(global.io(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
