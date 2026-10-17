//! Win32 class registration, icons, creation styles, and raw HWND creation.
//! App supplies the window procedures and owns userdata and HWND lifetimes.

const std = @import("std");
const TestHooks = @import("LifecycleTestHooks.zig");
const win32 = @import("win32").everything;
const build_config = @import("../../build_config.zig");
const brand = @import("../../brand.zig");

const log = std.log.scoped(.win32);

pub const Procedures = struct {
    window: win32.WNDPROC,
    tab_bar: win32.WNDPROC,
    split_divider: win32.WNDPROC,
    wakeup: win32.WNDPROC,
};

pub const window_class_name = win32.L(brand.windows.window_class_prefix ++ "Window");
const tab_bar_class_name = win32.L(brand.windows.window_class_prefix ++ "TabBar");
const split_divider_class_name = win32.L(brand.windows.window_class_prefix ++ "SplitDivider");
const wakeup_class_name = win32.L(brand.windows.window_class_prefix ++ "Wakeup");

/// Parent handle that creates a message-only window. Message-only windows
/// never appear on screen and exist so that posted messages are delivered
/// through DispatchMessage, including from inside modal loops.
const hwnd_message: win32.HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

const default_window_title = win32.L(brand.display_name);
const icon_resource_id: usize = 1;

