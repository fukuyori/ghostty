//! Native Windows backdrop effects for transparent DirectComposition windows.

const Backdrop = @This();

const std = @import("std");
const win32 = @import("win32").everything;

const log = std.log.scoped(.win32_backdrop);

hwnd: win32.HWND,
dwm_active: bool = false,
compositor: ?*win32.IInspectable = null,
target: ?*ICompositionTarget = null,
visual: ?*IVisual = null,

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
    InitializeWinRT,
    CreateDispatcherQueue,
    CreateRuntimeClassName,
    ActivateCompositor,
    QueryCompositorInterop,
    BindCompositorThread,
    CreateDesktopTarget,
    QueryCompositionTarget,
    QueryCompositor,
    QueryCompositor3,
    CreateHostBackdropBrush,
    QueryCompositionBrush,
    CreateSpriteVisual,
    QuerySpriteVisual,
    SetSpriteBrush,
    QueryVisual,
    SetVisualOpacity,
    QueryVisual2,
    SetRelativeSize,
    SetCompositionRoot,
};

/// Enable native Acrylic and, where available, add a lower Host Backdrop
/// visual. The lower visual mixes unblurred desktop pixels over Acrylic so the
/// configured radius can tune the perceived blur strength without affecting
/// the terminal's upper DirectComposition visual.
pub fn init(hwnd: win32.HWND, radius: u8, runtime: *Runtime) Error!Backdrop {
    try setSystemBackdrop(hwnd, .transient_window);

    var self: Backdrop = .{
        .hwnd = hwnd,
        .dwm_active = true,
    };
    self.initIntensityLayer(radius, runtime) catch |err| {
        // System Acrylic is still useful on Windows versions or configurations
        // where Host Backdrop composition isn't available.
        log.warn("adjustable backdrop unavailable; using fixed Acrylic: {}", .{err});
        self.releaseIntensityLayer();
    };
    return self;
}

pub fn deinit(self: *Backdrop) void {
    self.releaseIntensityLayer();
    if (self.dwm_active) {
        setSystemBackdrop(self.hwnd, .none) catch |err|
            log.warn("failed to remove Win32 background blur: {}", .{err});
        self.dwm_active = false;
    }
}

/// Update the adjustable layer after a configuration reload. If the layer was
/// unavailable during initialization, the fixed native Acrylic remains active.
pub fn setRadius(self: *Backdrop, radius: u8) Error!void {
    const visual = self.visual orelse return;
    try check(
        visual.vtable.put_Opacity(visual, unblurredOpacity(radius)),
        error.SetVisualOpacity,
        "IVisual.put_Opacity",
    );
}

fn initIntensityLayer(self: *Backdrop, radius: u8, runtime: *Runtime) Error!void {
    try runtime.ensure();
    errdefer self.releaseIntensityLayer();

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
            self.hwnd,
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

    const compositor3 = try queryInterface(
        ICompositor3,
        &compositor_instance.IUnknown,
        iid_compositor3,
        error.QueryCompositor3,
        "Compositor.QueryInterface(ICompositor3)",
    );
    defer _ = compositor3.IUnknown.Release();

    var backdrop_instance: *win32.IInspectable = undefined;
    try check(
        compositor3.vtable.CreateHostBackdropBrush(
            compositor3,
            &backdrop_instance,
        ),
        error.CreateHostBackdropBrush,
        "ICompositor3.CreateHostBackdropBrush",
    );
    defer _ = backdrop_instance.IUnknown.Release();

    const brush = try queryInterface(
        ICompositionBrush,
        &backdrop_instance.IUnknown,
        iid_composition_brush,
        error.QueryCompositionBrush,
        "CompositionBackdropBrush.QueryInterface(ICompositionBrush)",
    );
    defer _ = brush.IUnknown.Release();

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
    defer _ = sprite.IUnknown.Release();
    try check(
        sprite.vtable.put_Brush(sprite, brush),
        error.SetSpriteBrush,
        "ISpriteVisual.put_Brush",
    );

    const visual = try queryInterface(
        IVisual,
        &sprite_instance.IUnknown,
        iid_visual,
        error.QueryVisual,
        "SpriteVisual.QueryInterface(IVisual)",
    );
    errdefer _ = visual.IUnknown.Release();
    try check(
        visual.vtable.put_Opacity(visual, unblurredOpacity(radius)),
        error.SetVisualOpacity,
        "IVisual.put_Opacity",
    );

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
}

fn releaseIntensityLayer(self: *Backdrop) void {
    if (self.target) |target| {
        _ = target.vtable.put_Root(target, null);
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

/// Radius 32 is the full system Acrylic strength. Lower values progressively
/// reveal the unblurred Host Backdrop, while larger values remain clamped.
pub fn unblurredOpacity(radius: u8) f32 {
    const max_radius: f32 = 32;
    const value: f32 = @floatFromInt(@min(radius, 32));
    return 1 - value / max_radius;
}

fn setSystemBackdrop(hwnd: win32.HWND, kind: Kind) Error!void {
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

const ICompositor3 = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        CreateHostBackdropBrush: *const fn (
            self: *const ICompositor3,
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
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        before_put_opacity: [17]*const anyopaque,
        put_Opacity: *const fn (
            self: *const IVisual,
            value: f32,
        ) callconv(.winapi) win32.HRESULT,
    };
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
const iid_compositor3_value = win32.Guid.initString("C9DD8EF0-6EB1-4E3C-A658-675D9C64D4AB");
const iid_compositor3 = &iid_compositor3_value;
const iid_composition_brush_value = win32.Guid.initString("AB0D7608-30C0-40E9-B568-B60A6BD1FB46");
const iid_composition_brush = &iid_composition_brush_value;
const iid_sprite_visual_value = win32.Guid.initString("08E05581-1AD1-4F97-9757-402D76E4233B");
const iid_sprite_visual = &iid_sprite_visual_value;
const iid_visual_value = win32.Guid.initString("117E202D-A859-4C89-873B-C2AA566788E3");
const iid_visual = &iid_visual_value;
const iid_visual2_value = win32.Guid.initString("3052B611-56C3-4C3E-8BF3-F6E1AD473F06");
const iid_visual2 = &iid_visual2_value;

const rpc_e_changed_mode: win32.HRESULT = @bitCast(@as(u32, 0x80010106));
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
    try std.testing.expectEqual(@as(u32, 38), dwmwa_system_backdrop_type);
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Vector2));
}

test "Win32 backdrop strength maps radius to unblurred opacity" {
    try std.testing.expectEqual(@as(f32, 1), unblurredOpacity(0));
    try std.testing.expectEqual(@as(f32, 0.5), unblurredOpacity(16));
    try std.testing.expectEqual(@as(f32, 0.375), unblurredOpacity(20));
    try std.testing.expectEqual(@as(f32, 0), unblurredOpacity(32));
    try std.testing.expectEqual(@as(f32, 0), unblurredOpacity(255));
}
