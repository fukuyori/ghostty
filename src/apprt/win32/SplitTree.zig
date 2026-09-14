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

        pub const FocusDirection = enum {
            previous,
            next,
            up,
            down,
            left,
            right,
        };

        pub const ResizeDirection = enum {
            horizontal,
            vertical,
        };

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
        zoomed: ?*View = null,

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
            self.zoomed = null;
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

            if (self.zoomed == view) self.zoomed = null;

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
            const normalized = normalizeRect(bounds);
            if (self.zoomed) |view| {
                if (output.len == 0) return 0;
                output[0] = .{ .view = view, .rect = normalized };
                return 1;
            }

            var count: usize = 0;
            layoutNode(
                self.root,
                normalized,
                @max(0, divider_gap),
                output,
                &count,
            );
            return count;
        }

        /// Find the next view for keyboard focus navigation. Sequential
        /// movement follows visual leaf order and wraps. Directional movement
        /// uses top-left distance, matching the spatial navigation behavior of
        /// the macOS split tree.
        pub fn focusCandidate(
            self: *const Self,
            current: *View,
            direction: FocusDirection,
            bounds: Rect,
            divider_gap: i32,
            output: []LeafRect,
        ) ?*View {
            var count: usize = 0;
            layoutNode(
                self.root,
                normalizeRect(bounds),
                @max(0, divider_gap),
                output,
                &count,
            );
            if (count < 2) return null;

            var current_index: ?usize = null;
            for (output[0..count], 0..) |entry, i| {
                if (entry.view == current) {
                    current_index = i;
                    break;
                }
            }
            const index = current_index orelse return null;

            return switch (direction) {
                .next => output[(index + 1) % count].view,
                .previous => output[(index + count - 1) % count].view,
                .up, .down, .left, .right => directionalFocus(
                    output[0..count],
                    index,
                    direction,
                ),
            };
        }

        pub fn toggleZoom(self: *Self, view: *View) bool {
            switch (self.root.*) {
                .leaf => return false,
                .split => {},
            }
            if (self.find(view) == null) return false;
            self.zoomed = if (self.zoomed == null) view else null;
            return true;
        }

        pub fn updateZoomForNavigation(
            self: *Self,
            view: *View,
            preserve: bool,
        ) void {
            if (self.zoomed == null) return;
            self.zoomed = if (preserve) view else null;
        }

        pub fn isZoomed(self: *const Self) bool {
            return self.zoomed != null;
        }

        /// Move the nearest divider matching `direction` by a pixel delta.
        /// Positive deltas move right or down; negative deltas move left or
        /// up. The delta is converted relative to that split's own extent.
        pub fn resize(
            self: *Self,
            view: *View,
            direction: ResizeDirection,
            delta: i32,
            bounds: Rect,
            divider_gap: i32,
        ) bool {
            if (delta == 0) return false;
            const candidate = resizeCandidate(
                self.root,
                view,
                direction,
                normalizeRect(bounds),
                @max(0, divider_gap),
                null,
            ) orelse return false;
            if (candidate.extent <= 0) return false;

            const old_ratio = candidate.split.ratio;
            const ratio_delta = @as(f32, @floatFromInt(delta)) /
                @as(f32, @floatFromInt(candidate.extent));
            candidate.split.ratio = std.math.clamp(
                old_ratio + ratio_delta,
                0.0,
                1.0,
            );
            return true;
        }

        /// Size every leaf equally along runs that share the same split axis.
        pub fn equalize(self: *Self) bool {
            switch (self.root.*) {
                .leaf => return false,
                .split => {
                    _ = equalizeNode(self.root);
                    return true;
                },
            }
        }

        const ResizeCandidate = struct {
            split: *Node.Split,
            extent: i32,
        };

        fn resizeCandidate(
            node: *Node,
            view: *View,
            direction: ResizeDirection,
            bounds: Rect,
            divider_gap: i32,
            inherited: ?ResizeCandidate,
        ) ?ResizeCandidate {
            return switch (node.*) {
                .leaf => |candidate| if (candidate == view) inherited else null,
                .split => |*branch| blk: {
                    const child_bounds = splitBounds(branch.*, bounds, divider_gap);
                    const next = if (branch.direction == switch (direction) {
                        .horizontal => Direction.horizontal,
                        .vertical => Direction.vertical,
                    }) ResizeCandidate{
                        .split = branch,
                        .extent = switch (direction) {
                            .horizontal => child_bounds.available_width,
                            .vertical => child_bounds.available_height,
                        },
                    } else inherited;
                    break :blk resizeCandidate(
                        branch.children[0],
                        view,
                        direction,
                        child_bounds.first,
                        divider_gap,
                        next,
                    ) orelse resizeCandidate(
                        branch.children[1],
                        view,
                        direction,
                        child_bounds.second,
                        divider_gap,
                        next,
                    );
                },
            };
        }

        fn equalizeNode(node: *Node) bool {
            return switch (node.*) {
                .leaf => false,
                .split => |*branch| blk: {
                    const first_weight = layoutWeight(
                        branch.children[0],
                        branch.direction,
                    );
                    const second_weight = layoutWeight(
                        branch.children[1],
                        branch.direction,
                    );
                    const total: f32 = @floatFromInt(first_weight + second_weight);
                    const ratio = @as(f32, @floatFromInt(first_weight)) / total;
                    const changed = branch.ratio != ratio;
                    branch.ratio = ratio;
                    const first_changed = equalizeNode(branch.children[0]);
                    const second_changed = equalizeNode(branch.children[1]);
                    break :blk first_changed or second_changed or changed;
                },
            };
        }

        fn layoutWeight(node: *const Node, direction: Direction) usize {
            return switch (node.*) {
                .leaf => 1,
                .split => |branch| if (branch.direction == direction)
                    layoutWeight(branch.children[0], direction) +
                        layoutWeight(branch.children[1], direction)
                else
                    1,
            };
        }

        const FocusScore = struct {
            distance_squared: u128,

            fn lessThan(self: FocusScore, other: FocusScore) bool {
                return self.distance_squared < other.distance_squared;
            }
        };

        fn directionalFocus(
            entries: []const LeafRect,
            current_index: usize,
            direction: FocusDirection,
        ) ?*View {
            const current = entries[current_index].rect;
            var best: ?*View = null;
            var best_score: ?FocusScore = null;

            for (entries, 0..) |entry, i| {
                if (i == current_index) continue;
                const score = focusScore(current, entry.rect, direction) orelse continue;
                if (best_score == null or score.lessThan(best_score.?)) {
                    best = entry.view;
                    best_score = score;
                }
            }
            return best;
        }

        fn focusScore(
            current: Rect,
            candidate: Rect,
            direction: FocusDirection,
        ) ?FocusScore {
            const in_direction = switch (direction) {
                .left => rectEnd(candidate.x, candidate.width) <= @as(i64, current.x),
                .right => @as(i64, candidate.x) >= rectEnd(current.x, current.width),
                .up => rectEnd(candidate.y, candidate.height) <= @as(i64, current.y),
                .down => @as(i64, candidate.y) >= rectEnd(current.y, current.height),
                .previous, .next => return null,
            };
            if (!in_direction) return null;

            const dx = absDelta(current.x, candidate.x);
            const dy = absDelta(current.y, candidate.y);
            return .{ .distance_squared = dx * dx + dy * dy };
        }

        fn rectEnd(start: i32, length: i32) i64 {
            return @as(i64, start) + @as(i64, length);
        }

        fn absDelta(a: i32, b: i32) u128 {
            const a_i64: i64 = a;
            const b_i64: i64 = b;
            return @intCast(if (a_i64 >= b_i64) a_i64 - b_i64 else b_i64 - a_i64);
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
                    const child_bounds = splitBounds(branch, bounds, divider_gap);
                    layoutNode(
                        branch.children[0],
                        child_bounds.first,
                        divider_gap,
                        output,
                        count,
                    );
                    layoutNode(
                        branch.children[1],
                        child_bounds.second,
                        divider_gap,
                        output,
                        count,
                    );
                },
            }
        }

        const SplitBounds = struct {
            first: Rect,
            second: Rect,
            available_width: i32,
            available_height: i32,
        };

        fn splitBounds(branch: Node.Split, bounds: Rect, divider_gap: i32) SplitBounds {
            const ratio = std.math.clamp(branch.ratio, 0.0, 1.0);
            return switch (branch.direction) {
                .horizontal => blk: {
                    const gap = @min(divider_gap, bounds.width);
                    const available = bounds.width - gap;
                    const first = scaledLength(available, ratio);
                    break :blk .{
                        .first = .{
                            .x = bounds.x,
                            .y = bounds.y,
                            .width = first,
                            .height = bounds.height,
                        },
                        .second = .{
                            .x = bounds.x + first + gap,
                            .y = bounds.y,
                            .width = available - first,
                            .height = bounds.height,
                        },
                        .available_width = available,
                        .available_height = bounds.height,
                    };
                },
                .vertical => blk: {
                    const gap = @min(divider_gap, bounds.height);
                    const available = bounds.height - gap;
                    const first = scaledLength(available, ratio);
                    break :blk .{
                        .first = .{
                            .x = bounds.x,
                            .y = bounds.y,
                            .width = bounds.width,
                            .height = first,
                        },
                        .second = .{
                            .x = bounds.x,
                            .y = bounds.y + first + gap,
                            .width = bounds.width,
                            .height = available - first,
                        },
                        .available_width = bounds.width,
                        .available_height = available,
                    };
                },
            };
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

test "Win32 split focus follows visual and directional neighbors" {
    const testing = std.testing;
    const View = struct { id: u8 };
    const Tree = SplitTree(View);

    var left: View = .{ .id = 1 };
    var upper_right: View = .{ .id = 2 };
    var lower_right: View = .{ .id = 3 };
    var tree = try Tree.init(testing.allocator, &left);
    defer tree.deinit(testing.allocator);
    try tree.split(testing.allocator, &left, &upper_right, .horizontal, true);
    try tree.split(testing.allocator, &upper_right, &lower_right, .vertical, true);

    const bounds: Tree.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 41 };
    var output: [3]Tree.LeafRect = undefined;

    try testing.expectEqual(
        @as(?*View, &upper_right),
        tree.focusCandidate(&left, .next, bounds, 1, &output),
    );
    try testing.expectEqual(
        @as(?*View, &lower_right),
        tree.focusCandidate(&upper_right, .next, bounds, 1, &output),
    );
    try testing.expectEqual(
        @as(?*View, &left),
        tree.focusCandidate(&lower_right, .next, bounds, 1, &output),
    );
    try testing.expectEqual(
        @as(?*View, &lower_right),
        tree.focusCandidate(&left, .previous, bounds, 1, &output),
    );
    try testing.expectEqual(
        @as(?*View, &upper_right),
        tree.focusCandidate(&left, .right, bounds, 1, &output),
    );
    try testing.expectEqual(
        @as(?*View, &left),
        tree.focusCandidate(&lower_right, .left, bounds, 1, &output),
    );
    try testing.expectEqual(
        @as(?*View, &lower_right),
        tree.focusCandidate(&upper_right, .down, bounds, 1, &output),
    );
    try testing.expectEqual(
        @as(?*View, &upper_right),
        tree.focusCandidate(&lower_right, .up, bounds, 1, &output),
    );
    try testing.expectEqual(
        @as(?*View, null),
        tree.focusCandidate(&upper_right, .up, bounds, 1, &output),
    );
}

