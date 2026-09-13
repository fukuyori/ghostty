//! D3D11 render target used by the Windows renderer and compositor presenter.
const Self = @This();

const std = @import("std");
const win32 = @import("win32").everything;

const log = std.log.scoped(.d3d11_target);

texture: *win32.ID3D11Texture2D,
view: *win32.ID3D11RenderTargetView,
width: u32,
height: u32,
format: win32.DXGI_FORMAT,

pub const Error = error{
    CreateTexture,
    GetSwapChainBuffer,
    CreateRenderTarget,
    TargetSizeMismatch,
    TargetFormatMismatch,
};

/// Create an offscreen texture that can be rendered to and sampled by later
/// custom-shader passes.
pub fn init(
    device: *win32.ID3D11Device,
    width: u32,
    height: u32,
    format: win32.DXGI_FORMAT,
) Error!Self {
    const desc = textureDescription(width, height, format);
    var texture: *win32.ID3D11Texture2D = undefined;
    try check(
        device.CreateTexture2D(&desc, null, &texture),
        error.CreateTexture,
        "ID3D11Device.CreateTexture2D",
    );
    errdefer _ = texture.IUnknown.Release();

    return try fromTexture(device, texture, desc);
}

/// Acquire the current buffer of a composition swap chain as a render target.
pub fn fromSwapChain(
    device: *win32.ID3D11Device,
    swap_chain: *win32.IDXGISwapChain1,
) Error!Self {
    var texture_raw: *anyopaque = undefined;
    try check(
        swap_chain.IDXGISwapChain.GetBuffer(
            0,
            win32.IID_ID3D11Texture2D,
            &texture_raw,
        ),
        error.GetSwapChainBuffer,
        "IDXGISwapChain.GetBuffer",
    );
    const texture: *win32.ID3D11Texture2D = @ptrCast(@alignCast(texture_raw));
    errdefer _ = texture.IUnknown.Release();

    var desc: win32.D3D11_TEXTURE2D_DESC = undefined;
    texture.GetDesc(&desc);
    return try fromTexture(device, texture, desc);
}

pub fn deinit(self: *Self) void {
    _ = self.view.IUnknown.Release();
    _ = self.texture.IUnknown.Release();
}

/// Bind this target and its full-size viewport for subsequent draw calls.
pub fn bind(self: *const Self, context: *win32.ID3D11DeviceContext) void {
    var views = [_]?*win32.ID3D11RenderTargetView{self.view};
    context.OMSetRenderTargets(views.len, &views, null);

    const viewport: win32.D3D11_VIEWPORT = .{
        .TopLeftX = 0,
        .TopLeftY = 0,
        .Width = @floatFromInt(self.width),
        .Height = @floatFromInt(self.height),
        .MinDepth = 0,
        .MaxDepth = 1,
    };
    context.RSSetViewports(1, @ptrCast(&viewport));
}

/// Clear the target with an already-premultiplied RGBA color.
pub fn clear(
    self: *const Self,
    context: *win32.ID3D11DeviceContext,
    color: [4]f32,
) void {
    context.ClearRenderTargetView(self.view, &color[0]);
}

/// Copy the completed frame to a compatible destination without CPU readback.
pub fn copyTo(
    self: *const Self,
    context: *win32.ID3D11DeviceContext,
    destination: *const Self,
) Error!void {
    if (self.width != destination.width or self.height != destination.height) {
        return error.TargetSizeMismatch;
    }
    if (!compatibleFormats(self.format, destination.format)) {
        return error.TargetFormatMismatch;
    }

    context.CopyResource(
        @ptrCast(destination.texture),
        @ptrCast(self.texture),
    );
}

/// CopyResource permits typed formats from the same DXGI format family. The
/// renderer uses an sRGB view for linear blending and copies the encoded bytes
/// to DirectComposition's UNORM BGRA back buffer.
fn compatibleFormats(source: win32.DXGI_FORMAT, destination: win32.DXGI_FORMAT) bool {
    if (source == destination) return true;
    return (source == win32.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB and
        destination == win32.DXGI_FORMAT_B8G8R8A8_UNORM) or
        (source == win32.DXGI_FORMAT_B8G8R8A8_UNORM and
            destination == win32.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB);
}

fn fromTexture(
    device: *win32.ID3D11Device,
    texture: *win32.ID3D11Texture2D,
    desc: win32.D3D11_TEXTURE2D_DESC,
) Error!Self {
    var view: *win32.ID3D11RenderTargetView = undefined;
    try check(
        device.CreateRenderTargetView(
            @ptrCast(texture),
            null,
            &view,
        ),
        error.CreateRenderTarget,
        "ID3D11Device.CreateRenderTargetView",
    );

    return .{
        .texture = texture,
        .view = view,
        .width = desc.Width,
        .height = desc.Height,
        .format = desc.Format,
    };
}

fn textureDescription(
    width: u32,
    height: u32,
    format: win32.DXGI_FORMAT,
) win32.D3D11_TEXTURE2D_DESC {
    return .{
        .Width = @max(width, 1),
        .Height = @max(height, 1),
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = win32.D3D11_USAGE_DEFAULT,
        .BindFlags = .{
            .SHADER_RESOURCE = 1,
            .RENDER_TARGET = 1,
        },
        .CPUAccessFlags = .{},
        .MiscFlags = .{},
    };
}

fn check(result: win32.HRESULT, err: Error, operation: []const u8) Error!void {
    if (win32.SUCCEEDED(result)) return;
    log.err("{s} failed: hresult=0x{x}", .{
        operation,
        @as(u32, @bitCast(result)),
    });
    return err;
}

test "D3D11 target description clamps dimensions and enables shader input" {
    const testing = std.testing;
    const desc = textureDescription(0, 0, win32.DXGI_FORMAT_B8G8R8A8_UNORM);

    try testing.expectEqual(@as(u32, 1), desc.Width);
    try testing.expectEqual(@as(u32, 1), desc.Height);
    try testing.expectEqual(@as(u1, 1), desc.BindFlags.RENDER_TARGET);
    try testing.expectEqual(@as(u1, 1), desc.BindFlags.SHADER_RESOURCE);
}

test "D3D11 target accepts BGRA UNORM and sRGB copies" {
    try std.testing.expect(compatibleFormats(
        win32.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
        win32.DXGI_FORMAT_B8G8R8A8_UNORM,
    ));
    try std.testing.expect(!compatibleFormats(
        win32.DXGI_FORMAT_R8G8B8A8_UNORM,
        win32.DXGI_FORMAT_B8G8R8A8_UNORM,
    ));
}
