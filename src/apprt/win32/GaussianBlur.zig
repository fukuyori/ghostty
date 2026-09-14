//! Windows.UI.Composition Gaussian blur backed by the desktop Host Backdrop.
//!
//! Windows Composition consumes Win2D-compatible `IGraphicsEffect` graphs,
//! but Ghostty does not otherwise depend on Win2D. This file provides the
//! minimal documented WinRT effect description needed for D2D Gaussian blur.

const std = @import("std");
const win32 = @import("win32").everything;

const log = std.log.scoped(.win32_gaussian_blur);

pub const Error = error{Unavailable};

/// Create a CompositionEffectBrush whose source is the desktop behind the
/// owning window and whose blur amount is the configured standard deviation.
/// The returned inspectable owns one reference.
pub fn create(
    compositor_instance: *win32.IInspectable,
    radius: u8,
) Error!*win32.IInspectable {
    const compositor = queryInterface(
        ICompositor,
        &compositor_instance.IUnknown,
        iid_compositor,
        "Compositor.QueryInterface(ICompositor)",
    ) catch return error.Unavailable;
    defer _ = compositor.IUnknown.Release();

    const compositor3 = queryInterface(
        ICompositor3,
        &compositor_instance.IUnknown,
        iid_compositor3,
        "Compositor.QueryInterface(ICompositor3)",
    ) catch return error.Unavailable;
    defer _ = compositor3.IUnknown.Release();

    var host_instance: *win32.IInspectable = undefined;
    check(
        compositor3.vtable.CreateHostBackdropBrush(compositor3, &host_instance),
        "ICompositor3.CreateHostBackdropBrush",
    ) catch return error.Unavailable;
    defer _ = host_instance.IUnknown.Release();

    const host_brush = queryInterface(
        ICompositionBrush,
        &host_instance.IUnknown,
        iid_composition_brush,
        "CompositionBackdropBrush.QueryInterface(ICompositionBrush)",
    ) catch return error.Unavailable;
    defer _ = host_brush.IUnknown.Release();

    const source = createSourceParameter(source_name) catch return error.Unavailable;
    const effect = Effect.create(source, standardDeviation(radius)) catch {
        _ = source.IUnknown.Release();
        return error.Unavailable;
    };
    defer _ = effect.effect.IUnknown.Release();

    var factory_instance: *win32.IInspectable = undefined;
    check(
        compositor.vtable.CreateEffectFactory(
            compositor,
            &effect.effect,
            &factory_instance,
        ),
        "ICompositor.CreateEffectFactory",
    ) catch return error.Unavailable;
    defer _ = factory_instance.IUnknown.Release();

    const factory = queryInterface(
        ICompositionEffectFactory,
        &factory_instance.IUnknown,
        iid_composition_effect_factory,
        "CompositionEffectFactory.QueryInterface",
    ) catch return error.Unavailable;
    defer _ = factory.IUnknown.Release();

    var brush_instance: *win32.IInspectable = undefined;
    check(
        factory.vtable.CreateBrush(factory, &brush_instance),
        "ICompositionEffectFactory.CreateBrush",
    ) catch return error.Unavailable;
    errdefer _ = brush_instance.IUnknown.Release();

    const effect_brush = queryInterface(
        ICompositionEffectBrush,
        &brush_instance.IUnknown,
        iid_composition_effect_brush,
        "CompositionEffectBrush.QueryInterface",
    ) catch return error.Unavailable;
    defer _ = effect_brush.IUnknown.Release();

    const source_name_h = createHString(source_name) catch return error.Unavailable;
    defer _ = win32.WindowsDeleteString(source_name_h);
    check(
        effect_brush.vtable.SetSourceParameter(
            effect_brush,
            source_name_h,
            host_brush,
        ),
        "ICompositionEffectBrush.SetSourceParameter",
    ) catch return error.Unavailable;

    return brush_instance;
}

pub fn standardDeviation(radius: u8) f32 {
    return @floatFromInt(@min(radius, 250));
}

