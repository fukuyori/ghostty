//! The Windows app light/dark mode, read the way Microsoft documents for
//! Win32 apps: Windows.UI.ViewManagement.UISettings reports a light
//! foreground color in dark mode.

const std = @import("std");
const win32 = @import("win32").everything;
const apprt = @import("../../apprt.zig");

const log = std.log.scoped(.win32_color_scheme);

/// Read the current mode. Any WinRT failure is logged and reported as light,
/// the conditional configuration default.
pub fn current() apprt.ColorScheme {
    return query() catch |err| {
        log.warn("system color scheme unavailable; using light: {}", .{err});
        return .light;
    };
}

const Error = error{
    InitializeWinRT,
    CreateRuntimeClassName,
    ActivateUISettings,
    QueryUISettings3,
    GetColorValue,
};

fn query() Error!apprt.ColorScheme {
    const init_result = win32.RoInitialize(win32.RO_INIT_SINGLETHREADED);
    const ro_initialized = win32.SUCCEEDED(init_result);
    if (!ro_initialized and init_result != rpc_e_changed_mode) {
        try check(init_result, error.InitializeWinRT, "RoInitialize");
    }
    defer if (ro_initialized) win32.RoUninitialize();

    const class_name_w = std.unicode.utf8ToUtf16LeStringLiteral(
        "Windows.UI.ViewManagement.UISettings",
    );
    var class_name: ?win32.HSTRING = null;
    try check(
        win32.WindowsCreateString(class_name_w, @intCast(class_name_w.len), &class_name),
        error.CreateRuntimeClassName,
        "WindowsCreateString",
    );
    defer _ = win32.WindowsDeleteString(class_name);

    var instance: *win32.IInspectable = undefined;
    try check(
        win32.RoActivateInstance(class_name, &instance),
        error.ActivateUISettings,
        "RoActivateInstance(UISettings)",
    );
    defer _ = instance.IUnknown.Release();

    var settings_ptr: *anyopaque = undefined;
    try check(
        instance.IUnknown.QueryInterface(iid_ui_settings3, &settings_ptr),
        error.QueryUISettings3,
        "UISettings.QueryInterface(IUISettings3)",
    );
    const settings: *IUISettings3 = @ptrCast(@alignCast(settings_ptr));
    defer _ = settings.IUnknown.Release();

    var foreground: Color = undefined;
    try check(
        settings.vtable.GetColorValue(settings, ui_color_type_foreground, &foreground),
        error.GetColorValue,
        "IUISettings3.GetColorValue(Foreground)",
    );
    return schemeForForeground(foreground);
}

/// Dark mode is a light foreground on a dark background.
fn schemeForForeground(foreground: Color) apprt.ColorScheme {
    return if (isColorLight(foreground)) .dark else .light;
}

/// Microsoft's integer perceived-brightness test from the same guide.
fn isColorLight(color: Color) bool {
    const r: u32 = color.r;
    const g: u32 = color.g;
    const b: u32 = color.b;
    return 5 * g + 2 * r + b > 8 * 128;
}

fn check(result: win32.HRESULT, err: Error, operation: []const u8) Error!void {
    if (win32.SUCCEEDED(result)) return;
    log.warn("{s} failed: hresult=0x{x}", .{ operation, @as(u32, @bitCast(result)) });
    return err;
}

const rpc_e_changed_mode: win32.HRESULT = @bitCast(@as(u32, 0x80010106));

/// Windows.UI.Color: A, R, G, B bytes in that order.
const Color = extern struct {
    a: u8,
    r: u8,
    g: u8,
    b: u8,
};

/// Windows.UI.ViewManagement.UIColorType.Foreground.
const ui_color_type_foreground: i32 = 1;

/// Windows.UI.ViewManagement.IUISettings3, from windows.ui.viewmanagement.h.
const IUISettings3 = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        GetColorValue: *const fn (
            self: *const IUISettings3,
            desired_color: i32,
            value: *Color,
        ) callconv(.winapi) win32.HRESULT,
        add_ColorValuesChanged: *const anyopaque,
        remove_ColorValuesChanged: *const anyopaque,
    };
    vtable: *const VTable,
    IInspectable: win32.IInspectable,
    IUnknown: win32.IUnknown,
};

const iid_ui_settings3_value = win32.Guid.initString("03021BE4-5254-4781-8194-5168F7D06D7B");
const iid_ui_settings3 = &iid_ui_settings3_value;

test "Win32 color scheme classifies foreground colors as Microsoft documents" {
    const testing = std.testing;
    // Dark mode reports a white foreground; light mode a black one.
    try testing.expectEqual(apprt.ColorScheme.dark, schemeForForeground(.{ .a = 255, .r = 255, .g = 255, .b = 255 }));
    try testing.expectEqual(apprt.ColorScheme.light, schemeForForeground(.{ .a = 255, .r = 0, .g = 0, .b = 0 }));
    // 5 * 128 + 2 * 128 + 128 is exactly 8 * 128, which is not light.
    try testing.expect(!isColorLight(.{ .a = 255, .r = 128, .g = 128, .b = 128 }));
    try testing.expect(isColorLight(.{ .a = 255, .r = 128, .g = 129, .b = 128 }));
}

test "Win32 color scheme interface layout matches the SDK" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 4), @sizeOf(Color));
    // IInspectable has six slots; GetColorValue is the seventh.
    try testing.expectEqual(
        6 * @sizeOf(usize),
        @offsetOf(IUISettings3.VTable, "GetColorValue"),
    );
}
