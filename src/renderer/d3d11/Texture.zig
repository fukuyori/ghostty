//! D3D11 texture with shader-resource and optional render-target views.
const Self = @This();

const std = @import("std");
const win32 = @import("win32").everything;

const log = std.log.scoped(.d3d11_texture);

pub const Options = struct {
    device: *win32.ID3D11Device,
    context: *win32.ID3D11DeviceContext,
    format: win32.DXGI_FORMAT,
    render_target: bool = false,
};

texture: *win32.ID3D11Texture2D,
shader_view: *win32.ID3D11ShaderResourceView,
render_view: ?*win32.ID3D11RenderTargetView,
opts: Options,
width: u32,
height: u32,
bpp: u32,

pub const Error = error{
    UnsupportedFormat,
    InvalidDimensions,
    InvalidRegion,
    DataLengthMismatch,
    CreateTexture,
    CreateShaderView,
    CreateRenderTarget,
};

pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    const width_u32 = std.math.cast(u32, width) orelse
        return error.InvalidDimensions;
    const height_u32 = std.math.cast(u32, height) orelse
        return error.InvalidDimensions;
    if (width_u32 == 0 or height_u32 == 0) return error.InvalidDimensions;
    const bpp = try bytesPerPixel(opts.format);
    const expected_len = pixelByteLength(width, height, bpp) catch
        return error.InvalidDimensions;
    const row_pitch = std.math.mul(u32, width_u32, bpp) catch
        return error.InvalidDimensions;
    if (data) |bytes| {
        if (bytes.len != expected_len) return error.DataLengthMismatch;
    }

    const desc: win32.D3D11_TEXTURE2D_DESC = .{
        .Width = width_u32,
        .Height = height_u32,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = opts.format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = win32.D3D11_USAGE_DEFAULT,
        .BindFlags = .{
            .SHADER_RESOURCE = 1,
            .RENDER_TARGET = @intFromBool(opts.render_target),
        },
        .CPUAccessFlags = .{},
        .MiscFlags = .{},
    };
    const initial_data: win32.D3D11_SUBRESOURCE_DATA = .{
        .pSysMem = if (data) |bytes| bytes.ptr else null,
        .SysMemPitch = row_pitch,
        .SysMemSlicePitch = 0,
    };
    var texture: *win32.ID3D11Texture2D = undefined;
    try check(
        opts.device.CreateTexture2D(
            &desc,
            if (data != null) &initial_data else null,
            &texture,
        ),
        error.CreateTexture,
        "ID3D11Device.CreateTexture2D",
    );
    errdefer _ = texture.IUnknown.Release();

    var shader_view: *win32.ID3D11ShaderResourceView = undefined;
    try check(
        opts.device.CreateShaderResourceView(
            @ptrCast(texture),
            null,
            &shader_view,
        ),
        error.CreateShaderView,
        "ID3D11Device.CreateShaderResourceView",
    );
    errdefer _ = shader_view.IUnknown.Release();

    var render_view: ?*win32.ID3D11RenderTargetView = null;
    if (opts.render_target) {
        var view: *win32.ID3D11RenderTargetView = undefined;
        try check(
            opts.device.CreateRenderTargetView(
                @ptrCast(texture),
                null,
                &view,
            ),
            error.CreateRenderTarget,
            "ID3D11Device.CreateRenderTargetView",
        );
        render_view = view;
    }

    return .{
        .texture = texture,
        .shader_view = shader_view,
        .render_view = render_view,
        .opts = opts,
        .width = width_u32,
        .height = height_u32,
        .bpp = bpp,
    };
}

pub fn deinit(self: Self) void {
    if (self.render_view) |view| _ = view.IUnknown.Release();
    _ = self.shader_view.IUnknown.Release();
    _ = self.texture.IUnknown.Release();
}

pub fn replaceRegion(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) Error!void {
    const right = std.math.add(usize, x, width) catch
        return error.InvalidRegion;
    const bottom = std.math.add(usize, y, height) catch
        return error.InvalidRegion;
    if (right > self.width or bottom > self.height) return error.InvalidRegion;

    const expected_len = pixelByteLength(width, height, self.bpp) catch
        return error.InvalidRegion;
    if (data.len != expected_len) return error.DataLengthMismatch;
    if (width == 0 or height == 0) return;
    const row_pitch = std.math.cast(
        u32,
        pixelByteLength(width, 1, self.bpp) catch return error.InvalidRegion,
    ) orelse return error.InvalidRegion;

    const box: win32.D3D11_BOX = .{
        .left = @intCast(x),
        .top = @intCast(y),
        .front = 0,
        .right = @intCast(right),
        .bottom = @intCast(bottom),
        .back = 1,
    };
    self.opts.context.UpdateSubresource(
        @ptrCast(self.texture),
        0,
        &box,
        data.ptr,
        row_pitch,
        0,
    );
}

fn bytesPerPixel(format: win32.DXGI_FORMAT) Error!u32 {
    return switch (format) {
        win32.DXGI_FORMAT_R8_UNORM => 1,
        win32.DXGI_FORMAT_R8G8B8A8_UNORM,
        win32.DXGI_FORMAT_B8G8R8A8_UNORM,
        => 4,
        else => error.UnsupportedFormat,
    };
}

fn pixelByteLength(width: usize, height: usize, bpp: u32) !usize {
    const pixels = try std.math.mul(usize, width, height);
    return try std.math.mul(usize, pixels, bpp);
}

fn check(result: win32.HRESULT, err: Error, operation: []const u8) Error!void {
    if (win32.SUCCEEDED(result)) return;
    log.err("{s} failed: hresult=0x{x}", .{
        operation,
        @as(u32, @bitCast(result)),
    });
    return err;
}

test "D3D11 texture format sizes" {
    try std.testing.expectEqual(@as(u32, 1), try bytesPerPixel(win32.DXGI_FORMAT_R8_UNORM));
    try std.testing.expectEqual(@as(u32, 4), try bytesPerPixel(win32.DXGI_FORMAT_B8G8R8A8_UNORM));
    try std.testing.expectError(error.UnsupportedFormat, bytesPerPixel(win32.DXGI_FORMAT_UNKNOWN));
}
