const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32").everything;
const Protocol = @import("IpcProtocol.zig");

const Allocator = std.mem.Allocator;

const pipe_prefix = "\\\\.\\pipe\\fukuyori.ghostty.win32-ipc";
const pipe_buffer_size: u32 = 4 + 64 * 1024;
const accept_retry_limit: u8 = 3;
const accept_retry_delay_ms: u32 = 50;

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
    disconnected,
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
        // The client connected and closed before the accept began. The
        // listener can disconnect this instance and immediately reuse it.
        .ERROR_NO_DATA => .disconnected,
        else => error.ConnectNamedPipeFailed,
    };
}

const io_timeout_ms: u32 = 5000;
const client_response_timeout_ms: u32 = 7000;
const client_connect_timeout_ms: u32 = 7000;

pub fn clientExchange(alloc: Allocator, payload: []const u8) ![]u8 {
    return clientExchangeWithChannel(alloc, payload, null);
}

fn clientExchangeWithChannel(
    alloc: Allocator,
    payload: []const u8,
    channel: ?[]const u8,
) ![]u8 {
    var identity = try Identity.init(alloc);
    defer identity.deinit(alloc);
    const name = if (channel) |value|
        try identity.pipeNameWithChannel(alloc, value)
    else
        try identity.pipeName(alloc);
    defer alloc.free(name);

    const pipe = try connectClient(name);
    defer _ = win32.CloseHandle(pipe);
    const shutdown_event = win32.CreateEventW(null, 1, 0, null) orelse
        return error.CreateEventFailed;
    defer _ = win32.CloseHandle(shutdown_event);
    var operation = try Operation.init();
    defer operation.deinit();

    const frame = try Protocol.encodeFrame(alloc, payload);
    defer alloc.free(frame);
    try writeExactTimeout(
        pipe,
        shutdown_event,
        &operation,
        frame,
        client_response_timeout_ms,
    );

    var header: [@sizeOf(u32)]u8 = undefined;
    try readExactTimeout(
        pipe,
        shutdown_event,
        &operation,
        &header,
        client_response_timeout_ms,
    );
    const response_len = try Protocol.frameLength(&header);
    const response = try alloc.alloc(u8, response_len);
    errdefer alloc.free(response);
    try readExactTimeout(
        pipe,
        shutdown_event,
        &operation,
        response,
        client_response_timeout_ms,
    );
    return response;
}

fn connectClient(name: [:0]const u16) !win32.HANDLE {
    const read_bits: u32 = @bitCast(win32.FILE_GENERIC_READ);
    const write_bits: u32 = @bitCast(win32.FILE_GENERIC_WRITE);
    var flags = clientSecurityFlags();
    flags.FILE_FLAG_OVERLAPPED = 1;
    const started = win32.GetTickCount64();
    while (true) {
        const pipe = win32.CreateFileW(
            name,
            @bitCast(read_bits | write_bits),
            .{},
            null,
            .OPEN_EXISTING,
            flags,
            null,
        );
        if (pipe != win32.INVALID_HANDLE_VALUE) return pipe;
        switch (win32.GetLastError()) {
            .ERROR_FILE_NOT_FOUND => return error.ServerUnavailable,
            .ERROR_ACCESS_DENIED => return error.AccessDenied,
            .ERROR_PIPE_BUSY => {
                const elapsed = win32.GetTickCount64() - started;
                if (elapsed >= client_connect_timeout_ms) return error.ConnectTimeout;
                const remaining: u32 = @intCast(client_connect_timeout_ms - elapsed);
                if (win32.WaitNamedPipeW(name, remaining) == 0) {
                    const wait_error = win32.GetLastError();
                    if (wait_error == .ERROR_SEM_TIMEOUT) return error.ConnectTimeout;
                    if (wait_error == .ERROR_FILE_NOT_FOUND) return error.ServerUnavailable;
                    if (wait_error == .ERROR_ACCESS_DENIED) return error.AccessDenied;
                    // Another client may have claimed the instance between
                    // WaitNamedPipeW and CreateFileW. Retry while the shared
                    // connection deadline still has time remaining.
                    if (wait_error == .ERROR_PIPE_BUSY) continue;
                    return error.ConnectFailed;
                }
            },
            else => return error.ConnectFailed,
        }
    }
}

