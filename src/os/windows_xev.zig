//! Windows event loop adapter. Ghostty passes Async handles by value between
//! the renderer, termio, and stream handler. Unlike fd-backed Async handles,
//! libxev's IOCP Async stores its waiter inline: copying it creates a separate
//! notification state. Keep that state at one stable address instead.
const std = @import("std");
const native = @import("xev").Dynamic;

pub const dynamic = native.dynamic;
pub const backend = native.backend;
pub const Loop = native.Loop;
pub const Completion = native.Completion;
pub const CallbackAction = native.CallbackAction;
pub const Timer = native.Timer;
pub const Process = native.Process;
pub const Stream = native.Stream;
pub const WriteBuffer = native.WriteBuffer;
pub const WriteError = native.WriteError;
pub const WriteQueue = native.WriteQueue;
pub const WriteRequest = native.WriteRequest;

pub const Async = struct {
    state: *native.Async,

    pub const WaitError = native.Async.WaitError;
    const allocator = if (@import("builtin").is_test)
        std.testing.allocator
    else
        std.heap.page_allocator;

    pub fn init() !Async {
        const state = try allocator.create(native.Async);
        errdefer allocator.destroy(state);
        state.* = try native.Async.init();
        return .{ .state = state };
    }

    /// As with the original OS handle, only the owner calls deinit, after
    /// its loop and all producers have stopped. Copies are borrowed handles.
    pub fn deinit(self: *Async) void {
        self.state.deinit();
        allocator.destroy(self.state);
        self.* = undefined;
    }

    pub fn notify(self: *Async) !void {
        try self.state.notify();
    }

    pub fn wait(
        self: Async,
        loop: *Loop,
        completion: *Completion,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime callback: *const fn (?*Userdata, *Loop, *Completion, WaitError!void) CallbackAction,
    ) void {
        self.state.wait(loop, completion, Userdata, userdata, callback);
    }
};

fn countWake(count: ?*usize, _: *Loop, _: *Completion, result: Async.WaitError!void) CallbackAction {
    result catch unreachable;
    count.?.* += 1;
    return .rearm;
}

test "Win32 Async copies share notifications before and after wait" {
    var loop = try Loop.init(.{});
    defer loop.deinit();
    var owner = try Async.init();
    defer owner.deinit();
    var producer = owner;
    const waiter = owner;
    var completion: Completion = .{};
    var count: usize = 0;

    // Termio can produce output before the renderer registers its waiter.
    try producer.notify();
    waiter.wait(&loop, &completion, usize, &count, countWake);
    try loop.run(.no_wait);
    try std.testing.expectEqual(@as(usize, 1), count);

    // The producer copy must also see the waiter registered on the owner.
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(handle: Async) void {
            var copy = handle;
            copy.notify() catch unreachable;
        }
    }.run, .{producer});
    thread.join();
    try loop.run(.no_wait);
    try std.testing.expectEqual(@as(usize, 2), count);
    try loop.run(.no_wait);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Win32 copied renderer wakeup drains a full 64 message queue" {
    const Queue = @import("../datastruct/blocking_queue.zig").BlockingQueue(u8, 64);
    const Consumer = struct {
        queue: *Queue,
        received: usize = 0,

        fn wake(self_: ?*@This(), _: *Loop, _: *Completion, result: Async.WaitError!void) CallbackAction {
            result catch unreachable;
            const self = self_.?;
            while (self.queue.pop(std.testing.io)) |_| self.received += 1;
            return .rearm;
        }
    };
    var loop = try Loop.init(.{});
    defer loop.deinit();
    var owner = try Async.init();
    defer owner.deinit();
    // Both the termio object and its stream handler copy this handle.
    const termio = owner;
    var stream_handler = termio;
    var queue: Queue = .{};
    var consumer: Consumer = .{ .queue = &queue };
    var completion: Completion = .{};
    owner.wait(&loop, &completion, Consumer, &consumer, Consumer.wake);

    // Repeat after rearming; this also catches a one-shot-only repair.
    for (0..3) |batch| {
        for (0..64) |_| {
            try std.testing.expect(queue.push(std.testing.io, 4, .instant) != 0);
        }
        try std.testing.expectEqual(@as(u32, 0), queue.push(std.testing.io, 2, .instant));
        try stream_handler.notify();
        try loop.run(.no_wait);
        try std.testing.expectEqual((batch + 1) * 64, consumer.received);
        // The focus notification now fits, without an unbounded test wait.
        try std.testing.expectEqual(@as(u32, 1), queue.push(std.testing.io, 2, .instant));
        try std.testing.expectEqual(@as(?u8, 2), queue.pop(std.testing.io));
    }
}
