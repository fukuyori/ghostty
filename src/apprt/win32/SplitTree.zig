//! Platform-neutral layout state for Win32 terminal splits.
//!
//! Native window ownership deliberately lives outside this type. This keeps
//! split calculations testable while the Win32 runtime transitions from one
//! top-level HWND per surface to a parent window with child surface HWNDs.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn SplitTree(comptime View: type) type {
    return struct {
        const Self = @This();

        pub const Direction = enum { horizontal, vertical };

        pub const Node = union(enum) {
            leaf: *View,
            split: Split,

            pub const Split = struct {
                direction: Direction,
                ratio: f32 = 0.5,
                children: [2]*Node,
            };
        };

        pub const Rect = struct {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        };

        pub const LeafRect = struct {
            view: *View,
            rect: Rect,
        };

        root: *Node,

        pub fn init(alloc: Allocator, view: *View) Allocator.Error!Self {
            const root = try alloc.create(Node);
            root.* = .{ .leaf = view };
            return .{ .root = root };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            destroyNode(alloc, self.root);
            self.* = undefined;
        }

        fn destroyNode(alloc: Allocator, node: *Node) void {
            switch (node.*) {
                .leaf => {},
                .split => |branch| {
                    destroyNode(alloc, branch.children[0]);
                    destroyNode(alloc, branch.children[1]);
                },
            }
            alloc.destroy(node);
        }

        const FindResult = struct {
            slot: **Node,
            parent_slot: ?**Node,
        };

        fn find(self: *Self, view: *View) ?FindResult {
            return findIn(&self.root, null, view);
        }

        fn findIn(slot: **Node, parent_slot: ?**Node, view: *View) ?FindResult {
            const node = slot.*;
            return switch (node.*) {
                .leaf => |candidate| if (candidate == view)
                    .{ .slot = slot, .parent_slot = parent_slot }
                else
                    null,
                .split => |*branch| findIn(&branch.children[0], slot, view) orelse
                    findIn(&branch.children[1], slot, view),
            };
        }

        /// Insert `new_view` beside `existing`. Right and down insert after the
        /// existing view; left and up insert before it.
        pub fn split(
            self: *Self,
            alloc: Allocator,
            existing: *View,
            new_view: *View,
            direction: Direction,
            after: bool,
        ) (Allocator.Error || error{ViewNotFound})!void {
            const result = self.find(existing) orelse return error.ViewNotFound;
            const old_node = result.slot.*;

            const new_leaf = try alloc.create(Node);
            errdefer alloc.destroy(new_leaf);
            new_leaf.* = .{ .leaf = new_view };

            const split_node = try alloc.create(Node);
            errdefer alloc.destroy(split_node);
            split_node.* = .{ .split = .{
                .direction = direction,
                .children = if (after)
                    .{ old_node, new_leaf }
                else
                    .{ new_leaf, old_node },
            } };

            result.slot.* = split_node;
        }

        /// Remove a view from a tree that contains at least two leaves. The
        /// sibling branch is promoted and one of its leaves is returned as a
        /// deterministic focus candidate.
        pub fn remove(
            self: *Self,
            alloc: Allocator,
            view: *View,
        ) error{ ViewNotFound, LastView }!*View {
            const result = self.find(view) orelse return error.ViewNotFound;
            const parent_slot = result.parent_slot orelse return error.LastView;
            const parent_node = parent_slot.*;
            const branch = &parent_node.split;
            const leaf_node = result.slot.*;
            const sibling = if (branch.children[0] == leaf_node)
                branch.children[1]
            else
                branch.children[0];

            parent_slot.* = sibling;
            alloc.destroy(leaf_node);
            alloc.destroy(parent_node);
            return firstLeaf(sibling);
        }

        fn firstLeaf(node: *Node) *View {
            return switch (node.*) {
                .leaf => |view| view,
                .split => |branch| firstLeaf(branch.children[0]),
            };
        }

        /// Collect leaf rectangles in visual order. The caller owns native
        /// sizing and may choose a DPI-scaled divider gap.
        pub fn layout(
            self: *const Self,
            bounds: Rect,
            divider_gap: i32,
            output: []LeafRect,
        ) usize {
            var count: usize = 0;
            layoutNode(
                self.root,
                normalizeRect(bounds),
                @max(0, divider_gap),
                output,
                &count,
            );
            return count;
        }

        fn layoutNode(
            node: *const Node,
            bounds: Rect,
            divider_gap: i32,
            output: []LeafRect,
            count: *usize,
        ) void {
            switch (node.*) {
                .leaf => |view| {
                    if (count.* < output.len) {
                        output[count.*] = .{ .view = view, .rect = bounds };
                        count.* += 1;
                    }
                },
                .split => |branch| {
                    const ratio = std.math.clamp(branch.ratio, 0.0, 1.0);
                    switch (branch.direction) {
                        .horizontal => {
                            const gap = @min(divider_gap, bounds.width);
                            const available = bounds.width - gap;
                            const first = scaledLength(available, ratio);
                            layoutNode(
                                branch.children[0],
                                .{
                                    .x = bounds.x,
                                    .y = bounds.y,
                                    .width = first,
                                    .height = bounds.height,
                                },
                                divider_gap,
                                output,
                                count,
                            );
                            layoutNode(
                                branch.children[1],
                                .{
                                    .x = bounds.x + first + gap,
                                    .y = bounds.y,
                                    .width = available - first,
                                    .height = bounds.height,
                                },
                                divider_gap,
                                output,
                                count,
                            );
                        },
                        .vertical => {
                            const gap = @min(divider_gap, bounds.height);
                            const available = bounds.height - gap;
                            const first = scaledLength(available, ratio);
                            layoutNode(
                                branch.children[0],
                                .{
                                    .x = bounds.x,
                                    .y = bounds.y,
                                    .width = bounds.width,
                                    .height = first,
                                },
                                divider_gap,
                                output,
                                count,
                            );
                            layoutNode(
                                branch.children[1],
                                .{
                                    .x = bounds.x,
                                    .y = bounds.y + first + gap,
                                    .width = bounds.width,
                                    .height = available - first,
                                },
                                divider_gap,
                                output,
                                count,
                            );
                        },
                    }
                },
            }
        }

        fn normalizeRect(rect: Rect) Rect {
            return .{
                .x = rect.x,
                .y = rect.y,
                .width = @max(0, rect.width),
                .height = @max(0, rect.height),
            };
        }

        fn scaledLength(value: i32, ratio: f32) i32 {
            if (value <= 0) return 0;
            return @intFromFloat(@as(f32, @floatFromInt(value)) * ratio);
        }
    };
}

