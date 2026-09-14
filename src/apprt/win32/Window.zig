//! Ownership and layout state for one top-level Win32 terminal window.
//!
//! Rendering and input remain on child HWNDs owned by `Surface`. Keeping the
//! top-level HWND, surface collection, and split tree here prevents a single
//! split from being mistaken for a complete application window.

const Window = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const SplitTree = @import("SplitTree.zig").SplitTree;
const Surface = @import("Surface.zig");

const Tree = SplitTree(Surface);

pub const Rect = Tree.Rect;
pub const LeafRect = Tree.LeafRect;
pub const FocusDirection = Tree.FocusDirection;
pub const ResizeDirection = Tree.ResizeDirection;

hwnd: win32.HWND,
surfaces: std.ArrayListUnmanaged(*Surface) = .empty,
tree: Tree,
focused_surface: *Surface,

/// The host-backdrop opt-in belongs to the top-level HWND even though each
/// child surface owns its own bottom composition target.
host_backdrop_active: bool = false,

/// Fixed DWM Acrylic is used for the complete top-level window only when the
/// adjustable Host Backdrop composition path is unavailable.
dwm_backdrop_active: bool = false,

pub fn init(
    alloc: std.mem.Allocator,
    hwnd: win32.HWND,
    surface: *Surface,
) !Window {
    var surfaces: std.ArrayListUnmanaged(*Surface) = .empty;
    errdefer surfaces.deinit(alloc);
    try surfaces.append(alloc, surface);

    return .{
        .hwnd = hwnd,
        .surfaces = surfaces,
        .tree = try Tree.init(alloc, surface),
        .focused_surface = surface,
    };
}

/// Release ownership metadata. Native surfaces and HWNDs are destroyed by
/// App so renderer teardown happens before the corresponding handles vanish.
pub fn deinit(self: *Window, alloc: std.mem.Allocator) void {
    self.tree.deinit(alloc);
    self.surfaces.deinit(alloc);
    self.* = undefined;
}

pub fn contains(self: *const Window, surface: *const Surface) bool {
    for (self.surfaces.items) |candidate| {
        if (candidate == surface) return true;
    }
    return false;
}

pub fn addSplit(
    self: *Window,
    alloc: std.mem.Allocator,
    existing: *Surface,
    new_surface: *Surface,
    direction: Tree.Direction,
    after: bool,
) !void {
    try self.surfaces.append(alloc, new_surface);
    errdefer _ = self.surfaces.pop();
    try self.tree.split(alloc, existing, new_surface, direction, after);
    self.focused_surface = new_surface;
}

/// Remove one surface and return the sibling leaf that should receive focus.
/// The last surface is deliberately retained because removing it also closes
/// the owning native window and is handled by App.
pub fn removeSurface(
    self: *Window,
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
    self: *const Window,
    bounds: Rect,
    divider_gap: i32,
    output: []LeafRect,
) usize {
    return self.tree.layout(bounds, divider_gap, output);
}

pub fn focusCandidate(
    self: *const Window,
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
    self: *Window,
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

pub fn equalizeSplits(self: *Window) bool {
    return self.tree.equalize();
}

pub fn toggleSplitZoom(self: *Window, surface: *Surface) bool {
    return self.tree.toggleZoom(surface);
}

pub fn updateZoomForNavigation(
    self: *Window,
    surface: *Surface,
    preserve: bool,
) void {
    self.tree.updateZoomForNavigation(surface, preserve);
}

test "Win32 window owns and removes split surfaces" {
    const testing = std.testing;
    const hwnd: win32.HWND = @ptrFromInt(1);
    var first: Surface = .{ .hwnd = hwnd, .window_hwnd = hwnd };
    var second: Surface = .{ .hwnd = hwnd, .window_hwnd = hwnd };

    var window = try Window.init(testing.allocator, hwnd, &first);
    defer window.deinit(testing.allocator);

    try testing.expect(window.contains(&first));
    try testing.expectError(
        error.LastSurface,
        window.removeSurface(testing.allocator, &first),
    );

    try window.addSplit(
        testing.allocator,
        &first,
        &second,
        .horizontal,
        true,
    );
    try testing.expectEqual(@as(usize, 2), window.surfaces.items.len);
    try testing.expectEqual(&second, window.focused_surface);

    try testing.expectEqual(
        &first,
        try window.removeSurface(testing.allocator, &second),
    );
    try testing.expectEqual(@as(usize, 1), window.surfaces.items.len);
    try testing.expectEqual(&first, window.focused_surface);
}
