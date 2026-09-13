//! D3D11 render-pass command binding and draw submission.
const Self = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const BufferBinding = @import("buffer.zig").Binding;
const Pipeline = @import("Pipeline.zig");
const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");

pub const Options = struct {
    attachments: []const Attachment,

    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?BufferBinding = null,
    buffers: []const ?BufferBinding = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,

    pub const Draw = struct {
        type: Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };

    pub const Primitive = enum {
        triangle,
        triangle_strip,
    };
};

context: *win32.ID3D11DeviceContext,
default_sampler: ?*win32.ID3D11SamplerState,
attachments: []const Options.Attachment,
step_number: usize = 0,

pub fn begin(
    context: *win32.ID3D11DeviceContext,
    default_sampler: ?*win32.ID3D11SamplerState,
    opts: Options,
) Self {
    return .{
        .context = context,
        .default_sampler = default_sampler,
        .attachments = opts.attachments,
    };
}

/// Convenience entry point retained for the native integration test.
pub fn init(opts: struct {
    context: *win32.ID3D11DeviceContext,
    target: *const Target,
    clear_color: ?[4]f32 = null,
}) Self {
    opts.target.bind(opts.context);
    if (opts.clear_color) |color| opts.target.clear(opts.context, color);
    return .{
        .context = opts.context,
        .default_sampler = null,
        .attachments = &.{},
        .step_number = 1,
    };
}

pub fn setPipeline(self: *const Self, pipeline: *const Pipeline) void {
    pipeline.bind(self.context);
}

pub fn setVertexBuffer(self: *const Self, buffer: *win32.ID3D11Buffer, stride: u32) void {
    var buffers = [_]?*win32.ID3D11Buffer{buffer};
    const strides = [_]u32{stride};
    const offsets = [_]u32{0};
    self.context.IASetVertexBuffers(0, 1, &buffers, &strides, &offsets);
}

pub fn setUniformBuffer(self: *const Self, slot: u32, buffer: *win32.ID3D11Buffer) void {
    var buffers = [_]?*win32.ID3D11Buffer{buffer};
    self.context.VSSetConstantBuffers(slot, 1, &buffers);
    self.context.PSSetConstantBuffers(slot, 1, &buffers);
}

pub fn setShaderResources(self: *const Self, slot: u32, resources: []?*win32.ID3D11ShaderResourceView) void {
    if (resources.len == 0) return;
    const count: u32 = @intCast(resources.len);
    self.context.VSSetShaderResources(slot, count, resources.ptr);
    self.context.PSSetShaderResources(slot, count, resources.ptr);
}

pub fn setVertexShaderResources(self: *const Self, slot: u32, resources: []?*win32.ID3D11ShaderResourceView) void {
    if (resources.len == 0) return;
    self.context.VSSetShaderResources(slot, @intCast(resources.len), resources.ptr);
}

pub fn setPixelShaderResources(self: *const Self, slot: u32, resources: []?*win32.ID3D11ShaderResourceView) void {
    if (resources.len == 0) return;
    self.context.PSSetShaderResources(slot, @intCast(resources.len), resources.ptr);
}

pub fn setSamplers(self: *const Self, slot: u32, samplers: []?*win32.ID3D11SamplerState) void {
    if (samplers.len == 0) return;
    const count: u32 = @intCast(samplers.len);
    self.context.VSSetSamplers(slot, count, samplers.ptr);
    self.context.PSSetSamplers(slot, count, samplers.ptr);
}

pub fn setPixelSamplers(self: *const Self, slot: u32, samplers: []?*win32.ID3D11SamplerState) void {
    if (samplers.len == 0) return;
    self.context.PSSetSamplers(slot, @intCast(samplers.len), samplers.ptr);
}

pub fn draw(self: *const Self, vertex_count: u32, instance_count: u32) void {
    self.context.DrawInstanced(vertex_count, instance_count, 0, 0);
}

/// Add one generic-renderer step to this pass.
pub fn step(self: *Self, command: Step) void {
    if (command.draw.instance_count == 0 or self.attachments.len == 0) return;

    const attachment = self.attachments[0];
    switch (attachment.target) {
        .target => |target| target.bind(self.context),
        .texture => |texture| texture.bindAsTarget(self.context) catch return,
    }

    defer self.step_number += 1;
    if (self.step_number == 0) if (attachment.clear_color) |color| switch (attachment.target) {
        .target => |target| target.clear(self.context, color),
        .texture => |texture| texture.clear(self.context, color) catch return,
    };

    command.pipeline.bind(self.context);

    if (command.uniforms) |uniforms| self.setUniformBuffer(1, uniforms.resource);

    if (command.buffers.len > 0) {
        if (command.buffers[0]) |vertex| {
            self.setVertexBuffer(vertex.resource, command.pipeline.stride);
        }

        if (command.buffers.len > 1) {
            var resources: [16]?*win32.ID3D11ShaderResourceView = @splat(null);
            const count = @min(command.buffers.len - 1, resources.len);
            for (command.buffers[1..][0..count], 0..) |binding, index| {
                resources[index] = if (binding) |value| value.shader_view else null;
            }
            if (command.buffers[0] == null) {
                self.setPixelShaderResources(0, resources[0..count]);
            } else {
                self.setVertexShaderResources(0, resources[0..count]);
            }
        }
    }

    if (command.textures.len > 0) {
        var resources: [16]?*win32.ID3D11ShaderResourceView = @splat(null);
        const count = @min(command.textures.len, resources.len);
        for (command.textures[0..count], 0..) |texture, index| {
            resources[index] = if (texture) |value| value.shader_view else null;
        }
        self.setPixelShaderResources(0, resources[0..count]);
    }

    if (command.samplers.len > 0) {
        var samplers: [16]?*win32.ID3D11SamplerState = @splat(null);
        const count = @min(command.samplers.len, samplers.len);
        for (command.samplers[0..count], 0..) |sampler, index| {
            samplers[index] = if (sampler) |value| value.sampler else null;
        }
        self.setPixelSamplers(0, samplers[0..count]);
    } else if (command.textures.len > 0) {
        var samplers = [_]?*win32.ID3D11SamplerState{self.default_sampler};
        self.setPixelSamplers(0, &samplers);
    }

    self.draw(@intCast(command.draw.vertex_count), @intCast(command.draw.instance_count));
}

pub fn complete(self: *const Self) void {
    var no_targets = [_]?*win32.ID3D11RenderTargetView{null};
    self.context.OMSetRenderTargets(0, &no_targets, null);
}

test "D3D11 render pass options allow transparent clearing" {
    const options: Options = .{ .attachments = &.{.{
        .target = .{ .target = undefined },
        .clear_color = .{ 0, 0, 0, 0 },
    }} };
    try std.testing.expectEqual(@as(f32, 0), options.attachments[0].clear_color.?[3]);
}

test "D3D11 generic draw primitives are available" {
    try std.testing.expectEqual(Step.Primitive.triangle, .triangle);
    try std.testing.expectEqual(Step.Primitive.triangle_strip, .triangle_strip);
}
