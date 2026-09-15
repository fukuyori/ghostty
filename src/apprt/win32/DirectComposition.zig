/// DirectComposition presentation objects for a Win32 window.
///
/// This is intentionally independent from the current WGL renderer. It owns
/// the Direct3D 11 device, premultiplied-alpha DXGI swap chain, and the
/// DirectComposition visual tree that a future renderer backend will target.
const Self = @This();

const win32 = @import("win32").everything;
const D3D11Target = @import("../../renderer/d3d11/Target.zig");

const log = @import("std").log.scoped(.win32_direct_composition);

device: *win32.ID3D11Device,
context: *win32.ID3D11DeviceContext,
swap_chain: *win32.IDXGISwapChain1,
back_buffer: ?D3D11Target,
composition_device: *win32.IDCompositionDevice,
composition_target: *win32.IDCompositionTarget,
composition_visual: *win32.IDCompositionVisual,

pub const Error = error{
    CreateD3DDevice,
    QueryDxgiDevice,
    CreateDxgiFactory,
    CreateSwapChain,
    CreateTexture,
    GetSwapChainBuffer,
    CreateRenderTarget,
    RenderTargetUnavailable,
    TargetSizeMismatch,
    TargetFormatMismatch,
    CreateCompositionDevice,
    CreateCompositionTarget,
    CreateCompositionVisual,
    SetCompositionContent,
    SetCompositionRoot,
    CommitComposition,
    Present,
    DeviceLost,
    ResizeSwapChain,
    GetSwapChainDescription,
};

/// Create a DirectComposition visual backed by a premultiplied-alpha swap
/// chain. Hardware D3D11 is preferred, with WARP as a compatibility fallback.
pub fn init(hwnd: win32.HWND, width: u32, height: u32) Error!Self {
    var device: *win32.ID3D11Device = undefined;
    var context: *win32.ID3D11DeviceContext = undefined;
    var result = win32.D3D11CreateDevice(
        null,
        .HARDWARE,
        null,
        win32.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        null,
        0,
        win32.D3D11_SDK_VERSION,
        &device,
        null,
        &context,
    );
    if (!win32.SUCCEEDED(result)) {
        result = win32.D3D11CreateDevice(
            null,
            .WARP,
            null,
            win32.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            null,
            0,
            win32.D3D11_SDK_VERSION,
            &device,
            null,
            &context,
        );
    }
    try check(result, error.CreateD3DDevice, "D3D11CreateDevice");
    errdefer _ = context.IUnknown.Release();
    errdefer _ = device.IUnknown.Release();

    var dxgi_device_raw: *anyopaque = undefined;
    try check(
        device.IUnknown.QueryInterface(
            win32.IID_IDXGIDevice,
            &dxgi_device_raw,
        ),
        error.QueryDxgiDevice,
        "ID3D11Device.QueryInterface(IDXGIDevice)",
    );
    const dxgi_device: *win32.IDXGIDevice = @ptrCast(@alignCast(dxgi_device_raw));
    defer _ = dxgi_device.IUnknown.Release();

    var factory_raw: *anyopaque = undefined;
    try check(
        win32.CreateDXGIFactory2(
            0,
            win32.IID_IDXGIFactory2,
            &factory_raw,
        ),
        error.CreateDxgiFactory,
        "CreateDXGIFactory2",
    );
    const factory: *win32.IDXGIFactory2 = @ptrCast(@alignCast(factory_raw));
    defer _ = factory.IUnknown.Release();

    const desc = swapChainDescription(width, height);
    var swap_chain: *win32.IDXGISwapChain1 = undefined;
    try check(
        factory.CreateSwapChainForComposition(
            @ptrCast(device),
            &desc,
            null,
            &swap_chain,
        ),
        error.CreateSwapChain,
        "IDXGIFactory2.CreateSwapChainForComposition",
    );
    errdefer _ = swap_chain.IUnknown.Release();

    var back_buffer = try D3D11Target.fromSwapChain(device, swap_chain);
    errdefer back_buffer.deinit();

    var composition_device_raw: ?*anyopaque = null;
    try check(
        win32.DCompositionCreateDevice(
            dxgi_device,
            win32.IID_IDCompositionDevice,
            &composition_device_raw,
        ),
        error.CreateCompositionDevice,
        "DCompositionCreateDevice",
    );
    const composition_device: *win32.IDCompositionDevice =
        @ptrCast(@alignCast(composition_device_raw.?));
    errdefer _ = composition_device.IUnknown.Release();

    var composition_target: ?*win32.IDCompositionTarget = null;
    try check(
        composition_device.CreateTargetForHwnd(
            hwnd,
            win32.TRUE,
            &composition_target,
        ),
        error.CreateCompositionTarget,
        "IDCompositionDevice.CreateTargetForHwnd",
    );
    errdefer _ = composition_target.?.IUnknown.Release();

    var composition_visual: ?*win32.IDCompositionVisual = null;
    try check(
        composition_device.CreateVisual(&composition_visual),
        error.CreateCompositionVisual,
        "IDCompositionDevice.CreateVisual",
    );
    errdefer _ = composition_visual.?.IUnknown.Release();

    try check(
        composition_visual.?.SetContent(@ptrCast(swap_chain)),
        error.SetCompositionContent,
        "IDCompositionVisual.SetContent",
    );
    try check(
        composition_target.?.SetRoot(composition_visual),
        error.SetCompositionRoot,
        "IDCompositionTarget.SetRoot",
    );
    try check(
        composition_device.Commit(),
        error.CommitComposition,
        "IDCompositionDevice.Commit",
    );

    return .{
        .device = device,
        .context = context,
        .swap_chain = swap_chain,
        .back_buffer = back_buffer,
        .composition_device = composition_device,
        .composition_target = composition_target.?,
        .composition_visual = composition_visual.?,
    };
}

