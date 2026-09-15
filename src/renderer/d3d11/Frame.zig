//! Synchronous D3D11 frame submission for the generic renderer.
const Self = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const D3D11 = @import("../D3D11.zig");
const Renderer = @import("../generic.zig").Renderer(D3D11);
const RenderPass = @import("RenderPass.zig");
const Target = @import("Target.zig");
const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.d3d11_frame);

renderer: *Renderer,
target: *Target,
context: *win32.ID3D11DeviceContext,

pub fn begin(renderer: *Renderer, target: *Target, context: *win32.ID3D11DeviceContext) Self {
    return .{
        .renderer = renderer,
        .target = target,
        .context = context,
    };
}

pub fn renderPass(self: *const Self, attachments: []const RenderPass.Options.Attachment) RenderPass {
    return RenderPass.begin(
        self.context,
        self.renderer.api.default_sampler.?.sampler,
        .{ .attachments = attachments },
    );
}

/// D3D11 uses one CPU frame slot, so completion is synchronous from the
/// generic renderer's perspective even when Present itself is not blocking.
pub fn complete(self: *const Self, sync: bool) void {
    self.context.Flush();
    self.renderer.api.present(
        self.target,
        sync or self.renderer.config.vsync,
    ) catch |err| {
        log.err("failed to present D3D11 render target err={}", .{err});
        self.renderer.frameCompleted(.unhealthy);
        return;
    };
    self.renderer.frameCompleted(Health.healthy);
}
