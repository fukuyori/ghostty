//! IPC request handling for the Win32 runtime: the CLI entry point
//! (`performIpc`), UI request ownership and dispatch to the window thread,
//! and the result returned to the client. The pipe transport stays in
//! `IpcTransport.zig` and the wire format in `IpcProtocol.zig`.

const std = @import("std");
const build_config = @import("../../build_config.zig");
const win32 = @import("win32").everything;
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const brand = @import("../../brand.zig");
const App = @import("App.zig");
const IpcProtocol = @import("IpcProtocol.zig");
const IpcTransport = @import("IpcTransport.zig");
const Overrides = @import("Overrides.zig");
const WindowLifecycle = @import("WindowLifecycle.zig");

const log = std.log.scoped(.win32);

pub const WM_IPC_REQUEST = win32.WM_USER + 6;
const ipc_ui_timeout_ms: u32 = 5000;

pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) anyerror!bool {
    if (action != .new_tab) return false;
    if (target == .class) {
        std.debug.print("+new-tab --class is not supported on Windows.\n", .{});
        return error.IPCFailed;
    }
    const payload = try IpcProtocol.encodeRequest(alloc, .{
        .action = .new_tab,
        .surface_id = value.surface_id,
        .arguments = value.arguments orelse &.{},
    });
    defer alloc.free(payload);
    const response_payload = IpcTransport.clientExchange(alloc, payload) catch |err| {
        switch (err) {
            error.ServerUnavailable => std.debug.print(
                "No running " ++ brand.display_name ++ " instance was found.\n",
                .{},
            ),
            error.ConnectTimeout => std.debug.print(
                brand.display_name ++ " is busy processing another request.\n",
                .{},
            ),
            error.AccessDenied => std.debug.print(
                "Access to the running " ++ brand.display_name ++ " instance was denied; check whether it is running with different privileges.\n",
                .{},
            ),
            error.IoTimeout => std.debug.print(
                "Timed out waiting for " ++ brand.display_name ++ "; the tab may still be created.\n",
                .{},
            ),
            error.ConnectFailed => std.debug.print(
                "Unable to connect to the running " ++ brand.display_name ++ " instance.\n",
                .{},
            ),
            else => std.debug.print(brand.display_name ++ " IPC failed: {}\n", .{err}),
        }
        return error.IPCFailed;
    };
    defer alloc.free(response_payload);
    const response = IpcProtocol.decodeResponse(response_payload) catch |err| {
        std.debug.print("The " ++ brand.display_name ++ " IPC response was invalid: {}\n", .{err});
        return error.IPCFailed;
    };

    return switch (response.status) {
        .success => true,
        .target_fallback => success: {
            std.debug.print(brand.display_name ++ " used a fallback window for the new tab.\n", .{});
            break :success true;
        },
        else => failure: {
            std.debug.print(brand.display_name ++ " could not create the tab: {s}\n", .{response.message});
            break :failure error.IPCFailed;
        },
    };
}

const IpcUiRequest = struct {
    alloc: Allocator,
    arena: std.heap.ArenaAllocator,
    request: IpcProtocol.Request,
    completion: win32.HANDLE,
    refs: std.atomic.Value(u32) = .init(2),
    status: IpcProtocol.Status = .internal_error,
    test_next: if (build_config.win32_test_hooks) ?*IpcUiRequest else void = if (build_config.win32_test_hooks) null else {},

    fn release(self: *IpcUiRequest) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (comptime build_config.win32_test_hooks) {
            _ = test_live.fetchSub(1, .seq_cst);
        }
        _ = win32.CloseHandle(self.completion);
        self.arena.deinit();
        self.alloc.destroy(self);
    }

    fn complete(self: *IpcUiRequest) void {
        _ = win32.SetEvent(self.completion);
        self.release();
    }
};

pub fn ipcHandler(
    context: *anyopaque,
    alloc: Allocator,
    shutdown_event: win32.HANDLE,
    payload: []const u8,
) ![]u8 {
    const app: *App = @ptrCast(@alignCast(context));
    var arena: std.heap.ArenaAllocator = .init(alloc);
    const request = IpcProtocol.decodeRequest(arena.allocator(), payload) catch |err| {
        arena.deinit();
        if (err == error.OutOfMemory) return err;
        return IpcProtocol.encodeResponse(alloc, .{
            .status = if (err == error.UnsupportedVersion) .unsupported_version else .invalid_request,
            .message = if (err == error.UnsupportedVersion)
                "unsupported IPC protocol version"
            else
                "invalid IPC request",
        });
    };

    const ui_request = alloc.create(IpcUiRequest) catch |err| {
        arena.deinit();
        return err;
    };
    ui_request.* = .{
        .alloc = alloc,
        .arena = arena,
        .request = request,
        .completion = win32.CreateEventW(null, 1, 0, null) orelse {
            alloc.destroy(ui_request);
            arena.deinit();
            return error.CreateEventFailed;
        },
    };
    if (comptime build_config.win32_test_hooks) {
        _ = test_live.fetchAdd(1, .seq_cst);
    }
    defer ui_request.release();

    const hwnd = app.wakeup_hwnd orelse {
        ui_request.release();
        return error.UiWindowUnavailable;
    };
    if (win32.PostMessageW(
        hwnd,
        WM_IPC_REQUEST,
        0,
        @bitCast(@intFromPtr(ui_request)),
    ) == 0) {
        ui_request.release();
        return error.PostMessageFailed;
    }

    const handles = [_]?win32.HANDLE{ ui_request.completion, shutdown_event };
    const wait_result = win32.WaitForMultipleObjects(
        handles.len,
        &handles,
        0,
        ipc_ui_timeout_ms,
    );
    const status: IpcProtocol.Status = if (@backingInt(wait_result) == 0)
        ui_request.status
    else if (@backingInt(wait_result) == 1)
        return error.Shutdown
    else if (wait_result == .WAIT_TIMEOUT)
        .timeout
    else
        return error.WaitFailed;

    return IpcProtocol.encodeResponse(alloc, .{
        .status = status,
        .message = switch (status) {
            .success => "tab created",
            .target_fallback => "tab created using fallback target",
            .invalid_request => "invalid IPC request",
            .unsupported_version => "unsupported IPC protocol version",
            .internal_error => "unable to create tab",
            .timeout => "completion unknown; the tab may be created later",
        },
    });
}