pub fn deinit(self: *Self) void {
    // Disconnect the visual tree before releasing its content. Ignore errors
    // during teardown; every owned COM reference is still released below.
    _ = self.composition_target.SetRoot(null);
    _ = self.composition_device.Commit();

    if (self.back_buffer) |*back_buffer| {
        back_buffer.deinit();
        self.back_buffer = null;
    }
    _ = self.composition_visual.IUnknown.Release();
    _ = self.composition_target.IUnknown.Release();
    _ = self.composition_device.IUnknown.Release();
    _ = self.swap_chain.IUnknown.Release();
    _ = self.context.IUnknown.Release();
    _ = self.device.IUnknown.Release();
}

/// Clear the current back buffer with an already-premultiplied RGBA color.
/// The Ghostty renderer uses premultiplied alpha, matching the swap chain.
pub fn clear(self: *Self, color: [4]f32) Error!void {
    const back_buffer = if (self.back_buffer) |*target| target else return error.RenderTargetUnavailable;
    back_buffer.clear(self.context, color);
}

/// Create a renderer-owned target compatible with this presenter's swap chain.
pub fn createTarget(self: *Self, width: u32, height: u32) Error!D3D11Target {
    return try D3D11Target.init(
        self.device,
        width,
        height,
        win32.DXGI_FORMAT_B8G8R8A8_UNORM,
    );
}

/// Copy a completed GPU target into the composition swap chain and present it.
/// This path never maps the texture into CPU memory.
pub fn presentTarget(
    self: *Self,
    target: *const D3D11Target,
    sync_interval: u32,
) Error!void {
    const back_buffer = if (self.back_buffer) |*buffer| buffer else return error.RenderTargetUnavailable;
    try target.copyTo(self.context, back_buffer);
    try self.present(sync_interval);
}

/// Submit the current back buffer to DirectComposition.
pub fn present(self: *Self, sync_interval: u32) Error!void {
    const result = self.swap_chain.IDXGISwapChain.Present(sync_interval, 0);
    if (win32.SUCCEEDED(result)) return;

    const removed_reason = self.device.GetDeviceRemovedReason();
    if (isDeviceLostHresult(result) or isDeviceLostHresult(removed_reason)) {
        log.err(
            "IDXGISwapChain.Present detected device loss: hresult=0x{x} removed_reason=0x{x}",
            .{ hresultCode(result), hresultCode(removed_reason) },
        );
        return error.DeviceLost;
    }

    try check(result, error.Present, "IDXGISwapChain.Present");
}

