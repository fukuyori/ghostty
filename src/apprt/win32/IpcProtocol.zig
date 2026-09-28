const std = @import("std");
const Allocator = std.mem.Allocator;

pub const magic = "GHTYIPC1";
pub const version: u16 = 1;
pub const max_payload_size: usize = 64 * 1024;
pub const max_arguments: usize = 1024;

pub const Action = enum(u16) {
    new_tab = 1,
};

pub const Status = enum(u16) {
    success = 0,
    target_fallback = 1,
    invalid_request = 2,
    unsupported_version = 3,
    internal_error = 4,
    timeout = 5,
};

pub const Request = struct {
    action: Action,
    surface_id: u64,
    arguments: []const [:0]const u8,
};

pub const Response = struct {
    protocol_version: u16,
    status: Status,
    status_code: u16,
    message: []const u8,
};

pub const ResponsePayload = struct {
    protocol_version: u16 = version,
    status: Status,
    message: []const u8,
};

pub const DecodeError = error{
    InvalidMagic,
    UnsupportedVersion,
    InvalidAction,
    InvalidLength,
    TooManyArguments,
    PayloadTooLarge,
    TrailingData,
    InvalidUtf8,
    EmbeddedNul,
};

/// Add the byte-stream transport header. The length excludes the u32 header.
pub fn encodeFrame(alloc: Allocator, payload: []const u8) ![]u8 {
    if (payload.len > max_payload_size) return error.PayloadTooLarge;
    var result = try alloc.alloc(u8, @sizeOf(u32) + payload.len);
    errdefer alloc.free(result);
    std.mem.writeInt(u32, result[0..4], @intCast(payload.len), .little);
    @memcpy(result[4..], payload);
    return result;
}

/// Decode and validate the payload length from a byte-stream frame header.
pub fn frameLength(header: *const [@sizeOf(u32)]u8) !u32 {
    const payload_len = std.mem.readInt(u32, header, .little);
    if (payload_len > max_payload_size) return error.PayloadTooLarge;
    return payload_len;
}

/// Validate and return one complete byte-stream frame.
pub fn decodeFrame(frame: []const u8) ![]const u8 {
    if (frame.len < @sizeOf(u32)) return error.InvalidLength;
    const header: *const [@sizeOf(u32)]u8 = @ptrCast(frame[0..4]);
    const payload_len = try frameLength(header);
    if (payload_len > frame.len - 4) return error.InvalidLength;
    if (payload_len != frame.len - 4) return error.TrailingData;
    return frame[4..];
}

pub fn encodeRequest(alloc: Allocator, request: Request) ![]u8 {
    if (request.arguments.len > max_arguments) return error.TooManyArguments;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);
    try result.appendSlice(alloc, magic);
    try appendInt(u16, alloc, &result, version);
    try appendInt(u16, alloc, &result, @intFromEnum(request.action));
    try appendInt(u64, alloc, &result, request.surface_id);
    try appendInt(u32, alloc, &result, @intCast(request.arguments.len));
    for (request.arguments) |argument| {
        if (argument.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
        try appendInt(u32, alloc, &result, @intCast(argument.len));
        try result.appendSlice(alloc, argument);
        if (result.items.len > max_payload_size) return error.PayloadTooLarge;
    }
    return result.toOwnedSlice(alloc);
}

pub fn decodeRequest(arena_alloc: Allocator, payload: []const u8) !Request {
    if (payload.len > max_payload_size) return error.PayloadTooLarge;
    var cursor: usize = 0;
    if (payload.len < magic.len or !std.mem.eql(u8, payload[0..magic.len], magic))
        return error.InvalidMagic;
    cursor += magic.len;

    const request_version = try readInt(u16, payload, &cursor);
    if (request_version != version) return error.UnsupportedVersion;
    const action = parseAction(try readInt(u16, payload, &cursor)) orelse
        return error.InvalidAction;
    const surface_id = try readInt(u64, payload, &cursor);
    const argument_count = try readInt(u32, payload, &cursor);
    if (argument_count > max_arguments) return error.TooManyArguments;

    const arguments = try arena_alloc.alloc([:0]const u8, argument_count);
    for (arguments) |*argument| {
        const len = try readInt(u32, payload, &cursor);
        if (len > payload.len - cursor) return error.InvalidLength;
        const value = payload[cursor .. cursor + len];
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.EmbeddedNul;
        argument.* = try arena_alloc.dupeZ(u8, value);
        cursor += len;
    }
    if (cursor != payload.len) return error.TrailingData;
    return .{
        .action = action,
        .surface_id = surface_id,
        .arguments = arguments,
    };
}

