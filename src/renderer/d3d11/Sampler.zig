//! Immutable D3D11 texture sampler state.
const Self = @This();

const std = @import("std");
const win32 = @import("win32").everything;

const log = std.log.scoped(.d3d11_sampler);

pub const Options = struct {
    device: *win32.ID3D11Device,
    filter: win32.D3D11_FILTER = win32.D3D11_FILTER_MIN_MAG_MIP_LINEAR,
    address_u: win32.D3D11_TEXTURE_ADDRESS_MODE = win32.D3D11_TEXTURE_ADDRESS_CLAMP,
    address_v: win32.D3D11_TEXTURE_ADDRESS_MODE = win32.D3D11_TEXTURE_ADDRESS_CLAMP,
    address_w: win32.D3D11_TEXTURE_ADDRESS_MODE = win32.D3D11_TEXTURE_ADDRESS_CLAMP,
};

sampler: *win32.ID3D11SamplerState,

pub const Error = error{CreateSampler};

pub fn init(opts: Options) Error!Self {
    const desc = description(opts);
    var sampler: *win32.ID3D11SamplerState = undefined;
    const result = opts.device.CreateSamplerState(&desc, &sampler);
    if (!win32.SUCCEEDED(result)) {
        log.err("ID3D11Device.CreateSamplerState failed: hresult=0x{x}", .{
            @as(u32, @bitCast(result)),
        });
        return error.CreateSampler;
    }
    return .{ .sampler = sampler };
}

pub fn deinit(self: Self) void {
    _ = self.sampler.IUnknown.Release();
}

fn description(opts: Options) win32.D3D11_SAMPLER_DESC {
    return .{
        .Filter = opts.filter,
        .AddressU = opts.address_u,
        .AddressV = opts.address_v,
        .AddressW = opts.address_w,
        .MipLODBias = 0,
        .MaxAnisotropy = 1,
        .ComparisonFunc = win32.D3D11_COMPARISON_NEVER,
        .BorderColor = .{ 0, 0, 0, 0 },
        .MinLOD = 0,
        .MaxLOD = win32.D3D11_FLOAT32_MAX,
    };
}

test "D3D11 sampler defaults to linear clamp" {
    const desc = description(.{ .device = undefined });
    try std.testing.expectEqual(
        win32.D3D11_FILTER_MIN_MAG_MIP_LINEAR,
        desc.Filter,
    );
    try std.testing.expectEqual(win32.D3D11_TEXTURE_ADDRESS_CLAMP, desc.AddressU);
    try std.testing.expectEqual(win32.D3D11_TEXTURE_ADDRESS_CLAMP, desc.AddressV);
}