fn processIpcRequest(self: *App, request: *IpcUiRequest) void {
    const overrides = Overrides.parse(
        request.arena.allocator(),
        request.request.arguments,
    ) catch {
        request.status = .invalid_request;
        return;
    };
    const opts = WindowLifecycle.Options.fromOverrides(overrides);

    var fallback = false;
    const target = if (request.request.surface_id != 0) target: {
        if (self.core_app.findSurfaceByID(request.request.surface_id)) |surface|
            break :target surface;
        fallback = true;
        log.warn("new-tab: unable to find surface 0x{x:0>16}; using fallback", .{
            request.request.surface_id,
        });
        break :target self.core_app.focusedSurface();
    } else self.core_app.focusedSurface();

    if (target) |surface| {
        if (!(WindowLifecycle.newTabWithOptions(self, .{ .surface = surface }, opts) catch false)) {
            request.status = .internal_error;
            return;
        }
    } else {
        WindowLifecycle.createWindow(self, opts) catch {
            request.status = .internal_error;
            return;
        };
    }
    request.status = if (fallback) .target_fallback else .success;
}

/// Runs a posted request on the window thread. The wakeup window procedure
/// forwards `WM_IPC_REQUEST` here.
pub fn dispatch(hwnd: win32.HWND, lparam: win32.LPARAM) win32.LRESULT {
    const request: *IpcUiRequest = @ptrFromInt(@as(usize, @bitCast(lparam)));
    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr != 0) {
        const app: *App = @ptrFromInt(@as(usize, @bitCast(ptr)));
        if (comptime build_config.win32_test_hooks) {
            if (test_hold) {
                var next = &test_pending;
                while (next.*) |pending| next = &pending.test_next;
                next.* = request;
                return 0;
            }
        }
        processIpcRequest(app, request);
        request.complete();
    } else {
        // The request cannot be completed without its App. Release the UI
        // ownership; the worker remains responsible for its own reference
        // until timeout or shutdown.
        request.release();
    }
    return 0;
}

pub fn discardPendingIpcRequests(self: *App) void {
    if (comptime build_config.win32_test_hooks) {
        while (test_pending) |request| {
            test_pending = request.test_next;
            request.release();
        }
        test_hold = false;
    }
    const hwnd = self.wakeup_hwnd orelse return;
    var msg: win32.MSG = undefined;
    while (win32.PeekMessageW(
        &msg,
        hwnd,
        WM_IPC_REQUEST,
        WM_IPC_REQUEST,
        .{ .REMOVE = 1 },
    ) != 0) {
        if (msg.lParam != 0) {
            const request: *IpcUiRequest = @ptrFromInt(@as(usize, @bitCast(msg.lParam)));
            request.release();
        }
    }
    if (comptime build_config.win32_test_hooks) {
        std.log.scoped(.win32_test).info("IPC test requests remaining={d}", .{testLiveCount()});
        std.debug.assert(testLiveCount() == 0);
    }
}

// UI-thread-only pending list; the worker's reference survives independently.
var test_hold = false;
var test_pending: ?*IpcUiRequest = null;
var test_live: std.atomic.Value(usize) = .init(0);

pub fn testHold(app: *App, hold: bool) void {
    if (comptime !build_config.win32_test_hooks) return;
    test_hold = hold;
    if (!hold) while (test_pending) |request| {
        test_pending = request.test_next;
        processIpcRequest(app, request);
        request.complete();
    };
}

pub fn testPendingCount() usize {
    if (comptime !build_config.win32_test_hooks) return 0;
    var count: usize = 0;
    var next = test_pending;
    while (next) |request| : (next = request.test_next) count += 1;
    return count;
}

pub fn testLiveCount() usize {
    if (comptime !build_config.win32_test_hooks) return 0;
    return test_live.load(.seq_cst);
}

test "Win32 IPC request survives either owner releasing first" {
    const testing = std.testing;
    for ([_]bool{ false, true }) |ui_first| {
        const request = try testing.allocator.create(IpcUiRequest);
        request.* = .{
            .alloc = testing.allocator,
            .arena = .init(testing.allocator),
            .request = .{ .action = .new_tab, .surface_id = 0, .arguments = &.{} },
            .completion = win32.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed,
        };
        if (comptime build_config.win32_test_hooks) {
            _ = test_live.fetchAdd(1, .seq_cst);
        }
        const payload = try request.arena.allocator().dupe(u8, "owned until both release");
        if (ui_first) request.complete() else request.release();
        try testing.expectEqual(@as(u32, 1), request.refs.load(.seq_cst));
        try testing.expectEqualStrings("owned until both release", payload);
        const signaled = @backingInt(win32.WaitForSingleObject(request.completion, 0)) == 0;
        try testing.expectEqual(ui_first, signaled);
        if (ui_first) request.release() else request.complete();
    }
}