test "Win32 split layout divides horizontal and vertical leaves" {
    const testing = std.testing;
    const View = struct { id: u8 };
    const Tree = SplitTree(View);

    var first: View = .{ .id = 1 };
    var second: View = .{ .id = 2 };
    var third: View = .{ .id = 3 };

    var tree = try Tree.init(testing.allocator, &first);
    defer tree.deinit(testing.allocator);
    try tree.split(testing.allocator, &first, &second, .horizontal, true);
    try tree.split(testing.allocator, &second, &third, .vertical, true);

    var output: [3]Tree.LeafRect = undefined;
    const count = tree.layout(
        .{ .x = 0, .y = 0, .width = 100, .height = 40 },
        2,
        &output,
    );

    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(&first, output[0].view);
    try testing.expectEqual(Tree.Rect{ .x = 0, .y = 0, .width = 49, .height = 40 }, output[0].rect);
    try testing.expectEqual(&second, output[1].view);
    try testing.expectEqual(Tree.Rect{ .x = 51, .y = 0, .width = 49, .height = 19 }, output[1].rect);
    try testing.expectEqual(&third, output[2].view);
    try testing.expectEqual(Tree.Rect{ .x = 51, .y = 21, .width = 49, .height = 19 }, output[2].rect);
}

test "Win32 split layout preserves before ordering and clamps bounds" {
    const testing = std.testing;
    const View = struct { id: u8 };
    const Tree = SplitTree(View);

    var existing: View = .{ .id = 1 };
    var before: View = .{ .id = 2 };
    var tree = try Tree.init(testing.allocator, &existing);
    defer tree.deinit(testing.allocator);
    try tree.split(testing.allocator, &existing, &before, .horizontal, false);

    var output: [2]Tree.LeafRect = undefined;
    const count = tree.layout(
        .{ .x = 7, .y = 9, .width = -10, .height = 20 },
        3,
        &output,
    );

    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(&before, output[0].view);
    try testing.expectEqual(Tree.Rect{ .x = 7, .y = 9, .width = 0, .height = 20 }, output[0].rect);
    try testing.expectEqual(&existing, output[1].view);
    try testing.expectEqual(Tree.Rect{ .x = 7, .y = 9, .width = 0, .height = 20 }, output[1].rect);
}

test "Win32 split rejects an unknown existing view" {
    const testing = std.testing;
    const View = struct { id: u8 };
    const Tree = SplitTree(View);

    var existing: View = .{ .id = 1 };
    var missing: View = .{ .id = 2 };
    var new_view: View = .{ .id = 3 };
    var tree = try Tree.init(testing.allocator, &existing);
    defer tree.deinit(testing.allocator);

    try testing.expectError(
        error.ViewNotFound,
        tree.split(testing.allocator, &missing, &new_view, .vertical, true),
    );
}

test "Win32 split removal promotes the sibling branch" {
    const testing = std.testing;
    const View = struct { id: u8 };
    const Tree = SplitTree(View);

    var first: View = .{ .id = 1 };
    var second: View = .{ .id = 2 };
    var third: View = .{ .id = 3 };

    var tree = try Tree.init(testing.allocator, &first);
    defer tree.deinit(testing.allocator);
    try tree.split(testing.allocator, &first, &second, .horizontal, true);
    try tree.split(testing.allocator, &second, &third, .vertical, true);

    try testing.expectEqual(&second, try tree.remove(testing.allocator, &third));

    var output: [2]Tree.LeafRect = undefined;
    const count = tree.layout(
        .{ .x = 0, .y = 0, .width = 100, .height = 40 },
        2,
        &output,
    );
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(&first, output[0].view);
    try testing.expectEqual(&second, output[1].view);

    try testing.expectEqual(&first, try tree.remove(testing.allocator, &second));
    try testing.expectError(error.LastView, tree.remove(testing.allocator, &first));
    try testing.expectError(error.ViewNotFound, tree.remove(testing.allocator, &third));
}
