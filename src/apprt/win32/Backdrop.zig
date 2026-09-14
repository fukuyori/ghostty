//! Native Windows backdrop effects for transparent DirectComposition windows.

const Backdrop = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const GaussianBlur = @import("GaussianBlur.zig");

const log = std.log.scoped(.win32_backdrop);

compositor: ?*win32.IInspectable = null,
target: ?*ICompositionTarget = null,
visual: ?*IVisual = null,
sprite: ?*ISpriteVisual = null,

/// WinRT state shared by every backdrop on the Win32 UI thread. A desktop
/// DispatcherQueue must outlive all Windows.UI.Composition objects created on
/// that thread.
pub const Runtime = struct {
    ro_initialized: bool = false,
    controller: ?*win32.IInspectable = null,

    pub fn deinit(self: *Runtime) void {
        if (self.controller) |controller| {
            _ = controller.IUnknown.Release();
            self.controller = null;
        }
        if (self.ro_initialized) {
            win32.RoUninitialize();
            self.ro_initialized = false;
        }
    }

    fn ensure(self: *Runtime) Error!void {
        if (self.controller != null) return;

        const init_result = win32.RoInitialize(win32.RO_INIT_SINGLETHREADED);
        if (win32.SUCCEEDED(init_result)) {
            self.ro_initialized = true;
        } else if (init_result != rpc_e_changed_mode) {
            try check(init_result, error.InitializeWinRT, "RoInitialize");
        }
        errdefer if (self.ro_initialized) {
            win32.RoUninitialize();
            self.ro_initialized = false;
        };

        const options: win32.DispatcherQueueOptions = .{
            .dwSize = @sizeOf(win32.DispatcherQueueOptions),
            .threadType = win32.DQTYPE_THREAD_CURRENT,
            .apartmentType = win32.DQTAT_COM_STA,
        };
        var controller: *win32.IInspectable = undefined;
        try check(
            win32.CreateDispatcherQueueController(
                options,
                @ptrCast(&controller),
            ),
            error.CreateDispatcherQueue,
            "CreateDispatcherQueueController",
        );
        self.controller = controller;
    }
};

/// Values from DWM_SYSTEMBACKDROP_TYPE. The system backdrop attribute is
/// intentionally declared locally so older Windows SDK bindings can still
/// build Ghostty; unsupported Windows versions reject the attribute at runtime.
pub const Kind = enum(i32) {
    none = 1,
    transient_window = 3,
};

pub const Error = error{
    SetSystemBackdrop,
    SetHostBackdrop,
    InitializeWinRT,
    CreateDispatcherQueue,
    CreateRuntimeClassName,
    ActivateCompositor,
    QueryCompositorInterop,
    BindCompositorThread,
    CreateDesktopTarget,
    QueryCompositionTarget,
    QueryCompositor,
    QueryCompositionBrush,
    CreateGaussianBlurBrush,
    CreateSpriteVisual,
    QuerySpriteVisual,
    SetSpriteBrush,
    QueryVisual,
    QueryVisual2,
    SetRelativeSize,
    SetCompositionRoot,
};

/// Create a real Gaussian blur over the desktop Host Backdrop. Fixed native
/// Acrylic is retained only as a fallback when Composition effects are not
/// available on the current Windows configuration.
pub fn init(
    hwnd: win32.HWND,
    radius: u8,
    runtime: *Runtime,
) Error!Backdrop {
    var self: Backdrop = .{};
    try self.initGaussianLayer(hwnd, radius, runtime);
    log.info("enabled Gaussian backdrop blur standard_deviation={d}", .{GaussianBlur.standardDeviation(radius)});
    return self;
}

pub fn deinit(self: *Backdrop) void {
    self.releaseCompositionLayer();
}

/// Recompile the Gaussian effect when a configuration reload changes the
/// standard deviation. Fixed Acrylic has no adjustable radius.
pub fn setRadius(self: *Backdrop, radius: u8) Error!void {
    const compositor = self.compositor orelse return;
    const sprite = self.sprite orelse return;
    try setGaussianBrush(compositor, sprite, radius);
    log.info("updated Gaussian backdrop blur standard_deviation={d}", .{GaussianBlur.standardDeviation(radius)});
}

