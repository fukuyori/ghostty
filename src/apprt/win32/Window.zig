//! Ownership state for one top-level Win32 terminal window.
//!
//! A window owns one or more tabs. Each tab owns its terminal surfaces and
//! split tree, while App retains native HWND and renderer lifecycle control.

const Window = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const TabBar = @import("TabBar.zig");

pub const Rect = Tab.Rect;
pub const LeafRect = Tab.LeafRect;
pub const FocusDirection = Tab.FocusDirection;
pub const ResizeDirection = Tab.ResizeDirection;
pub const Divider = Tab.Divider;

pub const SplitDrag = struct {
    divider: Divider,
    last_x: i32,
    last_y: i32,
    capture_hwnd: win32.HWND,
};

pub const SelectTab = union(enum) {
    previous,
    next,
    last,
    /// One-based tab number, matching the `goto_tab` action.
    n: usize,
};

hwnd: win32.HWND,
tab_bar_hwnd: ?win32.HWND = null,
tab_bar_accessibility: ?*anyopaque = null,
tab_bar_hover: TabBar.Hit = .none,
tab_bar_tracking_mouse_leave: bool = false,
tab_bar_pressed: TabBar.Hit = .none,
tab_bar_drag: ?TabBar.Drag = null,
tab_bar_first_visible: usize = 0,
split_divider_hwnds: std.ArrayListUnmanaged(win32.HWND) = .empty,
split_dividers: std.ArrayListUnmanaged(Divider) = .empty,
split_divider_hover: ?Divider = null,
split_divider_drag: ?SplitDrag = null,
split_divider_tracking_mouse_leave: bool = false,
tabs: std.ArrayListUnmanaged(*Tab) = .empty,
active_tab: *Tab,

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
    const tab = try alloc.create(Tab);
    errdefer alloc.destroy(tab);
    tab.* = try Tab.init(alloc, surface);
    errdefer tab.deinit(alloc);

    var tabs: std.ArrayListUnmanaged(*Tab) = .empty;
    errdefer tabs.deinit(alloc);
    try tabs.append(alloc, tab);

    return .{
        .hwnd = hwnd,
        .tabs = tabs,
        .active_tab = tab,
    };
}

/// Release ownership metadata. Native surfaces and HWNDs are destroyed by
/// App so renderer teardown happens before the corresponding handles vanish.
pub fn deinit(self: *Window, alloc: std.mem.Allocator) void {
    std.debug.assert(self.tab_bar_accessibility == null);
    for (self.tabs.items) |tab| {
        tab.deinit(alloc);
        alloc.destroy(tab);
    }
    self.split_divider_hwnds.deinit(alloc);
    self.split_dividers.deinit(alloc);
    self.tabs.deinit(alloc);
    self.* = undefined;
}

pub fn contains(self: *const Window, surface: *const Surface) bool {
    return self.tabForSurface(surface) != null;
}

pub fn tabForSurface(self: *const Window, surface: *const Surface) ?*Tab {
    for (self.tabs.items) |tab| {
        if (tab.contains(surface)) return tab;
    }
    return null;
}

pub const SurfaceIterator = struct {
    window: *const Window,
    tab_index: usize = 0,
    surface_index: usize = 0,

    pub fn next(self: *SurfaceIterator) ?*Surface {
        while (self.tab_index < self.window.tabs.items.len) {
            const surfaces = self.window.tabs.items[self.tab_index].surfaces.items;
            if (self.surface_index < surfaces.len) {
                const surface = surfaces[self.surface_index];
                self.surface_index += 1;
                return surface;
            }

            self.tab_index += 1;
            self.surface_index = 0;
        }
        return null;
    }
};

pub fn surfaceIterator(self: *const Window) SurfaceIterator {
    return .{ .window = self };
}

pub fn activeSurfaceCount(self: *const Window) usize {
    return self.active_tab.surfaces.items.len;
}

pub fn surfaceCountFor(self: *const Window, surface: *const Surface) ?usize {
    const tab = self.tabForSurface(surface) orelse return null;
    return tab.surfaces.items.len;
}

pub fn surfacesAt(self: *const Window, index: usize) ?[]*Surface {
    if (index >= self.tabs.items.len) return null;
    return self.tabs.items[index].surfaces.items;
}

pub fn focusedSurfaceAt(self: *const Window, index: usize) ?*Surface {
    if (index >= self.tabs.items.len) return null;
    return self.tabs.items[index].focused_surface;
}

pub fn tabTitleAt(self: *const Window, index: usize) ?[:0]const u8 {
    if (index >= self.tabs.items.len) return null;
    return self.tabs.items[index].title();
}

pub fn titleForSurface(self: *const Window, surface: *const Surface) ?[:0]const u8 {
    const tab = self.tabForSurface(surface) orelse return null;
    return tab.title();
}

