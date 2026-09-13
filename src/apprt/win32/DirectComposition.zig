/// DirectComposition presentation objects for a Win32 window.
///
/// This is intentionally independent from the current WGL renderer. It owns
/// the Direct3D 11 device, premultiplied-alpha DXGI swap chain, and the
/// DirectComposition visual tree that a future renderer backend will target.
const Self = @This();

const win32 = @import("win32").everything;

const log = @import("std").log.scoped(.win32_direct_composition);

device: *win32.ID3D11Device,
context: *win32.ID3D11DeviceContext,
swap_chain: *win32.IDXGISwapChain1,
composition_device: *win32.IDCompositionDevice,
composition_target: *win32.IDCompositionTarget,
composition_visual: *win32.IDCompositionVisual,

pub const Error = error{
    CreateD3DDevice,
    QueryDxgiDevice,
    CreateDxgiFactory,
    CreateSwapChain,
    CreateCompositionDevice,
    CreateCompositionTarget,
    CreateCompositionVisual,
    SetCompositionContent,
    SetCompositionRoot,
    CommitComposition,
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

    _ = self.composition_visual.IUnknown.Release();
    _ = self.composition_target.IUnknown.Release();
    _ = self.composition_device.IUnknown.Release();
    _ = self.swap_chain.IUnknown.Release();
    _ = self.context.IUnknown.Release();
    _ = self.device.IUnknown.Release();
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