fn readPayload(
    alloc: Allocator,
    handle: win32.HANDLE,
    shutdown_event: win32.HANDLE,
    operation: *Operation,
) ![]u8 {
    var header: [@sizeOf(u32)]u8 = undefined;
    try readExact(handle, shutdown_event, operation, &header);
    const payload_len = try Protocol.frameLength(&header);
    const payload = try alloc.alloc(u8, payload_len);
    errdefer alloc.free(payload);
    try readExact(handle, shutdown_event, operation, payload);
    return payload;
}

fn writePayload(
    alloc: Allocator,
    handle: win32.HANDLE,
    shutdown_event: win32.HANDLE,
    operation: *Operation,
    payload: []const u8,
) !void {
    const frame = try Protocol.encodeFrame(alloc, payload);
    defer alloc.free(frame);
    try writeExact(handle, shutdown_event, operation, frame);
}

fn readExact(
    handle: win32.HANDLE,
    shutdown_event: win32.HANDLE,
    operation: *Operation,
    buffer: []u8,
) !void {
    return readExactTimeout(handle, shutdown_event, operation, buffer, io_timeout_ms);
}

fn readExactTimeout(
    handle: win32.HANDLE,
    shutdown_event: win32.HANDLE,
    operation: *Operation,
    buffer: []u8,
    timeout_ms: u32,
) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        try operation.reset();
        const pending = win32.ReadFile(
            handle,
            buffer[offset..].ptr,
            @intCast(buffer.len - offset),
            null,
            &operation.overlapped,
        ) == 0;
        const transferred = if (!pending)
            try operation.collectResult(handle, false)
        else switch (win32.GetLastError()) {
            .ERROR_IO_PENDING => switch (try operation.wait(handle, shutdown_event, timeout_ms)) {
                .completed => |count| count,
                .shutdown => return error.Shutdown,
                .timeout => return error.IoTimeout,
            },
            .ERROR_BROKEN_PIPE, .ERROR_NO_DATA => return error.Disconnected,
            else => return error.ReadFailed,
        };
        if (transferred == 0) return error.Disconnected;
        offset += transferred;
    }
}

fn writeExact(
    handle: win32.HANDLE,
    shutdown_event: win32.HANDLE,
    operation: *Operation,
    buffer: []const u8,
) !void {
    return writeExactTimeout(handle, shutdown_event, operation, buffer, io_timeout_ms);
}

fn writeExactTimeout(
    handle: win32.HANDLE,
    shutdown_event: win32.HANDLE,
    operation: *Operation,
    buffer: []const u8,
    timeout_ms: u32,
) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        try operation.reset();
        const pending = win32.WriteFile(
            handle,
            @constCast(buffer[offset..].ptr),
            @intCast(buffer.len - offset),
            null,
            &operation.overlapped,
        ) == 0;
        const transferred = if (!pending)
            try operation.collectResult(handle, false)
        else switch (win32.GetLastError()) {
            .ERROR_IO_PENDING => switch (try operation.wait(handle, shutdown_event, timeout_ms)) {
                .completed => |count| count,
                .shutdown => return error.Shutdown,
                .timeout => return error.IoTimeout,
            },
            .ERROR_BROKEN_PIPE, .ERROR_NO_DATA => return error.Disconnected,
            else => return error.WriteFailed,
        };
        if (transferred == 0) return error.Disconnected;
        offset += transferred;
    }
}