/// Resize the swap chain and rebuild its render-target view. DXGI requires all
/// references to the old back buffers to be released before ResizeBuffers.
pub fn resize(self: *Self, width: u32, height: u32) Error!void {
    if (self.back_buffer) |*back_buffer| {
        back_buffer.deinit();
        self.back_buffer = null;
    }

    const result = self.swap_chain.IDXGISwapChain.ResizeBuffers(
        0,
        @max(width, 1),
        @max(height, 1),
        win32.DXGI_FORMAT_UNKNOWN,
        0,
    );
    if (!win32.SUCCEEDED(result)) {
        // ResizeBuffers leaves the original buffers intact on failure. Restore
        // the view so the presenter can continue displaying the old size.
        self.back_buffer = D3D11Target.fromSwapChain(
            self.device,
            self.swap_chain,
        ) catch null;
        try check(result, error.ResizeSwapChain, "IDXGISwapChain.ResizeBuffers");
    }

    self.back_buffer = try D3D11Target.fromSwapChain(
        self.device,
        self.swap_chain,
    );
}

pub fn getSwapChainDescription(self: *const Self) Error!win32.DXGI_SWAP_CHAIN_DESC1 {
    var desc: win32.DXGI_SWAP_CHAIN_DESC1 = undefined;
    try check(
        self.swap_chain.GetDesc1(&desc),
        error.GetSwapChainDescription,
        "IDXGISwapChain1.GetDesc1",
    );
    return desc;
}

fn swapChainDescription(width: u32, height: u32) win32.DXGI_SWAP_CHAIN_DESC1 {
    return .{
        .Width = @max(width, 1),
        .Height = @max(height, 1),
        .Format = win32.DXGI_FORMAT_B8G8R8A8_UNORM,
        .Stereo = win32.FALSE,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .BufferUsage = win32.DXGI_USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = 2,
        .Scaling = win32.DXGI_SCALING_STRETCH,
        .SwapEffect = win32.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
        .AlphaMode = win32.DXGI_ALPHA_MODE_PREMULTIPLIED,
        .Flags = 0,
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

fn hresultCode(result: win32.HRESULT) u32 {
    return @bitCast(result);
}

fn isDeviceLostHresult(result: win32.HRESULT) bool {
    return switch (hresultCode(result)) {
        // DXGI_ERROR_DEVICE_REMOVED
        0x887A0005,
        // DXGI_ERROR_DEVICE_HUNG
        0x887A0006,
        // DXGI_ERROR_DEVICE_RESET
        0x887A0007,
        // DXGI_ERROR_DRIVER_INTERNAL_ERROR
        0x887A0020,
        => true,
        else => false,
    };
}

test "DirectComposition swap chain description clamps empty dimensions" {
    const testing = @import("std").testing;
    const desc = swapChainDescription(0, 0);

    try testing.expectEqual(@as(u32, 1), desc.Width);
    try testing.expectEqual(@as(u32, 1), desc.Height);
    try testing.expectEqual(win32.DXGI_FORMAT_B8G8R8A8_UNORM, desc.Format);
    try testing.expectEqual(win32.DXGI_ALPHA_MODE_PREMULTIPLIED, desc.AlphaMode);
    try testing.expectEqual(win32.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL, desc.SwapEffect);
    try testing.expectEqual(@as(u32, 2), desc.BufferCount);
}

test "DirectComposition recognizes DXGI device loss HRESULTs" {
    const testing = @import("std").testing;

    for ([_]u32{
        0x887A0005,
        0x887A0006,
        0x887A0007,
        0x887A0020,
    }) |code| {
        try testing.expect(isDeviceLostHresult(@bitCast(code)));
    }
    try testing.expect(!isDeviceLostHresult(0));
    try testing.expect(!isDeviceLostHresult(@bitCast(@as(u32, 0x887A0001))));
}