const Effect = struct {
    effect: IGraphicsEffect = .{ .vtable = &effect_vtable },
    source_interface: IGraphicsEffectSource = .{ .vtable = &source_vtable },
    interop: IGraphicsEffectD2D1Interop = .{ .vtable = &interop_vtable },
    references: std.atomic.Value(u32) = .init(1),
    source_parameter: *IGraphicsEffectSource,
    blur_amount: f32,

    fn create(source: *IGraphicsEffectSource, blur_amount: f32) !*Effect {
        const self = try std.heap.page_allocator.create(Effect);
        self.* = .{
            .source_parameter = source,
            .blur_amount = blur_amount,
        };
        return self;
    }

    fn addRef(self: *Effect) u32 {
        return self.references.fetchAdd(1, .monotonic) + 1;
    }

    fn release(self: *Effect) u32 {
        const previous = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return previous - 1;

        _ = self.source_parameter.IUnknown.Release();
        std.heap.page_allocator.destroy(self);
        return 0;
    }

    fn queryInterface(
        self: *Effect,
        iid: *const win32.Guid,
        result: **anyopaque,
    ) win32.HRESULT {
        const output: *?*anyopaque = @ptrCast(result);
        output.* = if (guidEqual(iid, win32.IID_IUnknown) or
            guidEqual(iid, win32.IID_IInspectable) or
            guidEqual(iid, iid_graphics_effect))
            @ptrCast(&self.effect)
        else if (guidEqual(iid, iid_graphics_effect_source))
            @ptrCast(&self.source_interface)
        else if (guidEqual(iid, iid_graphics_effect_d2d1_interop))
            @ptrCast(&self.interop)
        else
            null;

        if (output.* == null) return win32.E_NOINTERFACE;
        _ = self.addRef();
        return win32.S_OK;
    }
};

fn effectFromInterface(value: *const IGraphicsEffect) *Effect {
    return @constCast(@fieldParentPtr("effect", value));
}

fn sourceFromInterface(value: *const IGraphicsEffectSource) *Effect {
    return @constCast(@fieldParentPtr("source_interface", value));
}

fn interopFromInterface(value: *const IGraphicsEffectD2D1Interop) *Effect {
    return @constCast(@fieldParentPtr("interop", value));
}

fn effectQueryInterface(
    self: *const win32.IUnknown,
    iid: *const win32.Guid,
    result: **anyopaque,
) callconv(.winapi) win32.HRESULT {
    return effectFromInterface(@ptrCast(self)).queryInterface(iid, result);
}

fn effectAddRef(self: *const win32.IUnknown) callconv(.winapi) u32 {
    return effectFromInterface(@ptrCast(self)).addRef();
}

fn effectRelease(self: *const win32.IUnknown) callconv(.winapi) u32 {
    return effectFromInterface(@ptrCast(self)).release();
}

fn sourceQueryInterface(
    self: *const win32.IUnknown,
    iid: *const win32.Guid,
    result: **anyopaque,
) callconv(.winapi) win32.HRESULT {
    return sourceFromInterface(@ptrCast(self)).queryInterface(iid, result);
}

fn sourceAddRef(self: *const win32.IUnknown) callconv(.winapi) u32 {
    return sourceFromInterface(@ptrCast(self)).addRef();
}

fn sourceRelease(self: *const win32.IUnknown) callconv(.winapi) u32 {
    return sourceFromInterface(@ptrCast(self)).release();
}

fn interopQueryInterface(
    self: *const win32.IUnknown,
    iid: *const win32.Guid,
    result: **anyopaque,
) callconv(.winapi) win32.HRESULT {
    return interopFromInterface(@ptrCast(self)).queryInterface(iid, result);
}

fn interopAddRef(self: *const win32.IUnknown) callconv(.winapi) u32 {
    return interopFromInterface(@ptrCast(self)).addRef();
}

fn interopRelease(self: *const win32.IUnknown) callconv(.winapi) u32 {
    return interopFromInterface(@ptrCast(self)).release();
}

fn getIids(
    _: *const win32.IInspectable,
    count: ?*u32,
    iids: [*]?*win32.Guid,
) callconv(.winapi) win32.HRESULT {
    const output = count orelse return win32.E_POINTER;
    output.* = 0;
    _ = iids;
    return win32.S_OK;
}

fn getRuntimeClassName(
    _: *const win32.IInspectable,
    output: ?*?win32.HSTRING,
) callconv(.winapi) win32.HRESULT {
    const result = output orelse return win32.E_POINTER;
    result.* = createHString("Ghostty.GaussianBlurEffect") catch return win32.E_OUTOFMEMORY;
    return win32.S_OK;
}

fn getTrustLevel(
    _: *const win32.IInspectable,
    output: ?*win32.TrustLevel,
) callconv(.winapi) win32.HRESULT {
    const result = output orelse return win32.E_POINTER;
    result.* = .BaseTrust;
    return win32.S_OK;
}

fn getName(
    _: *const IGraphicsEffect,
    output: ?*?win32.HSTRING,
) callconv(.winapi) win32.HRESULT {
    const result = output orelse return win32.E_POINTER;
    result.* = createHString(effect_name) catch return win32.E_OUTOFMEMORY;
    return win32.S_OK;
}