pub fn createWakeup() !win32.HWND {
    const hinstance = win32.GetModuleHandleW(null);
    const hwnd = win32.CreateWindowExW(
        .{},
        wakeup_class_name,
        win32.L(""),
        .{},
        0,
        0,
        0,
        0,
        hwnd_message,
        null,
        hinstance,
        null,
    ) orelse {
        log.err("CreateWindowExW(wakeup) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };
    return hwnd;
}

pub fn registerClasses(procedures: Procedures) !void {
    const hinstance = win32.GetModuleHandleW(null) orelse {
        log.err("GetModuleHandleW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };
    const icons = loadWindowIcons(hinstance);

    const wc: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = if (build_config.renderer == .opengl)
            .{ .HREDRAW = 1, .VREDRAW = 1, .OWNDC = 1 }
        else
            .{ .HREDRAW = 1, .VREDRAW = 1 },
        .lpfnWndProc = procedures.window,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = icons.large,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = window_class_name,
        .hIconSm = icons.small,
    };

    if (win32.RegisterClassExW(&wc) == 0) {
        log.err("RegisterClassExW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    const tab_bar_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{ .HREDRAW = 1, .VREDRAW = 1, .DBLCLKS = 1 },
        .lpfnWndProc = procedures.tab_bar,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = tab_bar_class_name,
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&tab_bar_class) == 0) {
        log.err("RegisterClassExW(tab bar) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    const split_divider_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{ .HREDRAW = 1, .VREDRAW = 1 },
        .lpfnWndProc = procedures.split_divider,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = split_divider_class_name,
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&split_divider_class) == 0) {
        log.err("RegisterClassExW(split divider) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    const wakeup_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{},
        .lpfnWndProc = procedures.wakeup,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = wakeup_class_name,
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&wakeup_class) == 0) {
        log.err("RegisterClassExW(wakeup) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }
}

const WindowIcons = struct {
    large: ?win32.HICON,
    small: ?win32.HICON,
};

/// Load the embedded application icon at the system large and small sizes.
/// A missing or unreadable icon resource is not fatal: the window class falls
/// back to the Windows default icon so the terminal still starts. Executables
/// without the Windows resource script, such as the unit test binary, take
/// this path.
fn loadWindowIcons(hinstance: win32.HINSTANCE) WindowIcons {
    const large_width = @max(1, win32.GetSystemMetrics(win32.SM_CXICON));
    const large_height = @max(1, win32.GetSystemMetrics(win32.SM_CYICON));
    const small_width = @max(1, win32.GetSystemMetrics(win32.SM_CXSMICON));
    const small_height = @max(1, win32.GetSystemMetrics(win32.SM_CYSMICON));

    const large = loadWindowIcon(hinstance, large_width, large_height) catch null;
    const small = loadWindowIcon(hinstance, small_width, small_height) catch null;
    if (large == null or small == null) {
        log.warn(
            "embedded window icon unavailable; using the Windows default icon",
            .{},
        );
    }

    return .{ .large = large, .small = small };
}

fn loadWindowIcon(
    hinstance: win32.HINSTANCE,
    width: i32,
    height: i32,
) !win32.HICON {
    const handle = win32.LoadImageW(
        hinstance,
        @ptrFromInt(icon_resource_id),
        .ICON,
        width,
        height,
        .{ .SHARED = 1 },
    ) orelse {
        log.warn("LoadImageW(icon {d}x{d}) failed: err={d}", .{
            width,
            height,
            @intFromEnum(win32.GetLastError()),
        });
        return error.Win32Error;
    };
    return @ptrCast(handle);
}

pub fn createWindow() !win32.HWND {
    return createTopLevel(nativeWindowExStyle(), topLevelWindowStyle());
}

/// Captionless popup used by the quick terminal. The caller supplies the
/// extended style (tool window, topmost, optional no-activate) and places
/// the window before showing it.
pub fn createQuickWindow(ex_style: win32.WINDOW_EX_STYLE) !win32.HWND {
    const popup: u32 = 0x80000000;
    const clip_children: u32 = 0x02000000;
    return createTopLevel(ex_style, @bitCast(popup | clip_children));
}

/// Base extended style for top-level windows; see nativeWindowExStyle.
pub fn baseExStyle() win32.WINDOW_EX_STYLE {
    return nativeWindowExStyle();
}

fn createTopLevel(ex_style: win32.WINDOW_EX_STYLE, style: win32.WINDOW_STYLE) !win32.HWND {
    try TestHooks.fail(.parent_hwnd);
    const hinstance = win32.GetModuleHandleW(null);

    return win32.CreateWindowExW(
        ex_style,
        window_class_name,
        default_window_title,
        style,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        800,
        600,
        null,
        null,
        hinstance,
        null,
    ) orelse {
        log.err("CreateWindowExW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };
}

pub fn createSurface(window_hwnd: win32.HWND) !win32.HWND {
    try TestHooks.fail(.child_hwnd);
    const hinstance = win32.GetModuleHandleW(null);
    var rect: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(window_hwnd, &rect) == 0) {
        log.err("GetClientRect for surface failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    return win32.CreateWindowExW(
        nativeWindowExStyle(),
        window_class_name,
        default_window_title,
        surfaceWindowStyle(),
        0,
        0,
        @max(1, rect.right - rect.left),
        @max(1, rect.bottom - rect.top),
        window_hwnd,
        null,
        hinstance,
        null,
    ) orelse {
        log.err("CreateWindowExW(surface) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };
}

pub fn createTabBar(window_hwnd: win32.HWND) !win32.HWND {
    try TestHooks.fail(.tab_bar_hwnd);
    const popup: u32 = 0x80000000;
    const clip_siblings: u32 = 0x04000000;
    const hwnd = win32.CreateWindowExW(
        .{ .TOOLWINDOW = 1, .NOACTIVATE = 1 },
        tab_bar_class_name,
        win32.L(""),
        @bitCast(popup | clip_siblings),
        0,
        0,
        1,
        1,
        window_hwnd,
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse {
        log.err("CreateWindowExW(tab bar) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };
    errdefer _ = win32.DestroyWindow(hwnd);
    return hwnd;
}

pub fn createSplitDivider(window_hwnd: win32.HWND) !win32.HWND {
    const popup: u32 = 0x80000000;
    const clip_siblings: u32 = 0x04000000;
    return win32.CreateWindowExW(
        .{ .TOOLWINDOW = 1, .NOACTIVATE = 1, .TRANSPARENT = 1 },
        split_divider_class_name,
        win32.L(""),
        @bitCast(popup | clip_siblings),
        0,
        0,
        1,
        1,
        window_hwnd,
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse {
        log.warn("CreateWindowExW(split divider) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };
}

fn topLevelWindowStyle() win32.WINDOW_STYLE {
    const clip_children: u32 = 0x02000000;
    return @bitCast(@as(u32, @bitCast(win32.WS_OVERLAPPEDWINDOW)) | clip_children);
}

fn surfaceWindowStyle() win32.WINDOW_STYLE {
    const child: u32 = 0x40000000;
    const visible: u32 = 0x10000000;
    const clip_siblings: u32 = 0x04000000;
    return @bitCast(child | visible | clip_siblings);
}

/// DirectComposition owns the complete client-area visual tree. Disabling the
/// legacy redirected bitmap lets the swap chain's premultiplied alpha reach
/// the desktop compositor instead of being flattened against an HWND surface.
fn nativeWindowExStyle() win32.WINDOW_EX_STYLE {
    return if (build_config.renderer == .d3d11)
        .{ .NOREDIRECTIONBITMAP = 1 }
    else
        .{};
}

test "Win32 D3D11 windows bypass the legacy redirect bitmap" {
    const style = nativeWindowExStyle();
    try std.testing.expectEqual(
        @as(u1, @intFromBool(build_config.renderer == .d3d11)),
        style.NOREDIRECTIONBITMAP,
    );
}

test "Win32 window icons fall back without an embedded resource" {
    // The unit test executable does not link the Windows resource script,
    // so the icon lookup must degrade to the default icon instead of
    // failing window class registration.
    const hinstance = win32.GetModuleHandleW(null) orelse return error.Win32Error;
    const icons = loadWindowIcons(hinstance);
    try std.testing.expect(icons.large == null);
    try std.testing.expect(icons.small == null);
}
