const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32").everything;

const Allocator = std.mem.Allocator;

const pipe_prefix = "\\\\.\\pipe\\fukuyori.ghostty.win32-ipc";
const pipe_buffer_size: u32 = 4 + 64 * 1024;

pub const WaitResult = union(enum) {
    completed: u32,
    shutdown,
    timeout,
};

pub const Operation = struct {
    event: win32.HANDLE,
    overlapped: win32.OVERLAPPED,

    pub fn init() !Operation {
        const event = win32.CreateEventW(null, 1, 0, null) orelse
            return error.CreateEventFailed;
        return .{
            .event = event,
            .overlapped = .{
                .Internal = 0,
                .InternalHigh = 0,
                .Anonymous = .{ .Pointer = null },
                .hEvent = event,
            },
        };
    }

    pub fn deinit(self: *Operation) void {
        _ = win32.CloseHandle(self.event);
        self.* = undefined;
    }

    /// Prepare this object for another overlapped operation after the previous
    /// operation has been collected by wait().
    pub fn reset(self: *Operation) !void {
        if (win32.ResetEvent(self.event) == 0) return error.ResetEventFailed;
        self.overlapped = .{
            .Internal = 0,
            .InternalHigh = 0,
            .Anonymous = .{ .Pointer = null },
            .hEvent = self.event,
        };
    }

    /// Wait for an issued overlapped operation. Cancellation is not complete
    /// until GetOverlappedResult returns, so callers may release the OVERLAPPED
    /// and its buffer only after this function returns. Shutdown and timeout
    /// win races with completion; callers must discard or disconnect the pipe
    /// even when the operation completed immediately before cancellation.
    pub fn wait(
        self: *Operation,
        handle: win32.HANDLE,
        shutdown_event: win32.HANDLE,
        timeout_ms: u32,
    ) !WaitResult {
        const handles = [_]?win32.HANDLE{ self.event, shutdown_event };
        const wait_result = win32.WaitForMultipleObjects(handles.len, &handles, 0, timeout_ms);
        if (@intFromEnum(wait_result) == 0) return .{
            .completed = try self.collectResult(handle, false),
        };

        const reason: WaitResult = if (@intFromEnum(wait_result) == 1)
            .shutdown
        else if (wait_result == .WAIT_TIMEOUT)
            .timeout
        else {
            // Even a failed wait does not make the pending I/O and its
            // OVERLAPPED storage safe to release.
            self.cancelAndCollect(handle) catch {};
            return error.WaitFailed;
        };

        try self.cancelAndCollect(handle);
        return reason;
    }

    fn cancelAndCollect(self: *Operation, handle: win32.HANDLE) !void {
        var cancel_failed = false;
        if (win32.CancelIoEx(handle, &self.overlapped) == 0) switch (win32.GetLastError()) {
            // The operation completed between the wait and cancellation.
            .ERROR_NOT_FOUND => {},
            else => cancel_failed = true,
        };
        _ = self.collectResult(handle, true) catch |err| switch (err) {
            error.OperationAborted => {},
            else => {
                if (cancel_failed) return error.CancelIoFailed;
                return err;
            },
        };
        if (cancel_failed) return error.CancelIoFailed;
    }

    fn collectResult(self: *Operation, handle: win32.HANDLE, should_wait: bool) !u32 {
        var transferred: u32 = 0;
        if (win32.GetOverlappedResult(
            handle,
            &self.overlapped,
            &transferred,
            @intFromBool(should_wait),
        ) == 0) return switch (win32.GetLastError()) {
            .ERROR_OPERATION_ABORTED => error.OperationAborted,
            else => error.OverlappedIoFailed,
        };
        return transferred;
    }
};

pub const AcceptStart = enum {
    connected,
    pending,
};

/// Begin an overlapped accept. A client can connect between CreateNamedPipeW
/// and ConnectNamedPipe, in which case ERROR_PIPE_CONNECTED is synchronous
/// success and the operation event is not guaranteed to be signaled.
pub fn beginAccept(handle: win32.HANDLE, operation: *Operation) !AcceptStart {
    try operation.reset();
    if (win32.ConnectNamedPipe(handle, &operation.overlapped) != 0)
        return .connected;
    return switch (win32.GetLastError()) {
        .ERROR_IO_PENDING => .pending,
        .ERROR_PIPE_CONNECTED => .connected,
        else => error.ConnectNamedPipeFailed,
    };
}

/// Prevent a named-pipe server from impersonating the CLI process. The
/// generated binding uses file-attribute aliases for these shared bits.
pub fn clientSecurityFlags() win32.FILE_FLAGS_AND_ATTRIBUTES {
    var flags = win32.SECURITY_SQOS_PRESENT;
    flags.FILE_ATTRIBUTE_VIRTUAL = 1; // SECURITY_IDENTIFICATION
    return flags;
}