test "Win32 split resize moves the nearest matching divider" {
    const testing = std.testing;
    const View = struct { id: u8 };
    const Tree = SplitTree(View);

    var left: View = .{ .id = 1 };
    var upper_right: View = .{ .id = 2 };
    var lower_right: View = .{ .id = 3 };
    var tree = try Tree.init(testing.allocator, &left);
    defer tree.deinit(testing.allocator);
    try tree.split(testing.allocator, &left, &upper_right, .horizontal, true);
    try tree.split(testing.allocator, &upper_right, &lower_right, .vertical, true);

    const bounds: Tree.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try testing.expect(tree.resize(&lower_right, .horizontal, 10, bounds, 0));
    try testing.expect(tree.resize(&lower_right, .vertical, -10, bounds, 0));

    var output: [3]Tree.LeafRect = undefined;
    _ = tree.layout(bounds, 0, &output);
    try testing.expectEqual(Tree.Rect{ .x = 0, .y = 0, .width = 60, .height = 100 }, output[0].rect);
    try testing.expectEqual(Tree.Rect{ .x = 60, .y = 0, .width = 40, .height = 40 }, output[1].rect);
    try testing.expectEqual(Tree.Rect{ .x = 60, .y = 40, .width = 40, .height = 60 }, output[2].rect);
    try testing.expect(!tree.resize(&left, .vertical, 10, bounds, 0));
}

