//! Dynamically updated D3D11 buffer storage.

const std = @import("std");
const win32 = @import("win32").everything;

const log = std.log.scoped(.d3d11_buffer);

pub const Options = struct {
    device: *win32.ID3D11Device,
    context: *win32.ID3D11DeviceContext,
    bind_flags: win32.D3D11_BIND_FLAG,
    structured: bool = false,
};

pub const Error = error{
    BufferTooLarge,
    CreateBuffer,
    CreateShaderView,
    MapBuffer,
};

const Allocation = struct {
    buffer: *win32.ID3D11Buffer,
    shader_view: ?*win32.ID3D11ShaderResourceView,
};

pub fn Buffer(comptime T: type) type {
    if (@sizeOf(T) == 0) @compileError("D3D11 buffers cannot store zero-sized types");

    return struct {
        const Self = @This();

        opts: Options,
        buffer: *win32.ID3D11Buffer,
        shader_view: ?*win32.ID3D11ShaderResourceView,
        /// Allocated number of T elements.
        len: usize,

        pub fn init(opts: Options, len: usize) Error!Self {
            const allocation = try createAllocation(opts, T, len);
            return .{
                .opts = opts,
                .buffer = allocation.buffer,
                .shader_view = allocation.shader_view,
                .len = len,
            };
        }

        pub fn initFill(opts: Options, data: []const T) Error!Self {
            var self = try init(opts, data.len);
            errdefer self.deinit();
            try self.sync(data);
            return self;
        }

        pub fn deinit(self: *const Self) void {
            if (self.shader_view) |view| _ = view.IUnknown.Release();
            _ = self.buffer.IUnknown.Release();
        }

        pub fn sync(self: *Self, data: []const T) Error!void {
            if (data.len == 0) return;
            try self.ensureCapacity(data.len);
            try upload(self.opts.context, self.buffer, std.mem.sliceAsBytes(data));
        }

        pub fn syncFromArrayLists(
            self: *Self,
            lists: []const std.ArrayListUnmanaged(T),
        ) Error!usize {
            var total_len: usize = 0;
            for (lists) |list| {
                total_len = std.math.add(usize, total_len, list.items.len) catch
                    return error.BufferTooLarge;
            }
            if (total_len == 0) return 0;

            try self.ensureCapacity(total_len);

            var mapped: win32.D3D11_MAPPED_SUBRESOURCE = undefined;
            try check(
                self.opts.context.Map(
                    @ptrCast(self.buffer),
                    0,
                    win32.D3D11_MAP_WRITE_DISCARD,
                    0,
                    &mapped,
                ),
                error.MapBuffer,
                "ID3D11DeviceContext.Map",
            );
            defer self.opts.context.Unmap(@ptrCast(self.buffer), 0);

            const destination: [*]u8 = @ptrCast(mapped.pData orelse
                return error.MapBuffer);
            var offset: usize = 0;
            for (lists) |list| {
                const bytes = std.mem.sliceAsBytes(list.items);
                @memcpy(destination[offset..][0..bytes.len], bytes);
                offset += bytes.len;
            }
            return total_len;
        }

        fn ensureCapacity(self: *Self, required: usize) Error!void {
            if (required <= self.len) return;
            const new_len = std.math.mul(usize, required, 2) catch
                return error.BufferTooLarge;
            const replacement = try createAllocation(self.opts, T, new_len);
            if (self.shader_view) |view| _ = view.IUnknown.Release();
            _ = self.buffer.IUnknown.Release();
            self.buffer = replacement.buffer;
            self.shader_view = replacement.shader_view;
            self.len = new_len;
        }
    };
}

fn createAllocation(
    opts: Options,
    comptime T: type,
    len: usize,
) Error!Allocation {
    const byte_width = try bufferByteWidth(
        @sizeOf(T),
        len,
        opts.bind_flags.CONSTANT_BUFFER != 0,
    );

    const desc: win32.D3D11_BUFFER_DESC = .{
        .ByteWidth = byte_width,
        .Usage = win32.D3D11_USAGE_DYNAMIC,
        .BindFlags = opts.bind_flags,
        .CPUAccessFlags = .{ .WRITE = 1 },
        .MiscFlags = if (opts.structured)
            .{ .BUFFER_STRUCTURED = 1 }
        else
            .{},
        .StructureByteStride = if (opts.structured) @sizeOf(T) else 0,
    };
    var buffer: *win32.ID3D11Buffer = undefined;
    try check(
        opts.device.CreateBuffer(&desc, null, &buffer),
        error.CreateBuffer,
        "ID3D11Device.CreateBuffer",
    );
    errdefer _ = buffer.IUnknown.Release();

    var shader_view: ?*win32.ID3D11ShaderResourceView = null;
    if (opts.structured) {
        const element_count = std.math.cast(u32, @max(len, 1)) orelse
            return error.BufferTooLarge;
        const view_desc: win32.D3D11_SHADER_RESOURCE_VIEW_DESC = .{
            .Format = win32.DXGI_FORMAT_UNKNOWN,
            .ViewDimension = win32.D3D_SRV_DIMENSION_BUFFER,
            .Anonymous = .{ .Buffer = .{
                .Anonymous1 = .{ .FirstElement = 0 },
                .Anonymous2 = .{ .NumElements = element_count },
            } },
        };
        var view: *win32.ID3D11ShaderResourceView = undefined;
        try check(
            opts.device.CreateShaderResourceView(
                @ptrCast(buffer),
                &view_desc,
                &view,
            ),
            error.CreateShaderView,
            "ID3D11Device.CreateShaderResourceView",
        );
        shader_view = view;
    }

    return .{ .buffer = buffer, .shader_view = shader_view };
}

fn bufferByteWidth(
    element_size: usize,
    len: usize,
    constant: bool,
) Error!u32 {
    const element_bytes = std.math.mul(usize, len, element_size) catch
        return error.BufferTooLarge;
    var byte_width = @max(element_bytes, element_size);
    if (constant) byte_width = std.mem.alignForward(usize, byte_width, 16);
    return std.math.cast(u32, byte_width) orelse error.BufferTooLarge;
}

fn upload(
    context: *win32.ID3D11DeviceContext,
    buffer: *win32.ID3D11Buffer,
    data: []const u8,
) Error!void {
    var mapped: win32.D3D11_MAPPED_SUBRESOURCE = undefined;
    try check(
        context.Map(
            @ptrCast(buffer),
            0,
            win32.D3D11_MAP_WRITE_DISCARD,
            0,
            &mapped,
        ),
        error.MapBuffer,
        "ID3D11DeviceContext.Map",
    );
    defer context.Unmap(@ptrCast(buffer), 0);

    const destination: [*]u8 = @ptrCast(mapped.pData orelse
        return error.MapBuffer);
    @memcpy(destination[0..data.len], data);
}

fn check(result: win32.HRESULT, err: Error, operation: []const u8) Error!void {
    if (win32.SUCCEEDED(result)) return;
    log.err("{s} failed: hresult=0x{x}", .{
        operation,
        @as(u32, @bitCast(result)),
    });
    return err;
}

test "D3D11 constant buffer sizes are aligned" {
    try std.testing.expectEqual(@as(u32, 12), try bufferByteWidth(4, 3, false));
    try std.testing.expectEqual(@as(u32, 16), try bufferByteWidth(4, 3, true));
    try std.testing.expectEqual(@as(u32, 32), try bufferByteWidth(4, 5, true));
}