fn putName(_: *const IGraphicsEffect, _: ?win32.HSTRING) callconv(.winapi) win32.HRESULT {
    return win32.S_OK;
}

fn getEffectId(
    _: *const IGraphicsEffectD2D1Interop,
    output: ?*win32.Guid,
) callconv(.winapi) win32.HRESULT {
    const result = output orelse return win32.E_POINTER;
    result.* = win32.CLSID_D2D1GaussianBlur;
    return win32.S_OK;
}

fn getNamedPropertyMapping(
    _: *const IGraphicsEffectD2D1Interop,
    name: ?[*:0]const u16,
    output_index: ?*u32,
    output_mapping: ?*win32.GRAPHICS_EFFECT_PROPERTY_MAPPING,
) callconv(.winapi) win32.HRESULT {
    const value = name orelse return win32.E_POINTER;
    const index = output_index orelse return win32.E_POINTER;
    const mapping = output_mapping orelse return win32.E_POINTER;
    const text = std.mem.span(value);

    if (std.mem.eql(u16, text, std.unicode.utf8ToUtf16LeStringLiteral("BlurAmount"))) {
        index.* = @intFromEnum(win32.D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION);
    } else if (std.mem.eql(u16, text, std.unicode.utf8ToUtf16LeStringLiteral("Optimization"))) {
        index.* = @intFromEnum(win32.D2D1_GAUSSIANBLUR_PROP_OPTIMIZATION);
    } else if (std.mem.eql(u16, text, std.unicode.utf8ToUtf16LeStringLiteral("BorderMode"))) {
        index.* = @intFromEnum(win32.D2D1_GAUSSIANBLUR_PROP_BORDER_MODE);
    } else {
        return win32.E_INVALIDARG;
    }
    mapping.* = .DIRECT;
    return win32.S_OK;
}

fn getPropertyCount(
    _: *const IGraphicsEffectD2D1Interop,
    output: ?*u32,
) callconv(.winapi) win32.HRESULT {
    const result = output orelse return win32.E_POINTER;
    result.* = 3;
    return win32.S_OK;
}

fn getProperty(
    interface: *const IGraphicsEffectD2D1Interop,
    index: u32,
    output: ?**win32.IInspectable,
) callconv(.winapi) win32.HRESULT {
    const result = output orelse return win32.E_POINTER;
    const property_factory = getPropertyValueStatics() catch return win32.E_FAIL;
    defer _ = property_factory.IUnknown.Release();
    const self = interopFromInterface(interface);

    return switch (index) {
        0 => property_factory.vtable.CreateSingle(
            property_factory,
            self.blur_amount,
            result,
        ),
        1 => property_factory.vtable.CreateUInt32(
            property_factory,
            @intFromEnum(win32.D2D1_GAUSSIANBLUR_OPTIMIZATION_BALANCED),
            result,
        ),
        2 => property_factory.vtable.CreateUInt32(
            property_factory,
            @intFromEnum(win32.D2D1_BORDER_MODE_HARD),
            result,
        ),
        else => win32.E_INVALIDARG,
    };
}

fn getSource(
    interface: *const IGraphicsEffectD2D1Interop,
    index: u32,
    output: ?**IGraphicsEffectSource,
) callconv(.winapi) win32.HRESULT {
    const result = output orelse return win32.E_POINTER;
    if (index != 0) return win32.E_INVALIDARG;
    const source = interopFromInterface(interface).source_parameter;
    _ = source.IUnknown.AddRef();
    result.* = source;
    return win32.S_OK;
}

fn getSourceCount(
    _: *const IGraphicsEffectD2D1Interop,
    output: ?*u32,
) callconv(.winapi) win32.HRESULT {
    const result = output orelse return win32.E_POINTER;
    result.* = 1;
    return win32.S_OK;
}

fn createSourceParameter(name: []const u8) !*IGraphicsEffectSource {
    const class_name = try createHString("Windows.UI.Composition.CompositionEffectSourceParameter");
    defer _ = win32.WindowsDeleteString(class_name);

    var raw_factory: *anyopaque = undefined;
    try check(
        win32.RoGetActivationFactory(
            class_name,
            iid_composition_effect_source_parameter_factory,
            &raw_factory,
        ),
        "RoGetActivationFactory(CompositionEffectSourceParameter)",
    );
    const factory: *ICompositionEffectSourceParameterFactory = @ptrCast(@alignCast(raw_factory));
    defer _ = factory.IUnknown.Release();

    const name_h = try createHString(name);
    defer _ = win32.WindowsDeleteString(name_h);
    var result: *IGraphicsEffectSource = undefined;
    try check(
        factory.vtable.Create(factory, name_h, &result),
        "ICompositionEffectSourceParameterFactory.Create",
    );
    return result;
}

