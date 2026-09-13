//! D3D11 shader and fixed-function pipeline state.
const Self = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const Shader = @import("Shader.zig");

const log = std.log.scoped(.d3d11_pipeline);

pub const Options = struct {
    device: *win32.ID3D11Device,
    vertex_source: []const u8,
    pixel_source: []const u8,
    vertex_entrypoint: [:0]const u8 = "main",
    pixel_entrypoint: [:0]const u8 = "main",
    blending: bool = true,
    topology: win32.D3D_PRIMITIVE_TOPOLOGY =
        win32.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
};

pub const Error = Shader.Error || error{
    CreateVertexShader,
    CreatePixelShader,
    CreateBlendState,
};

vertex_shader: *win32.ID3D11VertexShader,
pixel_shader: *win32.ID3D11PixelShader,
blend_state: *win32.ID3D11BlendState,
topology: win32.D3D_PRIMITIVE_TOPOLOGY,

pub fn init(opts: Options) Error!Self {
    const vertex_code = try Shader.compile(
        opts.vertex_source,
        opts.vertex_entrypoint,
        .vertex,
    );
    defer vertex_code.deinit();
    const pixel_code = try Shader.compile(
        opts.pixel_source,
        opts.pixel_entrypoint,
        .pixel,
    );
    defer pixel_code.deinit();

    const vertex_bytes = vertex_code.bytes();
    var vertex_shader: *win32.ID3D11VertexShader = undefined;
    try check(
        opts.device.CreateVertexShader(
            vertex_bytes.ptr,
            vertex_bytes.len,
            null,
            &vertex_shader,
        ),
        error.CreateVertexShader,
        "ID3D11Device.CreateVertexShader",
    );
    errdefer _ = vertex_shader.IUnknown.Release();

    const pixel_bytes = pixel_code.bytes();
    var pixel_shader: *win32.ID3D11PixelShader = undefined;
    try check(
        opts.device.CreatePixelShader(
            pixel_bytes.ptr,
            pixel_bytes.len,
            null,
            &pixel_shader,
        ),
        error.CreatePixelShader,
        "ID3D11Device.CreatePixelShader",
    );
    errdefer _ = pixel_shader.IUnknown.Release();

    const blend_desc = blendDescription(opts.blending);
    var blend_state: *win32.ID3D11BlendState = undefined;
    try check(
        opts.device.CreateBlendState(&blend_desc, &blend_state),
        error.CreateBlendState,
        "ID3D11Device.CreateBlendState",
    );

    return .{
        .vertex_shader = vertex_shader,
        .pixel_shader = pixel_shader,
        .blend_state = blend_state,
        .topology = opts.topology,
    };
}

pub fn deinit(self: Self) void {
    _ = self.blend_state.IUnknown.Release();
    _ = self.pixel_shader.IUnknown.Release();
    _ = self.vertex_shader.IUnknown.Release();
}

pub fn bind(self: *const Self, context: *win32.ID3D11DeviceContext) void {
    context.IASetInputLayout(null);
    context.IASetPrimitiveTopology(self.topology);
    context.VSSetShader(self.vertex_shader, null, 0);
    context.PSSetShader(self.pixel_shader, null, 0);

    const blend_factor = [_]f32{ 0, 0, 0, 0 };
    context.OMSetBlendState(self.blend_state, &blend_factor[0], std.math.maxInt(u32));
}

fn blendDescription(enabled: bool) win32.D3D11_BLEND_DESC {
    var desc = std.mem.zeroes(win32.D3D11_BLEND_DESC);
    desc.RenderTarget[0] = .{
        .BlendEnable = @intFromBool(enabled),
        .SrcBlend = win32.D3D11_BLEND_ONE,
        .DestBlend = win32.D3D11_BLEND_INV_SRC_ALPHA,
        .BlendOp = win32.D3D11_BLEND_OP_ADD,
        .SrcBlendAlpha = win32.D3D11_BLEND_ONE,
        .DestBlendAlpha = win32.D3D11_BLEND_INV_SRC_ALPHA,
        .BlendOpAlpha = win32.D3D11_BLEND_OP_ADD,
        .RenderTargetWriteMask = @intFromEnum(win32.D3D11_COLOR_WRITE_ENABLE_ALL),
    };
    return desc;
}

fn check(result: win32.HRESULT, err: Error, operation: []const u8) Error!void {
    if (win32.SUCCEEDED(result)) return;
    log.err("{s} failed: hresult=0x{x}", .{
        operation,
        @as(u32, @bitCast(result)),
    });
    return err;
}

test "D3D11 pipeline uses premultiplied alpha blending" {
    const desc = blendDescription(true);
    const target = desc.RenderTarget[0];
    try std.testing.expect(target.BlendEnable != 0);
    try std.testing.expectEqual(win32.D3D11_BLEND_ONE, target.SrcBlend);
    try std.testing.expectEqual(win32.D3D11_BLEND_INV_SRC_ALPHA, target.DestBlend);
    try std.testing.expectEqual(win32.D3D11_BLEND_ONE, target.SrcBlendAlpha);
    try std.testing.expectEqual(win32.D3D11_BLEND_INV_SRC_ALPHA, target.DestBlendAlpha);
}