pub fn encodeResponse(alloc: Allocator, response: ResponsePayload) ![]u8 {
    if (response.message.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);
    try appendInt(u16, alloc, &result, response.protocol_version);
    try appendInt(u16, alloc, &result, @intFromEnum(response.status));
    try appendInt(u32, alloc, &result, @intCast(response.message.len));
    try result.appendSlice(alloc, response.message);
    if (result.items.len > max_payload_size) return error.PayloadTooLarge;
    return result.toOwnedSlice(alloc);
}

pub fn decodeResponse(payload: []const u8) !Response {
    if (payload.len > max_payload_size) return error.PayloadTooLarge;
    var cursor: usize = 0;
    const response_version = try readInt(u16, payload, &cursor);
    const status_code = try readInt(u16, payload, &cursor);
    const status = parseStatus(status_code) orelse .internal_error;
    const len = try readInt(u32, payload, &cursor);
    if (len > payload.len - cursor) return error.InvalidLength;
    const message = payload[cursor .. cursor + len];
    cursor += len;
    if (cursor != payload.len) return error.TrailingData;
    return .{
        .protocol_version = response_version,
        .status = status,
        .status_code = status_code,
        .message = message,
    };
}

fn appendInt(
    comptime T: type,
    alloc: Allocator,
    result: *std.ArrayList(u8),
    value: T,
) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try result.appendSlice(alloc, &bytes);
}

fn readInt(comptime T: type, payload: []const u8, cursor: *usize) !T {
    if (@sizeOf(T) > payload.len - cursor.*) return error.InvalidLength;
    const bytes: *const [@sizeOf(T)]u8 = @ptrCast(payload[cursor.*..][0..@sizeOf(T)]);
    cursor.* += @sizeOf(T);
    return std.mem.readInt(T, bytes, .little);
}

fn parseAction(value: u16) ?Action {
    return switch (value) {
        @intFromEnum(Action.new_tab) => .new_tab,
        else => null,
    };
}

fn parseStatus(value: u16) ?Status {
    return switch (value) {
        @intFromEnum(Status.success) => .success,
        @intFromEnum(Status.target_fallback) => .target_fallback,
        @intFromEnum(Status.invalid_request) => .invalid_request,
        @intFromEnum(Status.unsupported_version) => .unsupported_version,
        @intFromEnum(Status.internal_error) => .internal_error,
        @intFromEnum(Status.timeout) => .timeout,
        else => null,
    };
}

test "Win32 IPC request round trip" {
    const testing = std.testing;
    const encoded = try encodeRequest(testing.allocator, .{
        .action = .new_tab,
        .surface_id = 0x1234,
        .arguments = &.{ "--title=IPC tab", "-e", "cmd.exe", "/c", "echo ok" },
    });
    defer testing.allocator.free(encoded);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const decoded = try decodeRequest(arena.allocator(), encoded);
    try testing.expectEqual(Action.new_tab, decoded.action);
    try testing.expectEqual(@as(u64, 0x1234), decoded.surface_id);
    try testing.expectEqual(@as(usize, 5), decoded.arguments.len);
    try testing.expectEqualStrings("--title=IPC tab", decoded.arguments[0]);
    try testing.expectEqualStrings("echo ok", decoded.arguments[4]);
}

test "Win32 IPC byte-stream frame round trip and boundaries" {
    const testing = std.testing;
    const frame = try encodeFrame(testing.allocator, "payload");
    defer testing.allocator.free(frame);
    try testing.expectEqualStrings("payload", try decodeFrame(frame));
    const header: *const [4]u8 = @ptrCast(frame[0..4]);
    try testing.expectEqual(@as(u32, 7), try frameLength(header));
    try testing.expectError(error.InvalidLength, decodeFrame(frame[0..3]));

    var truncated = [_]u8{ 5, 0, 0, 0, 'a' };
    try testing.expectError(error.InvalidLength, decodeFrame(&truncated));
    var trailing = [_]u8{ 1, 0, 0, 0, 'a', 'b' };
    try testing.expectError(error.TrailingData, decodeFrame(&trailing));
    var oversized = [_]u8{ 1, 0, 1, 0 };
    try testing.expectError(error.PayloadTooLarge, frameLength(&oversized));
    try testing.expectError(error.PayloadTooLarge, decodeFrame(&oversized));
}