pub const Server = struct {
    pub const Handler = *const fn (
        *anyopaque,
        Allocator,
        win32.HANDLE,
        []const u8,
    ) anyerror![]u8;

    alloc: Allocator,
    listener: Listener,
    shutdown_event: win32.HANDLE,
    handler_context: *anyopaque,
    handler: Handler,
    thread: std.Thread,

    pub fn init(
        alloc: Allocator,
        handler_context: *anyopaque,
        handler: Handler,
    ) !*Server {
        return initWithChannel(alloc, handler_context, handler, null);
    }

    fn initWithChannel(
        alloc: Allocator,
        handler_context: *anyopaque,
        handler: Handler,
        channel: ?[]const u8,
    ) !*Server {
        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);
        self.* = undefined;
        self.alloc = alloc;
        self.listener = if (channel) |value|
            try Listener.initWithChannel(alloc, value)
        else
            try Listener.init(alloc);
        errdefer self.listener.deinit();
        self.shutdown_event = win32.CreateEventW(null, 1, 0, null) orelse
            return error.CreateEventFailed;
        errdefer _ = win32.CloseHandle(self.shutdown_event);
        self.handler_context = handler_context;
        self.handler = handler;
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        return self;
    }

    pub fn deinit(self: *Server) void {
        _ = win32.SetEvent(self.shutdown_event);
        self.thread.join();
        _ = win32.CloseHandle(self.shutdown_event);
        self.listener.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    fn threadMain(self: *Server) void {
        self.run() catch |err| {
            std.log.scoped(.win32_ipc).err("IPC listener stopped: {}", .{err});
        };
    }

    fn run(self: *Server) !void {
        var operation = try Operation.init();
        defer operation.deinit();
        var accept_failures: u8 = 0;
        while (true) {
            const start = beginAccept(self.listener.first, &operation) catch |err| switch (err) {
                // A client can disappear while its connection is being
                // accepted. Retry briefly, but do not spin forever if the
                // pipe handle itself has become unusable.
                error.ConnectNamedPipeFailed => {
                    _ = win32.DisconnectNamedPipe(self.listener.first);
                    accept_failures += 1;
                    if (accept_failures >= accept_retry_limit) {
                        std.log.scoped(.win32_ipc).warn(
                            "stopping IPC listener after {d} consecutive accept failures",
                            .{accept_failures},
                        );
                        return error.RepeatedAcceptFailure;
                    }
                    const retry_wait = win32.WaitForSingleObject(
                        self.shutdown_event,
                        accept_retry_delay_ms,
                    );
                    if (@intFromEnum(retry_wait) == 0) return;
                    if (retry_wait != .WAIT_TIMEOUT) return error.WaitFailed;
                    continue;
                },
                else => return err,
            };
            accept_failures = 0;
            switch (start) {
                .disconnected => {
                    _ = win32.DisconnectNamedPipe(self.listener.first);
                    continue;
                },
                .pending => switch (operation.wait(
                    self.listener.first,
                    self.shutdown_event,
                    win32.INFINITE,
                ) catch |err| switch (err) {
                    // A client-side disconnect may complete an accept with an
                    // I/O error. It invalidates this connection, not the
                    // listener itself.
                    error.OverlappedIoFailed => {
                        _ = win32.DisconnectNamedPipe(self.listener.first);
                        continue;
                    },
                    else => return err,
                }) {
                    .completed => {},
                    .shutdown => return,
                    .timeout => unreachable,
                },
                .connected => {},
            }

            self.serve(self.listener.first, &operation) catch |err| switch (err) {
                error.Shutdown => return,
                error.Disconnected, error.IoTimeout => {},
                error.PayloadTooLarge => self.writeErrorResponse(
                    self.listener.first,
                    &operation,
                    .invalid_request,
                    "request exceeds the 64 KiB limit",
                ) catch {},
                else => {
                    std.log.scoped(.win32_ipc).warn("IPC request failed: {}", .{err});
                    self.writeErrorResponse(
                        self.listener.first,
                        &operation,
                        .internal_error,
                        "IPC request failed",
                    ) catch {};
                },
            };
            _ = win32.DisconnectNamedPipe(self.listener.first);
        }
    }

    fn serve(self: *Server, handle: win32.HANDLE, operation: *Operation) !void {
        const request = try readPayload(self.alloc, handle, self.shutdown_event, operation);
        defer self.alloc.free(request);
        const response = try self.handler(
            self.handler_context,
            self.alloc,
            self.shutdown_event,
            request,
        );
        defer self.alloc.free(response);
        // Keep frame construction failures eligible for an internal-error
        // response. Once the first response write has been attempted, never
        // append another frame after a possibly partial one.
        const frame = Protocol.encodeFrame(self.alloc, response) catch |err| switch (err) {
            error.PayloadTooLarge => return error.ResponseTooLarge,
            else => return err,
        };
        defer self.alloc.free(frame);
        writeExact(handle, self.shutdown_event, operation, frame) catch |err| switch (err) {
            error.Shutdown => return err,
            else => {
                std.log.scoped(.win32_ipc).warn(
                    "IPC response write failed: {}",
                    .{err},
                );
                return;
            },
        };
        self.waitForClientClose(handle, operation) catch |err| switch (err) {
            error.Shutdown => return err,
            error.Disconnected, error.IoTimeout => return,
            else => {
                // A response has already been sent. Log and disconnect this
                // client without attempting a second protocol response.
                std.log.scoped(.win32_ipc).warn(
                    "IPC client failed after response: {}",
                    .{err},
                );
                return;
            },
        };
    }

    fn waitForClientClose(
        self: *Server,
        handle: win32.HANDLE,
        operation: *Operation,
    ) !void {
        // DisconnectNamedPipe discards unread buffered data. Wait for the
        // client to consume the response and close its handle, but keep this
        // wait cancellable and bounded rather than using FlushFileBuffers,
        // which can block indefinitely on a client that stops reading.
        var unexpected: [1]u8 = undefined;
        readExact(handle, self.shutdown_event, operation, &unexpected) catch |err| switch (err) {
            error.Disconnected, error.IoTimeout => return,
            else => return err,
        };
        return error.TrailingClientData;
    }

    fn writeErrorResponse(
        self: *Server,
        handle: win32.HANDLE,
        operation: *Operation,
        status: Protocol.Status,
        message: []const u8,
    ) !void {
        const response = try Protocol.encodeResponse(self.alloc, .{
            .status = status,
            .message = message,
        });
        defer self.alloc.free(response);
        try writePayload(self.alloc, handle, self.shutdown_event, operation, response);
        try self.waitForClientClose(handle, operation);
    }
};

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