pub fn setTabTitle(
    self: *Window,
    alloc: std.mem.Allocator,
    surface: *const Surface,
    value: []const u8,
) !bool {
    const tab = self.tabForSurface(surface) orelse return false;
    try tab.setTitleOverride(alloc, value);
    return true;
}

pub fn stateSurface(self: *const Window) *Surface {
    return self.tabs.items[0].surfaces.items[0];
}

pub fn focusedSurface(self: *const Window) *Surface {
    return self.active_tab.focused_surface;
}

pub fn setFocusedSurface(self: *Window, surface: *Surface) bool {
    const tab = self.tabForSurface(surface) orelse return false;
    self.active_tab = tab;
    tab.focused_surface = surface;
    return true;
}

pub fn totalSurfaceCount(self: *const Window) usize {
    var count: usize = 0;
    for (self.tabs.items) |tab| count += tab.surfaces.items.len;
    return count;
}

pub fn tabCount(self: *const Window) usize {
    return self.tabs.items.len;
}

pub fn tabIndexForSurface(self: *const Window, surface: *const Surface) ?usize {
    for (self.tabs.items, 0..) |tab, index| {
        if (tab.contains(surface)) return index;
    }
    return null;
}

pub fn activeTabIndex(self: *const Window) usize {
    for (self.tabs.items, 0..) |tab, index| {
        if (tab == self.active_tab) return index;
    }
    unreachable;
}

pub fn addTab(
    self: *Window,
    alloc: std.mem.Allocator,
    surface: *Surface,
    after_current: bool,
) !void {
    const tab = try alloc.create(Tab);
    errdefer alloc.destroy(tab);
    tab.* = try Tab.init(alloc, surface);
    errdefer tab.deinit(alloc);

    const index = if (after_current)
        self.activeTabIndex() + 1
    else
        self.tabs.items.len;
    try self.tabs.insert(alloc, index, tab);
    self.active_tab = tab;
}

pub fn selectTab(self: *Window, target: SelectTab) bool {
    if (self.tabs.items.len <= 1) return false;

    const current = self.activeTabIndex();
    const index = switch (target) {
        .previous => if (current > 0) current - 1 else self.tabs.items.len - 1,
        .next => if (current + 1 < self.tabs.items.len) current + 1 else 0,
        .last => self.tabs.items.len - 1,
        .n => |number| if (number == 0)
            return false
        else
            @min(number - 1, self.tabs.items.len - 1),
    };
    if (index == current) return false;

    self.active_tab = self.tabs.items[index];
    return true;
}

pub fn moveTab(self: *Window, surface: *const Surface, amount: isize) bool {
    if (self.tabs.items.len <= 1 or amount == 0) return false;

    const current = self.tabIndexForSurface(surface) orelse return false;
    const count: isize = @intCast(self.tabs.items.len);
    const destination: usize = @intCast(@mod(@as(isize, @intCast(current)) + amount, count));
    return self.moveTabTo(current, destination);
}

pub fn moveTabTo(self: *Window, current: usize, destination: usize) bool {
    if (current >= self.tabs.items.len or destination >= self.tabs.items.len or
        destination == current)
    {
        return false;
    }

    if (destination > current) {
        for (current..destination) |index| {
            std.mem.swap(*Tab, &self.tabs.items[index], &self.tabs.items[index + 1]);
        }
    } else {
        var index = current;
        while (index > destination) : (index -= 1) {
            std.mem.swap(*Tab, &self.tabs.items[index], &self.tabs.items[index - 1]);
        }
    }
    return true;
}

pub fn removeTabAt(
    self: *Window,
    alloc: std.mem.Allocator,
    index: usize,
) error{ LastTab, TabNotFound }!*Surface {
    if (index >= self.tabs.items.len) return error.TabNotFound;
    if (self.tabs.items.len == 1) return error.LastTab;

    const removed = self.tabs.items[index];
    const was_active = removed == self.active_tab;
    _ = self.tabs.orderedRemove(index);
    if (was_active) self.active_tab = self.tabs.items[@min(index, self.tabs.items.len - 1)];

    removed.deinit(alloc);
    alloc.destroy(removed);
    return self.active_tab.focused_surface;
}

pub fn addSplit(
    self: *Window,
    alloc: std.mem.Allocator,
    existing: *Surface,
    new_surface: *Surface,
    direction: Tab.SplitDirection,
    after: bool,
) !void {
    const tab = self.tabForSurface(existing) orelse return error.SurfaceNotFound;
    try tab.addSplit(alloc, existing, new_surface, direction, after);
    self.active_tab = tab;
}

