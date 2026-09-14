//! One Win32 tab containing a split tree of terminal surfaces.
//!
//! Native child HWND ownership remains in App. This type owns only the tab's
//! surface membership, split layout, focus, and zoom state.

const Tab = @This();

const std = @import("std");
const SplitTree = @import("SplitTree.zig").SplitTree;
const Surface = @import("Surface.zig");

const Tree = SplitTree(Surface);

pub const Rect = Tree.Rect;
pub const LeafRect = Tree.LeafRect;
pub const FocusDirection = Tree.FocusDirection;
pub const ResizeDirection = Tree.ResizeDirection;
pub const SplitDirection = Tree.Direction;
pub const Divider = Tree.Divider;

surfaces: std.ArrayListUnmanaged(*Surface) = .empty,
tree: Tree,
focused_surface: *Surface,

pub fn init(alloc: std.mem.Allocator, surface: *Surface) !Tab {
    var surfaces: std.ArrayListUnmanaged(*Surface) = .empty;
    errdefer surfaces.deinit(alloc);
    try surfaces.append(alloc, surface);

    return .{
        .surfaces = surfaces,
        .tree = try Tree.init(alloc, surface),
        .focused_surface = surface,
    };
}

pub fn deinit(self: *Tab, alloc: std.mem.Allocator) void {
    self.tree.deinit(alloc);
    self.surfaces.deinit(alloc);
    self.* = undefined;
}

pub fn contains(self: *const Tab, surface: *const Surface) bool {
    for (self.surfaces.items) |candidate| {
        if (candidate == surface) return true;
    }
    return false;
}

pub fn addSplit(
    self: *Tab,
    alloc: std.mem.Allocator,
    existing: *Surface,
    new_surface: *Surface,
    direction: SplitDirection,
    after: bool,
) !void {
    try self.surfaces.append(alloc, new_surface);
    errdefer _ = self.surfaces.pop();
    try self.tree.split(alloc, existing, new_surface, direction, after);
    self.focused_surface = new_surface;
}

pub fn removeSurface(
    self: *Tab,
    alloc: std.mem.Allocator,
    surface: *Surface,
) error{ SurfaceNotFound, LastSurface }!*Surface {
    if (self.surfaces.items.len == 1) {
        if (self.surfaces.items[0] == surface) return error.LastSurface;
        return error.SurfaceNotFound;
    }

    var index: ?usize = null;
    for (self.surfaces.items, 0..) |candidate, i| {
        if (candidate == surface) {
            index = i;
            break;
        }
    }
    const remove_index = index orelse return error.SurfaceNotFound;
    const focus = self.tree.remove(alloc, surface) catch |err| switch (err) {
        error.ViewNotFound => return error.SurfaceNotFound,
        error.LastView => return error.LastSurface,
    };
    _ = self.surfaces.orderedRemove(remove_index);
    if (self.focused_surface == surface) self.focused_surface = focus;
    return focus;
}

pub fn layout(
    self: *const Tab,
    bounds: Rect,
    divider_gap: i32,
    output: []LeafRect,
) usize {
    return self.tree.layout(bounds, divider_gap, output);
}

pub fn focusCandidate(
    self: *const Tab,
    current: *Surface,
    direction: FocusDirection,
    bounds: Rect,
    divider_gap: i32,
    output: []LeafRect,
) ?*Surface {
    return self.tree.focusCandidate(
        current,
        direction,
        bounds,
        divider_gap,
        output,
    );
}

pub fn resizeSplit(
    self: *Tab,
    surface: *Surface,
    direction: ResizeDirection,
    delta: i32,
    bounds: Rect,
    divider_gap: i32,
) bool {
    return self.tree.resize(
        surface,
        direction,
        delta,
        bounds,
        divider_gap,
    );
}

pub fn dividerAt(
    self: *Tab,
    bounds: Rect,
    divider_gap: i32,
    x: i32,
    y: i32,
    hit_slop: i32,
) ?Divider {
    return self.tree.dividerAt(bounds, divider_gap, x, y, hit_slop);
}

pub fn resizeDivider(
    self: *Tab,
    divider: Divider,
    delta: i32,
    bounds: Rect,
    divider_gap: i32,
    minimum_leaf_extent: i32,
) bool {
    return self.tree.resizeDivider(
        divider,
        delta,
        bounds,
        divider_gap,
        minimum_leaf_extent,
    );
}

pub fn equalizeSplits(self: *Tab) bool {
    return self.tree.equalize();
}

pub fn toggleSplitZoom(self: *Tab, surface: *Surface) bool {
    return self.tree.toggleZoom(surface);
}

pub fn updateZoomForNavigation(
    self: *Tab,
    surface: *Surface,
    preserve: bool,
) void {
    self.tree.updateZoomForNavigation(surface, preserve);
}

test "Win32 tab owns and removes split surfaces" {
    const testing = std.testing;
    const win32 = @import("win32").everything;
    const hwnd: win32.HWND = @ptrFromInt(1);
    var first: Surface = .{ .hwnd = hwnd, .window_hwnd = hwnd };
    var second: Surface = .{ .hwnd = hwnd, .window_hwnd = hwnd };

    var tab = try Tab.init(testing.allocator, &first);
    defer tab.deinit(testing.allocator);

    try testing.expect(tab.contains(&first));
    try testing.expectError(
        error.LastSurface,
        tab.removeSurface(testing.allocator, &first),
    );

    try tab.addSplit(
        testing.allocator,
        &first,
        &second,
        .horizontal,
        true,
    );
    try testing.expectEqual(@as(usize, 2), tab.surfaces.items.len);
    try testing.expectEqual(&second, tab.focused_surface);

    try testing.expectEqual(
        &first,
        try tab.removeSurface(testing.allocator, &second),
    );
    try testing.expectEqual(@as(usize, 1), tab.surfaces.items.len);
    try testing.expectEqual(&first, tab.focused_surface);
}