fn initGaussianLayer(
    self: *Backdrop,
    hwnd: win32.HWND,
    radius: u8,
    runtime: *Runtime,
) Error!void {
    try runtime.ensure();
    errdefer self.releaseCompositionLayer();

    const class_name_w = std.unicode.utf8ToUtf16LeStringLiteral(
        "Windows.UI.Composition.Compositor",
    );
    var class_name: ?win32.HSTRING = null;
    try check(
        win32.WindowsCreateString(
            class_name_w,
            @intCast(class_name_w.len),
            &class_name,
        ),
        error.CreateRuntimeClassName,
        "WindowsCreateString",
    );
    defer _ = win32.WindowsDeleteString(class_name);

    var compositor_instance: *win32.IInspectable = undefined;
    try check(
        win32.RoActivateInstance(class_name, &compositor_instance),
        error.ActivateCompositor,
        "RoActivateInstance(Compositor)",
    );
    errdefer _ = compositor_instance.IUnknown.Release();

    const desktop_interop = try queryInterface(
        win32.ICompositorDesktopInterop,
        &compositor_instance.IUnknown,
        win32.IID_ICompositorDesktopInterop,
        error.QueryCompositorInterop,
        "Compositor.QueryInterface(ICompositorDesktopInterop)",
    );
    defer _ = desktop_interop.IUnknown.Release();

    try check(
        desktop_interop.EnsureOnThread(win32.GetCurrentThreadId()),
        error.BindCompositorThread,
        "ICompositorDesktopInterop.EnsureOnThread",
    );

    var target_instance: *win32.IInspectable = undefined;
    try check(
        desktop_interop.vtable.CreateDesktopWindowTarget(
            desktop_interop,
            hwnd,
            win32.FALSE,
            @ptrCast(&target_instance),
        ),
        error.CreateDesktopTarget,
        "ICompositorDesktopInterop.CreateDesktopWindowTarget",
    );
    defer _ = target_instance.IUnknown.Release();

    const target = try queryInterface(
        ICompositionTarget,
        &target_instance.IUnknown,
        iid_composition_target,
        error.QueryCompositionTarget,
        "DesktopWindowTarget.QueryInterface(ICompositionTarget)",
    );
    errdefer _ = target.IUnknown.Release();

    const compositor = try queryInterface(
        ICompositor,
        &compositor_instance.IUnknown,
        iid_compositor,
        error.QueryCompositor,
        "Compositor.QueryInterface(ICompositor)",
    );
    defer _ = compositor.IUnknown.Release();

    var sprite_instance: *win32.IInspectable = undefined;
    try check(
        compositor.vtable.CreateSpriteVisual(compositor, &sprite_instance),
        error.CreateSpriteVisual,
        "ICompositor.CreateSpriteVisual",
    );
    defer _ = sprite_instance.IUnknown.Release();

    const sprite = try queryInterface(
        ISpriteVisual,
        &sprite_instance.IUnknown,
        iid_sprite_visual,
        error.QuerySpriteVisual,
        "SpriteVisual.QueryInterface(ISpriteVisual)",
    );
    errdefer _ = sprite.IUnknown.Release();
    try setGaussianBrush(compositor_instance, sprite, radius);

    const visual = try queryInterface(
        IVisual,
        &sprite_instance.IUnknown,
        iid_visual,
        error.QueryVisual,
        "SpriteVisual.QueryInterface(IVisual)",
    );
    errdefer _ = visual.IUnknown.Release();
    const visual2 = try queryInterface(
        IVisual2,
        &sprite_instance.IUnknown,
        iid_visual2,
        error.QueryVisual2,
        "SpriteVisual.QueryInterface(IVisual2)",
    );
    defer _ = visual2.IUnknown.Release();
    try check(
        visual2.vtable.put_RelativeSizeAdjustment(
            visual2,
            .{ .x = 1, .y = 1 },
        ),
        error.SetRelativeSize,
        "IVisual2.put_RelativeSizeAdjustment",
    );

    try check(
        target.vtable.put_Root(target, visual),
        error.SetCompositionRoot,
        "ICompositionTarget.put_Root",
    );

    self.compositor = compositor_instance;
    self.target = target;
    self.visual = visual;
    self.sprite = sprite;
}

fn setGaussianBrush(
    compositor: *win32.IInspectable,
    sprite: *ISpriteVisual,
    radius: u8,
) Error!void {
    const brush_instance = GaussianBlur.create(compositor, radius) catch
        return error.CreateGaussianBlurBrush;
    defer _ = brush_instance.IUnknown.Release();

    const brush = try queryInterface(
        ICompositionBrush,
        &brush_instance.IUnknown,
        iid_composition_brush,
        error.QueryCompositionBrush,
        "CompositionEffectBrush.QueryInterface(ICompositionBrush)",
    );
    defer _ = brush.IUnknown.Release();
    try check(
        sprite.vtable.put_Brush(sprite, brush),
        error.SetSpriteBrush,
        "ISpriteVisual.put_Brush",
    );
}