pub fn removeSurface(
    self: *Window,
    alloc: std.mem.Allocator,
    surface: *Surface,
) error{ SurfaceNotFound, LastSurface }!*Surface {
    const tab = self.tabForSurface(surface) orelse return error.SurfaceNotFound;
    return tab.removeSurface(alloc, surface);
}

pub fn layout(
    self: *const Window,
    bounds: Rect,
    divider_gap: i32,
    output: []LeafRect,
) usize {
    return self.active_tab.layout(bounds, divider_gap, output);
}

pub fn focusCandidate(
    self: *const Window,
    current: *Surface,
    direction: FocusDirection,
    bounds: Rect,
    divider_gap: i32,
    output: []LeafRect,
) ?*Surface {
    const tab = self.tabForSurface(current) orelse return null;
    return tab.focusCandidate(
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
    const tab = self.tabForSurface(surface) orelse return false;
    return tab.resizeSplit(
        surface,
        direction,
        delta,
        bounds,
        divider_gap,
    );
}

pub fn dividerAt(
    self: *Window,
    bounds: Rect,
    divider_gap: i32,
    x: i32,
    y: i32,
    hit_slop: i32,
) ?Divider {
    return self.active_tab.dividerAt(
        bounds,
        divider_gap,
        x,
        y,
        hit_slop,
    );
}

pub fn dividers(
    self: *Window,
    bounds: Rect,
    divider_gap: i32,
    output: []Divider,
) usize {
    return self.active_tab.dividers(bounds, divider_gap, output);
}

pub fn resizeDivider(
    self: *Window,
    divider: Divider,
    delta: i32,
    bounds: Rect,
    divider_gap: i32,
    minimum_leaf_extent: i32,
) bool {
    return self.active_tab.resizeDivider(
        divider,
        delta,
        bounds,
        divider_gap,
        minimum_leaf_extent,
    );
}

pub fn equalizeSplits(self: *Window) bool {
    return self.active_tab.equalizeSplits();
}

pub fn toggleSplitZoom(self: *Window, surface: *Surface) bool {
    const tab = self.tabForSurface(surface) orelse return false;
    return tab.toggleSplitZoom(surface);
}

pub fn activeTabIsZoomed(self: *const Window) bool {
    return self.active_tab.isZoomed();
}

pub fn updateZoomForNavigation(
    self: *Window,
    surface: *Surface,
    preserve: bool,
) void {
    const tab = self.tabForSurface(surface) orelse return;
    tab.updateZoomForNavigation(surface, preserve);
}

test "Win32 window owns a tab and delegates split ownership" {
    const testing = std.testing;
    const hwnd: win32.HWND = @ptrFromInt(1);
    var first: Surface = .{ .hwnd = hwnd, .window_hwnd = hwnd };
    var second: Surface = .{ .hwnd = hwnd, .window_hwnd = hwnd };
    var third: Surface = .{ .hwnd = hwnd, .window_hwnd = hwnd };

    var window = try Window.init(testing.allocator, hwnd, &first);
    defer window.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), window.tabs.items.len);
    try testing.expect(window.contains(&first));
    try testing.expectEqual(&first, window.stateSurface());
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
    try testing.expectEqual(@as(usize, 2), window.activeSurfaceCount());
    try testing.expectEqual(&second, window.focusedSurface());
    try testing.expectEqual(@as(usize, 2), window.totalSurfaceCount());

    try testing.expectEqual(
        &first,
        try window.removeSurface(testing.allocator, &second),
    );
    try testing.expectEqual(@as(usize, 1), window.activeSurfaceCount());
    try testing.expectEqual(&first, window.focusedSurface());

    try window.addTab(testing.allocator, &second, true);
    try window.addTab(testing.allocator, &third, false);
    try testing.expectEqual(@as(usize, 3), window.tabCount());
    try testing.expectEqual(&third, window.focusedSurface());

    try testing.expect(window.selectTab(.next));
    try testing.expectEqual(&first, window.focusedSurface());
    try testing.expect(window.selectTab(.{ .n = 2 }));
    try testing.expectEqual(&second, window.focusedSurface());

    try testing.expect(window.moveTab(&second, -1));
    try testing.expectEqual(@as(usize, 0), window.tabIndexForSurface(&second).?);
    try testing.expect(window.moveTabTo(0, 2));
    try testing.expectEqual(@as(usize, 2), window.tabIndexForSurface(&second).?);
    try testing.expect(!window.moveTabTo(2, 2));
    try testing.expectEqual(
        &second,
        try window.removeTabAt(testing.allocator, 0),
    );
    try testing.expectEqual(@as(usize, 2), window.tabCount());

    var surfaces = window.surfaceIterator();
    var count: usize = 0;
    while (surfaces.next() != null) count += 1;
    try testing.expectEqual(@as(usize, 2), count);
}