fn getPropertyValueStatics() !*IPropertyValueStatics {
    const class_name = try createHString("Windows.Foundation.PropertyValue");
    defer _ = win32.WindowsDeleteString(class_name);

    var raw_factory: *anyopaque = undefined;
    try check(
        win32.RoGetActivationFactory(
            class_name,
            iid_property_value_statics,
            &raw_factory,
        ),
        "RoGetActivationFactory(PropertyValue)",
    );
    return @ptrCast(@alignCast(raw_factory));
}

fn createHString(value: []const u8) !win32.HSTRING {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, value);
    defer std.heap.page_allocator.free(wide);
    var result: ?win32.HSTRING = null;
    try check(
        win32.WindowsCreateString(wide, @intCast(wide.len), &result),
        "WindowsCreateString",
    );
    return result.?;
}

fn queryInterface(
    comptime T: type,
    source: *win32.IUnknown,
    iid: *const win32.Guid,
    operation: []const u8,
) !*T {
    var result: *anyopaque = undefined;
    try check(source.QueryInterface(iid, &result), operation);
    return @ptrCast(@alignCast(result));
}

fn check(result: win32.HRESULT, operation: []const u8) !void {
    if (win32.SUCCEEDED(result)) return;
    log.err("{s} failed: hresult=0x{x}", .{
        operation,
        @as(u32, @bitCast(result)),
    });
    return error.Unavailable;
}

fn guidEqual(a: *const win32.Guid, b: *const win32.Guid) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

const source_name = "backdrop";
const effect_name = "Blur";