fn releaseCompositionLayer(self: *Backdrop) void {
    if (self.target) |target| {
        _ = target.vtable.put_Root(target, null);
    }
    if (self.sprite) |sprite| {
        _ = sprite.IUnknown.Release();
        self.sprite = null;
    }
    if (self.visual) |visual| {
        _ = visual.IUnknown.Release();
        self.visual = null;
    }
    if (self.target) |target| {
        _ = target.IUnknown.Release();
        self.target = null;
    }
    if (self.compositor) |compositor| {
        _ = compositor.IUnknown.Release();
        self.compositor = null;
    }
}

pub fn setHostBackdrop(hwnd: win32.HWND, enabled: bool) Error!void {
    var value: win32.BOOL = if (enabled) win32.TRUE else win32.FALSE;
    const result = DwmSetWindowAttribute(
        hwnd,
        dwmwa_use_host_backdrop_brush,
        &value,
        @sizeOf(@TypeOf(value)),
    );
    try check(result, error.SetHostBackdrop, "DwmSetWindowAttribute(DWMWA_USE_HOSTBACKDROPBRUSH)");
}

pub fn setSystemBackdrop(hwnd: win32.HWND, kind: Kind) Error!void {
    var value: i32 = @intFromEnum(kind);
    const result = DwmSetWindowAttribute(
        hwnd,
        dwmwa_system_backdrop_type,
        &value,
        @sizeOf(@TypeOf(value)),
    );
    try check(result, error.SetSystemBackdrop, "DwmSetWindowAttribute");
}

fn queryInterface(
    comptime T: type,
    source: *win32.IUnknown,
    iid: *const win32.Guid,
    err: Error,
    operation: []const u8,
) Error!*T {
    var result: *anyopaque = undefined;
    try check(source.QueryInterface(iid, &result), err, operation);
    return @ptrCast(@alignCast(result));
}

fn check(result: win32.HRESULT, err: Error, operation: []const u8) Error!void {
    if (win32.SUCCEEDED(result)) return;
    log.err("{s} failed: hresult=0x{x}", .{
        operation,
        @as(u32, @bitCast(result)),
    });
    return err;
}

const Vector2 = extern struct {
    x: f32,
    y: f32,
};

const ICompositionBrush = extern union {
    const VTable = extern struct { base: win32.IInspectable.VTable };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const ICompositionTarget = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        get_Root: *const anyopaque,
        put_Root: *const fn (
            self: *const ICompositionTarget,
            value: ?*IVisual,
        ) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const ICompositor = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        before_create_sprite_visual: [16]*const anyopaque,
        CreateSpriteVisual: *const fn (
            self: *const ICompositor,
            result: **win32.IInspectable,
        ) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const ISpriteVisual = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        get_Brush: *const anyopaque,
        put_Brush: *const fn (
            self: *const ISpriteVisual,
            value: ?*ICompositionBrush,
        ) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const IVisual = extern union {
    const VTable = extern struct { base: win32.IInspectable.VTable };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const IVisual2 = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        before_put_relative_size: [5]*const anyopaque,
        put_RelativeSizeAdjustment: *const fn (
            self: *const IVisual2,
            value: Vector2,
        ) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const iid_composition_target_value = win32.Guid.initString("A1BEA8BA-D726-4663-8129-6B5E7927FFA6");
const iid_composition_target = &iid_composition_target_value;
const iid_compositor_value = win32.Guid.initString("B403CA50-7F8C-4E83-985F-CC45060036D8");
const iid_compositor = &iid_compositor_value;
const iid_composition_brush_value = win32.Guid.initString("AB0D7608-30C0-40E9-B568-B60A6BD1FB46");
const iid_composition_brush = &iid_composition_brush_value;
const iid_sprite_visual_value = win32.Guid.initString("08E05581-1AD1-4F97-9757-402D76E4233B");
const iid_sprite_visual = &iid_sprite_visual_value;
const iid_visual_value = win32.Guid.initString("117E202D-A859-4C89-873B-C2AA566788E3");
const iid_visual = &iid_visual_value;
const iid_visual2_value = win32.Guid.initString("3052B611-56C3-4C3E-8BF3-F6E1AD473F06");
const iid_visual2 = &iid_visual2_value;

const rpc_e_changed_mode: win32.HRESULT = @bitCast(@as(u32, 0x80010106));
const dwmwa_use_host_backdrop_brush: u32 = 17;
const dwmwa_system_backdrop_type: u32 = 38;

extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: win32.HWND,
    attribute: u32,
    value: *const anyopaque,
    value_size: u32,
) callconv(.winapi) win32.HRESULT;

test "Win32 backdrop values match the native ABI" {
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(Kind.none));
    try std.testing.expectEqual(@as(i32, 3), @intFromEnum(Kind.transient_window));
    try std.testing.expectEqual(@as(u32, 17), dwmwa_use_host_backdrop_brush);
    try std.testing.expectEqual(@as(u32, 38), dwmwa_system_backdrop_type);
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Vector2));
}
