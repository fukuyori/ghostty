//! Native Windows backdrop effects for transparent DirectComposition windows.

const Backdrop = @This();

const win32 = @import("win32").everything;

/// Values from DWM_SYSTEMBACKDROP_TYPE. The system backdrop attribute is
/// intentionally declared locally so older Windows SDK bindings can still
/// build Ghostty; unsupported Windows versions reject the attribute at runtime.
pub const Kind = enum(i32) {
    none = 1,
    transient_window = 3,
};

pub const Error = error{SetSystemBackdrop};

/// Apply or remove the native transient-window backdrop. This corresponds to
/// the Windows Acrylic system material and lets DWM choose the exact effect.
pub fn set(hwnd: win32.HWND, kind: Kind) Error!void {
    var value: i32 = @intFromEnum(kind);
    const result = DwmSetWindowAttribute(
        hwnd,
        dwmwa_system_backdrop_type,
        &value,
        @sizeOf(@TypeOf(value)),
    );
    if (result < 0) return error.SetSystemBackdrop;
}

/// DWMWA_SYSTEMBACKDROP_TYPE is available at runtime on supported Windows
/// versions even when it isn't present in the SDK used for the Zig bindings.
const dwmwa_system_backdrop_type: u32 = 38;

extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: win32.HWND,
    attribute: u32,
    value: *const anyopaque,
    value_size: u32,
) callconv(.winapi) i32;

test "Win32 backdrop values match the DWM ABI" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(Kind.none));
    try std.testing.expectEqual(@as(i32, 3), @intFromEnum(Kind.transient_window));
    try std.testing.expectEqual(@as(u32, 38), dwmwa_system_backdrop_type);
}