test "Win32 IPC server accepts repeated framed requests" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const Test = struct {
        fn echo(
            _: *anyopaque,
            alloc: Allocator,
            _: win32.HANDLE,
            request: []const u8,
        ) ![]u8 {
            if (std.mem.eql(u8, request, "handler failure"))
                return error.TestHandlerFailure;
            return alloc.dupe(u8, request);
        }

        fn connect(name: [:0]const u16) !win32.HANDLE {
            const read_bits: u32 = @bitCast(win32.FILE_GENERIC_READ);
            const write_bits: u32 = @bitCast(win32.FILE_GENERIC_WRITE);
            while (true) {
                const pipe = win32.CreateFileW(
                    name,
                    @bitCast(read_bits | write_bits),
                    .{},
                    null,
                    .OPEN_EXISTING,
                    clientSecurityFlags(),
                    null,
                );
                if (pipe != win32.INVALID_HANDLE_VALUE) return pipe;
                if (win32.GetLastError() != .ERROR_PIPE_BUSY)
                    return error.ConnectFailed;
                if (win32.WaitNamedPipeW(name, 5000) == 0)
                    return error.ConnectFailed;
            }
        }

        fn writeAll(pipe: win32.HANDLE, bytes: []const u8) !void {
            var offset: usize = 0;
            while (offset < bytes.len) {
                var written: u32 = 0;
                if (win32.WriteFile(
                    pipe,
                    @constCast(bytes[offset..].ptr),
                    @intCast(bytes.len - offset),
                    &written,
                    null,
                ) == 0) return error.WriteFailed;
                if (written == 0) return error.WriteFailed;
                offset += written;
            }
        }

        fn readAll(pipe: win32.HANDLE, bytes: []u8) !void {
            var offset: usize = 0;
            while (offset < bytes.len) {
                var read: u32 = 0;
                if (win32.ReadFile(
                    pipe,
                    bytes[offset..].ptr,
                    @intCast(bytes.len - offset),
                    &read,
                    null,
                ) == 0) return error.ReadFailed;
                if (read == 0) return error.ReadFailed;
                offset += read;
            }
        }

        fn exchange(alloc: Allocator, name: [:0]const u16, payload: []const u8) ![]u8 {
            const pipe = try connect(name);
            defer _ = win32.CloseHandle(pipe);
            const frame = try Protocol.encodeFrame(alloc, payload);
            defer alloc.free(frame);
            try writeAll(pipe, frame);

            return readFrame(alloc, pipe);
        }

        fn exchangeOversizedHeader(alloc: Allocator, name: [:0]const u16) ![]u8 {
            const pipe = try connect(name);
            defer _ = win32.CloseHandle(pipe);
            var header: [4]u8 = undefined;
            std.mem.writeInt(
                u32,
                &header,
                @intCast(Protocol.max_payload_size + 1),
                .little,
            );
            try writeAll(pipe, &header);
            return readFrame(alloc, pipe);
        }

        fn readFrame(alloc: Allocator, pipe: win32.HANDLE) ![]u8 {
            var header: [4]u8 = undefined;
            try readAll(pipe, &header);
            const response_len = try Protocol.frameLength(&header);
            const response = try alloc.alloc(u8, response_len);
            errdefer alloc.free(response);
            try readAll(pipe, response);
            return response;
        }
    };

    var channel_buf: [64]u8 = undefined;
    const channel = try std.fmt.bufPrint(
        &channel_buf,
        "test-server-{d}",
        .{win32.GetCurrentProcessId()},
    );
    var context: u8 = 0;
    const server = try Server.initWithChannel(
        testing.allocator,
        &context,
        Test.echo,
        channel,
    );
    defer server.deinit();

    for ([_][]const u8{ "first request", "second request" }) |expected| {
        const response = try Test.exchange(testing.allocator, server.listener.name, expected);
        defer testing.allocator.free(response);
        try testing.expectEqualStrings(expected, response);
    }

    const failure = try Test.exchange(
        testing.allocator,
        server.listener.name,
        "handler failure",
    );
    defer testing.allocator.free(failure);
    const decoded = try Protocol.decodeResponse(failure);
    try testing.expectEqual(Protocol.Status.internal_error, decoded.status);
    try testing.expectEqualStrings("IPC request failed", decoded.message);

    const oversized = try Test.exchangeOversizedHeader(
        testing.allocator,
        server.listener.name,
    );
    defer testing.allocator.free(oversized);
    const oversized_response = try Protocol.decodeResponse(oversized);
    try testing.expectEqual(Protocol.Status.invalid_request, oversized_response.status);

    const client_payload = try Protocol.encodeRequest(testing.allocator, .{
        .action = .new_tab,
        .surface_id = 42,
        .arguments = &.{"--title=client exchange"},
    });
    defer testing.allocator.free(client_payload);
    const client_response = try clientExchangeWithChannel(
        testing.allocator,
        client_payload,
        channel,
    );
    defer testing.allocator.free(client_response);
    try testing.expectEqualSlices(u8, client_payload, client_response);
}