test "Win32 split equalize gives same-axis leaves equal space" {
    const testing = std.testing;
    const View = struct { id: u8 };
    const Tree = SplitTree(View);

    var first: View = .{ .id = 1 };
    var second: View = .{ .id = 2 };
    var third: View = .{ .id = 3 };
    var tree = try Tree.init(testing.allocator, &first);
    defer tree.deinit(testing.allocator);
    try tree.split(testing.allocator, &first, &second, .horizontal, true);
    try tree.split(testing.allocator, &second, &third, .horizontal, true);
    try testing.expect(tree.resize(
        &third,
        .horizontal,
        20,
        .{ .x = 0, .y = 0, .width = 120, .height = 40 },
        0,
    ));

    try testing.expect(tree.equalize());
    var output: [3]Tree.LeafRect = undefined;
    _ = tree.layout(
        .{ .x = 0, .y = 0, .width = 120, .height = 40 },
        0,
        &output,
    );
    try testing.expectEqual(@as(i32, 40), output[0].rect.width);
    try testing.expectEqual(@as(i32, 40), output[1].rect.width);
    try testing.expectEqual(@as(i32, 40), output[2].rect.width);
    try testing.expect(tree.equalize());
}

test "Win32 split zoom shows one leaf and restores the layout" {
    const testing = std.testing;
    const View = struct { id: u8 };
    const Tree = SplitTree(View);

    var first: View = .{ .id = 1 };
    var second: View = .{ .id = 2 };
    var third: View = .{ .id = 3 };
    var tree = try Tree.init(testing.allocator, &first);
    defer tree.deinit(testing.allocator);
    try tree.split(testing.allocator, &first, &second, .horizontal, true);

    const bounds: Tree.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 40 };
    var output: [3]Tree.LeafRect = undefined;
    try testing.expect(tree.toggleZoom(&second));
    try testing.expect(tree.isZoomed());
    try testing.expectEqual(@as(usize, 1), tree.layout(bounds, 1, &output));
    try testing.expectEqual(&second, output[0].view);
    try testing.expectEqual(bounds, output[0].rect);

    // Focus candidates continue to use the complete tree while zoomed.
    try testing.expectEqual(
        @as(?*View, &first),
        tree.focusCandidate(&second, .previous, bounds, 1, &output),
    );
    tree.updateZoomForNavigation(&first, true);
    try testing.expectEqual(@as(usize, 1), tree.layout(bounds, 1, &output));
    try testing.expectEqual(&first, output[0].view);

    tree.updateZoomForNavigation(&second, false);
    try testing.expect(!tree.isZoomed());
    try testing.expectEqual(@as(usize, 2), tree.layout(bounds, 1, &output));

    try testing.expect(tree.toggleZoom(&first));
    try tree.split(testing.allocator, &second, &third, .vertical, true);
    try testing.expect(!tree.isZoomed());
}

test "Win32 split removal clears zoom only for the removed leaf" {
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

    try testing.expect(tree.toggleZoom(&first));
    _ = try tree.remove(testing.allocator, &third);
    try testing.expect(tree.isZoomed());
    _ = try tree.remove(testing.allocator, &first);
    try testing.expect(!tree.isZoomed());
}