const IGraphicsEffect = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        get_Name: *const fn (*const IGraphicsEffect, ?*?win32.HSTRING) callconv(.winapi) win32.HRESULT,
        put_Name: *const fn (*const IGraphicsEffect, ?win32.HSTRING) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const IGraphicsEffectSource = extern union {
    const VTable = extern struct { base: win32.IInspectable.VTable };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const IGraphicsEffectD2D1Interop = extern union {
    const VTable = extern struct {
        base: win32.IUnknown.VTable,
        GetEffectId: *const fn (*const IGraphicsEffectD2D1Interop, ?*win32.Guid) callconv(.winapi) win32.HRESULT,
        GetNamedPropertyMapping: *const fn (*const IGraphicsEffectD2D1Interop, ?[*:0]const u16, ?*u32, ?*win32.GRAPHICS_EFFECT_PROPERTY_MAPPING) callconv(.winapi) win32.HRESULT,
        GetPropertyCount: *const fn (*const IGraphicsEffectD2D1Interop, ?*u32) callconv(.winapi) win32.HRESULT,
        GetProperty: *const fn (*const IGraphicsEffectD2D1Interop, u32, ?**win32.IInspectable) callconv(.winapi) win32.HRESULT,
        GetSource: *const fn (*const IGraphicsEffectD2D1Interop, u32, ?**IGraphicsEffectSource) callconv(.winapi) win32.HRESULT,
        GetSourceCount: *const fn (*const IGraphicsEffectD2D1Interop, ?*u32) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IUnknown: win32.IUnknown,
};

const ICompositionBrush = extern union {
    const VTable = extern struct { base: win32.IInspectable.VTable };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const ICompositionEffectBrush = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        GetSourceParameter: *const anyopaque,
        SetSourceParameter: *const fn (*const ICompositionEffectBrush, win32.HSTRING, *ICompositionBrush) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const ICompositionEffectFactory = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        CreateBrush: *const fn (*const ICompositionEffectFactory, **win32.IInspectable) callconv(.winapi) win32.HRESULT,
        ExtendedError: *const anyopaque,
        LoadStatus: *const anyopaque,
    };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const ICompositionEffectSourceParameterFactory = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        Create: *const fn (*const ICompositionEffectSourceParameterFactory, win32.HSTRING, **IGraphicsEffectSource) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const ICompositor = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        before_create_effect_factory: [5]*const anyopaque,
        CreateEffectFactory: *const fn (*const ICompositor, *IGraphicsEffect, **win32.IInspectable) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const ICompositor3 = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        CreateHostBackdropBrush: *const fn (*const ICompositor3, **win32.IInspectable) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const IPropertyValueStatics = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        before_create_uint32: [5]*const anyopaque,
        CreateUInt32: *const fn (*const IPropertyValueStatics, u32, **win32.IInspectable) callconv(.winapi) win32.HRESULT,
        before_create_single: [2]*const anyopaque,
        CreateSingle: *const fn (*const IPropertyValueStatics, f32, **win32.IInspectable) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const effect_vtable: IGraphicsEffect.VTable = .{
    .base = .{
        .base = .{
            .QueryInterface = effectQueryInterface,
            .AddRef = effectAddRef,
            .Release = effectRelease,
        },
        .GetIids = getIids,
        .GetRuntimeClassName = getRuntimeClassName,
        .GetTrustLevel = getTrustLevel,
    },
    .get_Name = getName,
    .put_Name = putName,
};

const source_vtable: IGraphicsEffectSource.VTable = .{
    .base = .{
        .base = .{
            .QueryInterface = sourceQueryInterface,
            .AddRef = sourceAddRef,
            .Release = sourceRelease,
        },
        .GetIids = getIids,
        .GetRuntimeClassName = getRuntimeClassName,
        .GetTrustLevel = getTrustLevel,
    },
};

const interop_vtable: IGraphicsEffectD2D1Interop.VTable = .{
    .base = .{
        .QueryInterface = interopQueryInterface,
        .AddRef = interopAddRef,
        .Release = interopRelease,
    },
    .GetEffectId = getEffectId,
    .GetNamedPropertyMapping = getNamedPropertyMapping,
    .GetPropertyCount = getPropertyCount,
    .GetProperty = getProperty,
    .GetSource = getSource,
    .GetSourceCount = getSourceCount,
};

const iid_graphics_effect_value = win32.Guid.initString("CB51C0CE-8FE6-4636-B202-861FAA07D8F3");
const iid_graphics_effect = &iid_graphics_effect_value;
const iid_graphics_effect_source_value = win32.Guid.initString("2D8F9DDC-4339-4EB9-9216-F9DEB75658A2");
const iid_graphics_effect_source = &iid_graphics_effect_source_value;
const iid_graphics_effect_d2d1_interop = win32.IID_IGraphicsEffectD2D1Interop;
const iid_compositor_value = win32.Guid.initString("B403CA50-7F8C-4E83-985F-CC45060036D8");
const iid_compositor = &iid_compositor_value;
const iid_compositor3_value = win32.Guid.initString("C9DD8EF0-6EB1-4E3C-A658-675D9C64D4AB");
const iid_compositor3 = &iid_compositor3_value;
const iid_composition_brush_value = win32.Guid.initString("AB0D7608-30C0-40E9-B568-B60A6BD1FB46");
const iid_composition_brush = &iid_composition_brush_value;
const iid_composition_effect_brush_value = win32.Guid.initString("BF7F795E-83CC-44BF-A447-3E3C071789EC");
const iid_composition_effect_brush = &iid_composition_effect_brush_value;
const iid_composition_effect_factory_value = win32.Guid.initString("BE5624AF-BA7E-4510-9850-41C0B4FF74DF");
const iid_composition_effect_factory = &iid_composition_effect_factory_value;
const iid_composition_effect_source_parameter_factory_value = win32.Guid.initString("B3D9F276-ABA3-4724-ACF3-D0397464DB1C");
const iid_composition_effect_source_parameter_factory = &iid_composition_effect_source_parameter_factory_value;
const iid_property_value_statics_value = win32.Guid.initString("629BDBC8-D932-4FF4-96B9-8D96C5C1E858");
const iid_property_value_statics = &iid_property_value_statics_value;

test "Win32 Gaussian blur uses configured standard deviation" {
    try std.testing.expectEqual(@as(f32, 1), standardDeviation(1));
    try std.testing.expectEqual(@as(f32, 20), standardDeviation(20));
    try std.testing.expectEqual(@as(f32, 250), standardDeviation(255));
}

test "Win32 Gaussian effect ABI identifiers match Windows metadata" {
    try std.testing.expect(guidEqual(iid_graphics_effect, &win32.Guid.initString("CB51C0CE-8FE6-4636-B202-861FAA07D8F3")));
    try std.testing.expect(guidEqual(iid_graphics_effect_d2d1_interop, win32.IID_IGraphicsEffectD2D1Interop));
    try std.testing.expect(guidEqual(&win32.CLSID_D2D1GaussianBlur, &win32.Guid.initString("1FEB6D69-2FE6-4AC9-8C58-1D7F93E7A6A5")));
}