test "Win32 IPC rejects invalid request boundaries" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.InvalidMagic, decodeRequest(arena.allocator(), "bad"));

    var too_many: [max_arguments + 1][:0]const u8 = @splat("");
    try testing.expectError(error.TooManyArguments, encodeRequest(testing.allocator, .{
        .action = .new_tab,
        .surface_id = 0,
        .arguments = &too_many,
    }));

    const valid = try encodeRequest(testing.allocator, .{
        .action = .new_tab,
        .surface_id = 0,
        .arguments = &.{"x"},
    });
    defer testing.allocator.free(valid);

    var unsupported_version = try testing.allocator.dupe(u8, valid);
    defer testing.allocator.free(unsupported_version);
    std.mem.writeInt(u16, unsupported_version[8..10], version + 1, .little);
    try testing.expectError(
        error.UnsupportedVersion,
        decodeRequest(arena.allocator(), unsupported_version),
    );

    var invalid_action = try testing.allocator.dupe(u8, valid);
    defer testing.allocator.free(invalid_action);
    std.mem.writeInt(u16, invalid_action[10..12], 0xFFFF, .little);
    try testing.expectError(
        error.InvalidAction,
        decodeRequest(arena.allocator(), invalid_action),
    );

    try testing.expectError(
        error.InvalidLength,
        decodeRequest(arena.allocator(), valid[0..9]),
    );

    var invalid_argument_length = try testing.allocator.dupe(u8, valid);
    defer testing.allocator.free(invalid_argument_length);
    std.mem.writeInt(u32, invalid_argument_length[24..28], 2, .little);
    try testing.expectError(
        error.InvalidLength,
        decodeRequest(arena.allocator(), invalid_argument_length),
    );

    const with_trailing = try std.mem.concat(testing.allocator, u8, &.{ valid, "x" });
    defer testing.allocator.free(with_trailing);
    try testing.expectError(
        error.TrailingData,
        decodeRequest(arena.allocator(), with_trailing),
    );

    var too_many_wire = try testing.allocator.dupe(u8, valid);
    defer testing.allocator.free(too_many_wire);
    std.mem.writeInt(u32, too_many_wire[20..24], max_arguments + 1, .little);
    try testing.expectError(
        error.TooManyArguments,
        decodeRequest(arena.allocator(), too_many_wire),
    );

    const oversized_payload = try testing.allocator.alloc(u8, max_payload_size + 1);
    defer testing.allocator.free(oversized_payload);
    try testing.expectError(
        error.PayloadTooLarge,
        decodeRequest(arena.allocator(), oversized_payload),
    );
}

test "Win32 IPC rejects invalid argument strings" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const invalid_utf8 = try encodeRequest(testing.allocator, .{
        .action = .new_tab,
        .surface_id = 0,
        .arguments = &.{"\xff"},
    });
    defer testing.allocator.free(invalid_utf8);
    try testing.expectError(
        error.InvalidUtf8,
        decodeRequest(arena.allocator(), invalid_utf8),
    );

    const embedded_nul = try encodeRequest(testing.allocator, .{
        .action = .new_tab,
        .surface_id = 0,
        .arguments = &.{"a\x00b"},
    });
    defer testing.allocator.free(embedded_nul);
    try testing.expectError(
        error.EmbeddedNul,
        decodeRequest(arena.allocator(), embedded_nul),
    );
}

test "Win32 IPC response round trip" {
    const testing = std.testing;
    const encoded = try encodeResponse(testing.allocator, .{
        .status = .target_fallback,
        .message = "focused surface used",
    });
    defer testing.allocator.free(encoded);
    const decoded = try decodeResponse(encoded);
    try testing.expectEqual(Status.target_fallback, decoded.status);
    try testing.expectEqual(@intFromEnum(Status.target_fallback), decoded.status_code);
    try testing.expectEqualStrings("focused surface used", decoded.message);
}

test "Win32 IPC response parses fixed header across versions" {
    const testing = std.testing;
    const encoded = try encodeResponse(testing.allocator, .{
        .protocol_version = version + 1,
        .status = .unsupported_version,
        .message = "unsupported protocol version",
    });
    defer testing.allocator.free(encoded);
    const decoded = try decodeResponse(encoded);
    try testing.expectEqual(version + 1, decoded.protocol_version);
    try testing.expectEqual(Status.unsupported_version, decoded.status);
    try testing.expectEqualStrings("unsupported protocol version", decoded.message);

    var unknown_status = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(unknown_status);
    std.mem.writeInt(u16, unknown_status[2..4], 0xFFFF, .little);
    const unknown = try decodeResponse(unknown_status);
    try testing.expectEqual(Status.internal_error, unknown.status);
    try testing.expectEqual(@as(u16, 0xFFFF), unknown.status_code);
    try testing.expectEqualStrings("unsupported protocol version", unknown.message);
    try testing.expectError(error.InvalidLength, decodeResponse(encoded[0..5]));

    const trailing = try std.mem.concat(testing.allocator, u8, &.{ encoded, "x" });
    defer testing.allocator.free(trailing);
    try testing.expectError(error.TrailingData, decodeResponse(trailing));
}
