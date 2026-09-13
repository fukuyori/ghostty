//! Graphics API wrapper for Direct3D 11 and DirectComposition on Windows.
pub const D3D11 = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32").everything;
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const rendererpkg = @import("../renderer.zig");
const DirectComposition = @import("../apprt/win32/DirectComposition.zig");

pub const GraphicsAPI = D3D11;
pub const Target = @import("d3d11/Target.zig");
pub const Frame = @import("d3d11/Frame.zig");
pub const RenderPass = @import("d3d11/RenderPass.zig");
pub const Pipeline = @import("d3d11/Pipeline.zig");
const bufferpkg = @import("d3d11/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("d3d11/Sampler.zig");
pub const Texture = @import("d3d11/Texture.zig");
pub const shaders = @import("d3d11/shaders.zig");

/// Custom GLSL post-processing requires a separate HLSL translation path and
/// is intentionally deferred until the native terminal renderer is stable.
pub const supports_custom_shaders = false;
pub const custom_shader_y_is_down = true;
pub const swap_chain_count = 1;

surface: *apprt.Surface,
presenter: DirectComposition,
default_sampler: Sampler,
blending: configpkg.Config.AlphaBlending,
last_target: ?Target = null,

pub fn init(_: Allocator, opts: rendererpkg.Options) !D3D11 {
    const size = try opts.rt_surface.getSize();
    var presenter = try DirectComposition.init(
        opts.rt_surface.hwnd,
        @intCast(size.width),
        @intCast(size.height),
    );
    errdefer presenter.deinit();
    const default_sampler = try Sampler.init(.{ .device = presenter.device });
    errdefer default_sampler.deinit();
    return .{
        .surface = opts.rt_surface,
        .presenter = presenter,
        .default_sampler = default_sampler,
        .blending = opts.config.blending,
    };
}

pub fn deinit(self: *D3D11) void {
    self.default_sampler.deinit();
    self.presenter.deinit();
    self.* = undefined;
}

pub fn surfaceInit(_: *apprt.Surface) !void {}
pub fn finalizeSurfaceInit(_: *const D3D11, _: *apprt.Surface) !void {}
pub fn threadEnter(_: *const D3D11, _: *apprt.Surface) !void {}
pub fn threadExit(_: *const D3D11) void {}
pub fn drawFrameStart(_: *D3D11) void {}
pub fn drawFrameEnd(_: *D3D11) void {}

pub fn initShaders(self: *const D3D11, _: Allocator, _: []const [:0]const u8) !shaders.Shaders {
    return try shaders.Shaders.init(self.presenter.device);
}

pub fn surfaceSize(self: *const D3D11) !struct { width: u32, height: u32 } {
    const size = try self.surface.getSize();
    return .{ .width = @intCast(size.width), .height = @intCast(size.height) };
}

pub fn initTarget(self: *const D3D11, width: usize, height: usize) !Target {
    return try Target.init(
        self.presenter.device,
        @intCast(width),
        @intCast(height),
        if (self.blending.isLinear())
            win32.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB
        else
            win32.DXGI_FORMAT_B8G8R8A8_UNORM,
    );
}

pub fn present(self: *D3D11, target: *const Target, sync: bool) !void {
    const back_buffer = self.presenter.back_buffer orelse
        return error.RenderTargetUnavailable;
    if (back_buffer.width != target.width or back_buffer.height != target.height) {
        try self.presenter.resize(target.width, target.height);
    }
    try self.presenter.presentTarget(target, if (sync) 1 else 0);
    self.last_target = target.*;
}

pub fn presentLastTarget(self: *D3D11) !void {
    if (self.last_target) |*target| try self.present(target, false);
}

pub fn gpuResourcesReleased(self: *D3D11) void {
    self.last_target = null;
}

pub inline fn uniformBufferOptions(self: D3D11) bufferpkg.Options {
    return .{
        .device = self.presenter.device,
        .context = self.presenter.context,
        .bind_flags = .{ .CONSTANT_BUFFER = 1 },
    };
}

pub inline fn fgBufferOptions(self: D3D11) bufferpkg.Options {
    return self.instanceBufferOptions();
}

pub inline fn bgBufferOptions(self: D3D11) bufferpkg.Options {
    return .{
        .device = self.presenter.device,
        .context = self.presenter.context,
        .bind_flags = .{ .SHADER_RESOURCE = 1 },
        .structured = true,
    };
}

pub inline fn instanceBufferOptions(self: D3D11) bufferpkg.Options {
    return .{
        .device = self.presenter.device,
        .context = self.presenter.context,
        .bind_flags = .{ .VERTEX_BUFFER = 1 },
    };
}

pub const imageBufferOptions = instanceBufferOptions;
pub const bgImageBufferOptions = instanceBufferOptions;

pub inline fn textureOptions(self: D3D11) Texture.Options {
    return .{
        .device = self.presenter.device,
        .context = self.presenter.context,
        .format = win32.DXGI_FORMAT_B8G8R8A8_UNORM,
        .render_target = true,
    };
}

pub inline fn samplerOptions(self: D3D11) Sampler.Options {
    return .{ .device = self.presenter.device };
}

pub const ImageTextureFormat = enum { gray, rgba, bgra };

pub inline fn imageTextureOptions(
    self: D3D11,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    return .{
        .device = self.presenter.device,
        .context = self.presenter.context,
        .format = switch (format) {
            .gray => win32.DXGI_FORMAT_R8_UNORM,
            .rgba => if (srgb)
                win32.DXGI_FORMAT_R8G8B8A8_UNORM_SRGB
            else
                win32.DXGI_FORMAT_R8G8B8A8_UNORM,
            .bgra => if (srgb)
                win32.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB
            else
                win32.DXGI_FORMAT_B8G8R8A8_UNORM,
        },
    };
}

pub fn initAtlasTexture(self: *const D3D11, atlas: *const font.Atlas) Texture.Error!Texture {
    const format = switch (atlas.format) {
        .grayscale => win32.DXGI_FORMAT_R8_UNORM,
        .bgra => win32.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
        else => @panic("unsupported atlas format for D3D11 texture"),
    };
    return try Texture.init(.{
        .device = self.presenter.device,
        .context = self.presenter.context,
        .format = format,
    }, atlas.size, atlas.size, null);
}

pub inline fn beginFrame(
    self: *const D3D11,
    renderer: *@import("generic.zig").Renderer(D3D11),
    target: *Target,
) !Frame {
    return Frame.begin(renderer, target, self.presenter.context);
}

test "D3D11 exposes generic renderer resource types" {
    comptime {
        _ = Buffer(shaders.Uniforms);
        _ = Buffer(shaders.CellText);
        _ = RenderPass.Step;
        _ = Frame;
    }
}