pub const Identity = struct {
    session_id: u32,
    sid_hash: u64,
    sid_string: []u16,

    pub fn init(alloc: Allocator) !Identity {
        var session_id: u32 = 0;
        if (win32.ProcessIdToSessionId(win32.GetCurrentProcessId(), &session_id) == 0)
            return error.SessionIdUnavailable;

        var token: ?win32.HANDLE = null;
        if (win32.OpenProcessToken(
            win32.GetCurrentProcess(),
            win32.TOKEN_QUERY,
            &token,
        ) == 0) return error.ProcessTokenUnavailable;
        defer _ = win32.CloseHandle(token);

        var required: u32 = 0;
        _ = win32.GetTokenInformation(token, win32.TokenLogonSid, null, 0, &required);
        if (required == 0) return error.LogonSidUnavailable;
        const token_info = try alloc.alignedAlloc(u8, .of(win32.TOKEN_GROUPS), required);
        defer alloc.free(token_info);
        if (win32.GetTokenInformation(
            token,
            win32.TokenLogonSid,
            token_info.ptr,
            required,
            &required,
        ) == 0) return error.LogonSidUnavailable;

        const groups: *const win32.TOKEN_GROUPS = @ptrCast(@alignCast(token_info.ptr));
        if (groups.GroupCount != 1) return error.LogonSidUnavailable;
        const sid = groups.Groups[0].Sid orelse return error.LogonSidUnavailable;
        const sid_len = win32.GetLengthSid(sid);
        if (sid_len == 0) return error.LogonSidUnavailable;
        const sid_bytes: [*]const u8 = @ptrCast(sid);
        const sid_hash = std.hash.Wyhash.hash(0, sid_bytes[0..sid_len]);

        var sid_string_ptr: ?win32.PWSTR = null;
        if (win32.ConvertSidToStringSidW(sid, &sid_string_ptr) == 0)
            return error.LogonSidUnavailable;
        const sid_string_value = sid_string_ptr orelse return error.LogonSidUnavailable;
        defer _ = win32.LocalFree(@intCast(@intFromPtr(sid_string_value)));
        const sid_string = try alloc.dupe(u16, std.mem.span(sid_string_value));

        return .{
            .session_id = session_id,
            .sid_hash = sid_hash,
            .sid_string = sid_string,
        };
    }

    pub fn deinit(self: *Identity, alloc: Allocator) void {
        alloc.free(self.sid_string);
        self.* = undefined;
    }

    pub fn pipeName(self: Identity, alloc: Allocator) ![:0]u16 {
        const channel = if (builtin.mode == .Debug) "debug" else "release";
        return self.pipeNameWithChannel(alloc, channel);
    }

    pub fn pipeNameWithChannel(
        self: Identity,
        alloc: Allocator,
        channel: []const u8,
    ) ![:0]u16 {
        const utf8 = try std.fmt.allocPrint(
            alloc,
            pipe_prefix ++ "-{d}-{x:0>16}-{s}",
            .{ self.session_id, self.sid_hash, channel },
        );
        defer alloc.free(utf8);
        return std.unicode.utf8ToUtf16LeAllocZ(alloc, utf8);
    }
};

pub const Security = struct {
    descriptor: win32.PSECURITY_DESCRIPTOR,
    attributes: win32.SECURITY_ATTRIBUTES,

    pub fn init(alloc: Allocator, sid: []const u16) !Security {
        const prefix = std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;");
        const suffix = std.unicode.utf8ToUtf16LeStringLiteral(")");
        const sddl = try alloc.allocSentinel(u16, prefix.len + sid.len + suffix.len, 0);
        defer alloc.free(sddl);
        @memcpy(sddl[0..prefix.len], prefix);
        @memcpy(sddl[prefix.len..][0..sid.len], sid);
        @memcpy(sddl[prefix.len + sid.len ..][0..suffix.len], suffix);

        var descriptor: ?win32.PSECURITY_DESCRIPTOR = null;
        if (win32.ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl,
            win32.SDDL_REVISION_1,
            &descriptor,
            null,
        ) == 0) return error.SecurityDescriptorUnavailable;
        const value = descriptor orelse return error.SecurityDescriptorUnavailable;
        return .{
            .descriptor = value,
            .attributes = .{
                .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
                .lpSecurityDescriptor = value,
                .bInheritHandle = 0,
            },
        };
    }

    pub fn deinit(self: *Security) void {
        _ = win32.LocalFree(@intCast(@intFromPtr(self.descriptor)));
        self.* = undefined;
    }
};

