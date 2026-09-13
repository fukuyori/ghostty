//! D3D11 render-pass command binding and draw submission.
const Self = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const Pipeline = @import("Pipeline.zig");
const Target = @import("Target.zig");

context: *win32.ID3D11DeviceContext,

pub const Options = struct {
    context: *win32.ID3D11DeviceContext,
    target: *const Target,
    clear_color: ?[4]f32 = null,
};

pub fn init(opts: Options) Self {
    opts.target.bind(opts.context);
    if (opts.clear_color) |color| opts.target.clear(opts.context, color);
    return .{ .context = opts.context };
}

pub fn setPipeline(self: *const Self, pipeline: *const Pipeline) void {
    pipeline.bind(self.context);
}

pub fn setVertexBuffer(
    self: *const Self,
    buffer: *win32.ID3D11Buffer,
    stride: u32,
) void {
    var buffers = [_]?*win32.ID3D11Buffer{buffer};
    const strides = [_]u32{stride};
    const offsets = [_]u32{0};
    self.context.IASetVertexBuffers(0, 1, &buffers, &strides, &offsets);
}

pub fn setUniformBuffer(
    self: *const Self,
    slot: u32,
    buffer: *win32.ID3D11Buffer,
) void {
    var buffers = [_]?*win32.ID3D11Buffer{buffer};
    self.context.VSSetConstantBuffers(slot, 1, &buffers);
    self.context.PSSetConstantBuffers(slot, 1, &buffers);
}

pub fn setShaderResources(
    self: *const Self,
    slot: u32,
    resources: []?*win32.ID3D11ShaderResourceView,
) void {
    if (resources.len == 0) return;
    const count: u32 = @intCast(resources.len);
    self.context.VSSetShaderResources(slot, count, resources.ptr);
    self.context.PSSetShaderResources(slot, count, resources.ptr);
}

pub fn setSamplers(
    self: *const Self,
    slot: u32,
    samplers: []?*win32.ID3D11SamplerState,
) void {
    if (samplers.len == 0) return;
    const count: u32 = @intCast(samplers.len);
    self.context.VSSetSamplers(slot, count, samplers.ptr);
    self.context.PSSetSamplers(slot, count, samplers.ptr);
}

pub fn draw(
    self: *const Self,
    vertex_count: u32,
    instance_count: u32,
) void {
    self.context.DrawInstanced(vertex_count, instance_count, 0, 0);
}

pub fn complete(self: *const Self) void {
    var no_targets = [_]?*win32.ID3D11RenderTargetView{null};
    self.context.OMSetRenderTargets(0, &no_targets, null);
}

test "D3D11 render pass options allow transparent clearing" {
    const options: Options = .{
        .context = undefined,
        .target = undefined,
        .clear_color = .{ 0, 0, 0, 0 },
    };
    try std.testing.expectEqual(@as(f32, 0), options.clear_color.?[3]);
}