pub const Listener = struct {
    alloc: Allocator,
    identity: Identity,
    name: [:0]u16,
    security: Security,
    first: win32.HANDLE,

    pub fn init(alloc: Allocator) !Listener {
        const channel = if (builtin.mode == .Debug) "debug" else "release";
        return initWithChannel(alloc, channel);
    }

    pub fn initWithChannel(alloc: Allocator, channel: []const u8) !Listener {
        var identity = try Identity.init(alloc);
        errdefer identity.deinit(alloc);
        const name = try identity.pipeNameWithChannel(alloc, channel);
        errdefer alloc.free(name);
        var security = try Security.init(alloc, identity.sid_string);
        errdefer security.deinit();

        const first = createInstance(name, &security.attributes, true) catch |err| switch (err) {
            error.AccessDenied => return error.PipeAlreadyOwned,
            else => return err,
        };
        return .{
            .alloc = alloc,
            .identity = identity,
            .name = name,
            .security = security,
            .first = first,
        };
    }

    pub fn deinit(self: *Listener) void {
        _ = win32.CloseHandle(self.first);
        self.security.deinit();
        self.alloc.free(self.name);
        self.identity.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn additionalInstance(self: *Listener) !win32.HANDLE {
        return createInstance(self.name, &self.security.attributes, false);
    }
};

fn createInstance(
    name: [:0]const u16,
    security: *win32.SECURITY_ATTRIBUTES,
    first: bool,
) !win32.HANDLE {
    var open_mode = win32.PIPE_ACCESS_DUPLEX;
    open_mode.FILE_FLAG_OVERLAPPED = 1;
    // The generated binding names bit 0x00080000 FILE_ATTRIBUTE_PINNED in
    // this shared flag type. CreateNamedPipeW defines the same bit as
    // FILE_FLAG_FIRST_PIPE_INSTANCE.
    if (first) open_mode.FILE_ATTRIBUTE_PINNED = 1;
    var pipe_mode = win32.PIPE_TYPE_BYTE;
    pipe_mode.REJECT_REMOTE_CLIENTS = 1;
    const handle = win32.CreateNamedPipeW(
        name,
        open_mode,
        pipe_mode,
        win32.PIPE_UNLIMITED_INSTANCES,
        pipe_buffer_size,
        pipe_buffer_size,
        0,
        security,
    );
    if (handle == win32.INVALID_HANDLE_VALUE) return switch (win32.GetLastError()) {
        .ERROR_ACCESS_DENIED => error.AccessDenied,
        else => error.CreateNamedPipeFailed,
    };
    return handle;
}

test "Win32 IPC identity produces a scoped pipe name and ACL" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var identity = try Identity.init(testing.allocator);
    defer identity.deinit(testing.allocator);
    const name = try identity.pipeName(testing.allocator);
    defer testing.allocator.free(name);

    const expected_prefix = std.unicode.utf8ToUtf16LeStringLiteral(pipe_prefix);
    try testing.expect(std.mem.startsWith(u16, name, expected_prefix));
    try testing.expect(identity.sid_string.len > 0);

    var security = try Security.init(testing.allocator, identity.sid_string);
    defer security.deinit();
    try testing.expect(security.attributes.lpSecurityDescriptor != null);
}

test "Win32 IPC first pipe instance owns the endpoint" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var channel_buf: [64]u8 = undefined;
    const channel = try std.fmt.bufPrint(
        &channel_buf,
        "test-{d}",
        .{win32.GetCurrentProcessId()},
    );
    var listener = try Listener.initWithChannel(testing.allocator, channel);
    defer listener.deinit();
    try testing.expectError(
        error.PipeAlreadyOwned,
        Listener.initWithChannel(testing.allocator, channel),
    );

    const additional = try listener.additionalInstance();
    defer _ = win32.CloseHandle(additional);
}

test "Win32 IPC operation owns an event and client uses identification SQOS" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var operation = try Operation.init();
    defer operation.deinit();
    try std.testing.expect(operation.overlapped.hEvent == operation.event);

    operation.overlapped.Internal = 1;
    operation.overlapped.InternalHigh = 2;
    try std.testing.expect(win32.SetEvent(operation.event) != 0);
    try operation.reset();
    try std.testing.expectEqual(@as(usize, 0), operation.overlapped.Internal);
    try std.testing.expectEqual(@as(usize, 0), operation.overlapped.InternalHigh);
    try std.testing.expect(operation.overlapped.hEvent == operation.event);
    const event_handles = [_]?win32.HANDLE{operation.event};
    const event_wait = win32.WaitForMultipleObjects(event_handles.len, &event_handles, 0, 0);
    try std.testing.expectEqual(
        @TypeOf(event_wait).WAIT_TIMEOUT,
        event_wait,
    );

    const flags = clientSecurityFlags();
    try std.testing.expect(flags.FILE_ATTRIBUTE_UNPINNED == 1);
    try std.testing.expect(flags.FILE_ATTRIBUTE_VIRTUAL == 1);
}

test "Win32 IPC shutdown cancels and reaps an overlapped accept" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var channel_buf: [64]u8 = undefined;
    const channel = try std.fmt.bufPrint(
        &channel_buf,
        "test-cancel-{d}",
        .{win32.GetCurrentProcessId()},
    );
    var listener = try Listener.initWithChannel(testing.allocator, channel);
    defer listener.deinit();
    var operation = try Operation.init();
    defer operation.deinit();
    const shutdown = win32.CreateEventW(null, 1, 0, null) orelse
        return error.CreateEventFailed;
    defer _ = win32.CloseHandle(shutdown);

    try testing.expectEqual(AcceptStart.pending, try beginAccept(listener.first, &operation));
    try testing.expect(win32.SetEvent(shutdown) != 0);
    try testing.expectEqual(
        WaitResult.shutdown,
        try operation.wait(listener.first, shutdown, 5000),
    );
}
