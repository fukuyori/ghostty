/// Win32 application runtime for Ghostty. This is a minimal native Windows
/// application using the Win32 API with OpenGL rendering.
const App = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const input = @import("../../input.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32);

/// User-defined wakeup message sent via PostMessage to break out of
/// GetMessage and run the core app's tick.
const WM_WAKEUP = win32.WM_USER + 1;

core_app: *CoreApp,
config: *Config,
alloc: Allocator,
running: bool = true,
hwnd: ?win32.HWND = null,
surface: Surface = undefined,

/// Metadata from a text-producing keydown, merged into the following
/// WM_CHAR/WM_SYSCHAR event so the core receives one complete key event.
pending_text_key: ?PendingTextKey = null,

/// WM_CHAR transports supplementary Unicode characters as a UTF-16
/// surrogate pair, one message at a time.
pending_high_surrogate: ?u16 = null,

const PendingTextKey = struct {
    action: input.Action,
    key: input.Key,
    mods: input.Mods,
    unshifted_codepoint: u21,
};

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const alloc = core_app.alloc;
    var config = try Config.load(alloc);
    errdefer config.deinit();

    const config_ptr = try alloc.create(Config);
    config_ptr.* = config;

    self.* = .{
        .core_app = core_app,
        .config = config_ptr,
        .alloc = alloc,
    };

    try self.createWindow();
    try self.surface.init(self.hwnd.?);

    _ = win32.SetWindowLongPtrW(
        self.hwnd.?,
        win32.GWLP_USERDATA,
        @bitCast(@intFromPtr(self)),
    );

    try self.initCoreSurface();
}

pub fn run(self: *App) !void {
    log.info("starting Win32 event loop", .{});

    while (self.running) {
        var msg: win32.MSG = std.mem.zeroes(win32.MSG);
        const ret = win32.GetMessageW(&msg, null, 0, 0);
        if (ret == 0) {
            self.running = false;
            break;
        }
        if (ret == -1) {
            log.err("GetMessage failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            return error.Win32Error;
        }
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    self.surface.deinit();
    if (self.hwnd) |hwnd| {
        if (win32.DestroyWindow(hwnd) == 0) {
            log.warn("DestroyWindow failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
        self.hwnd = null;
    }
    self.config.deinit();
    self.alloc.destroy(self.config);
}

pub fn wakeup(self: *App) void {
    if (self.hwnd) |hwnd| {
        if (win32.PostMessageW(hwnd, WM_WAKEUP, 0, 0) == 0) {
            log.warn("PostMessage(WM_WAKEUP) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
    }
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    _ = self;
    _ = target;
    _ = value;

    switch (action) {
        .quit => {
            win32.PostQuitMessage(0);
            return true;
        },
        .new_window => return false,
        else => return false,
    }
}

pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}

pub fn redrawInspector(_: *App, surface: *Surface) void {
    surface.redrawInspector();
}

fn initCoreSurface(self: *App) !void {
    const alloc = self.alloc;
    self.surface.app = self;

    const core_surface = try alloc.create(CoreSurface);
    errdefer alloc.destroy(core_surface);

    try self.core_app.addSurface(&self.surface);
    errdefer self.core_app.deleteSurface(&self.surface);

    var config = try apprt.surface.newConfig(
        self.core_app,
        self.config,
        .window,
    );
    defer config.deinit();

    core_surface.init(
        alloc,
        &config,
        self.core_app,
        self,
        &self.surface,
    ) catch |err| {
        log.err("failed to initialize core surface: {}", .{err});
        return err;
    };

    self.surface.core_surface = core_surface;
    log.info("core surface initialized successfully", .{});
}

fn createWindow(self: *App) !void {
    const class_name = win32.L("GhosttyWindow");
    const hinstance = win32.GetModuleHandleW(null);

    const wc: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{ .HREDRAW = 1, .VREDRAW = 1, .OWNDC = 1 },
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };

    if (win32.RegisterClassExW(&wc) == 0) {
        log.err("RegisterClassExW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    self.hwnd = win32.CreateWindowExW(
        .{},
        class_name,
        win32.L("Ghostty"),
        win32.WS_OVERLAPPEDWINDOW,
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

    _ = win32.ShowWindow(self.hwnd.?, win32.SW_SHOWNORMAL);
    _ = win32.UpdateWindow(self.hwnd.?);
}

fn getApp(hwnd: win32.HWND) ?*App {
    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn getModifiers() input.Mods {
    var mods: input.Mods = .{};
    if (win32.GetKeyState(0x10) < 0) {
        mods.shift = true;
        mods.sides.shift = if (win32.GetKeyState(0xA1) < 0) .right else .left;
    }
    if (win32.GetKeyState(0x11) < 0) {
        mods.ctrl = true;
        mods.sides.ctrl = if (win32.GetKeyState(0xA3) < 0) .right else .left;
    }
    if (win32.GetKeyState(0x12) < 0) {
        mods.alt = true;
        mods.sides.alt = if (win32.GetKeyState(0xA5) < 0) .right else .left;
    }
    if (win32.GetKeyState(0x5B) < 0 or win32.GetKeyState(0x5C) < 0) {
        mods.super = true;
        mods.sides.super = if (win32.GetKeyState(0x5C) < 0) .right else .left;
    }

    mods.caps_lock = (win32.GetKeyState(0x14) & 1) != 0;
    mods.num_lock = (win32.GetKeyState(0x90) & 1) != 0;
    return mods;
}

fn keyAction(lparam: win32.LPARAM) input.Action {
    const bits: usize = @bitCast(lparam);
    return if ((bits & (@as(usize, 1) << 30)) != 0) .repeat else .press;
}

fn isExtendedKey(lparam: win32.LPARAM) bool {
    const bits: usize = @bitCast(lparam);
    return (bits & (@as(usize, 1) << 24)) != 0;
}

fn mapVirtualKey(vk: win32.WPARAM, lparam: win32.LPARAM) input.Key {
    return switch (vk) {
        0x41 => .key_a,
        0x42 => .key_b,
        0x43 => .key_c,
        0x44 => .key_d,
        0x45 => .key_e,
        0x46 => .key_f,
        0x47 => .key_g,
        0x48 => .key_h,
        0x49 => .key_i,
        0x4A => .key_j,
        0x4B => .key_k,
        0x4C => .key_l,
        0x4D => .key_m,
        0x4E => .key_n,
        0x4F => .key_o,
        0x50 => .key_p,
        0x51 => .key_q,
        0x52 => .key_r,
        0x53 => .key_s,
        0x54 => .key_t,
        0x55 => .key_u,
        0x56 => .key_v,
        0x57 => .key_w,
        0x58 => .key_x,
        0x59 => .key_y,
        0x5A => .key_z,
        0x30 => .digit_0,
        0x31 => .digit_1,
        0x32 => .digit_2,
        0x33 => .digit_3,
        0x34 => .digit_4,
        0x35 => .digit_5,
        0x36 => .digit_6,
        0x37 => .digit_7,
        0x38 => .digit_8,
        0x39 => .digit_9,
        0x08 => .backspace,
        0x09 => .tab,
        0x0D => if (isExtendedKey(lparam)) .numpad_enter else .enter,
        0x10 => if (((@as(usize, @bitCast(lparam)) >> 16) & 0xFF) == 0x36)
            .shift_right
        else
            .shift_left,
        0x11 => if (isExtendedKey(lparam)) .control_right else .control_left,
        0x12 => if (isExtendedKey(lparam)) .alt_right else .alt_left,
        0x13 => .pause,
        0x14 => .caps_lock,
        0x15 => .kana_mode,
        0x1B => .escape,
        0x1C => .convert,
        0x1D => .non_convert,
        0x20 => .space,
        0x21 => .page_up,
        0x22 => .page_down,
        0x23 => .end,
        0x24 => .home,
        0x25 => .arrow_left,
        0x26 => .arrow_up,
        0x27 => .arrow_right,
        0x28 => .arrow_down,
        0x2C => .print_screen,
        0x2D => .insert,
        0x2E => .delete,
        0x5B => .meta_left,
        0x5C => .meta_right,
        0x5D => .context_menu,
        0x60 => .numpad_0,
        0x61 => .numpad_1,
        0x62 => .numpad_2,
        0x63 => .numpad_3,
        0x64 => .numpad_4,
        0x65 => .numpad_5,
        0x66 => .numpad_6,
        0x67 => .numpad_7,
        0x68 => .numpad_8,
        0x69 => .numpad_9,
        0x6A => .numpad_multiply,
        0x6B => .numpad_add,
        0x6C => .numpad_separator,
        0x6D => .numpad_subtract,
        0x6E => .numpad_decimal,
        0x6F => .numpad_divide,
        0x70 => .f1,
        0x71 => .f2,
        0x72 => .f3,
        0x73 => .f4,
        0x74 => .f5,
        0x75 => .f6,
        0x76 => .f7,
        0x77 => .f8,
        0x78 => .f9,
        0x79 => .f10,
        0x7A => .f11,
        0x7B => .f12,
        0x7C => .f13,
        0x7D => .f14,
        0x7E => .f15,
        0x7F => .f16,
        0x80 => .f17,
        0x81 => .f18,
        0x82 => .f19,
        0x83 => .f20,
        0x84 => .f21,
        0x85 => .f22,
        0x86 => .f23,
        0x87 => .f24,
        0x90 => .num_lock,
        0x91 => .scroll_lock,
        0xBA => .semicolon,
        0xBB => .equal,
        0xBC => .comma,
        0xBD => .minus,
        0xBE => .period,
        0xBF => .slash,
        0xC0 => .backquote,
        0xDB => .bracket_left,
        0xDC => .backslash,
        0xDD => .bracket_right,
        0xDE => .quote,
        else => .unidentified,
    };
}

fn isTextVirtualKey(vk: win32.WPARAM) bool {
    return switch (vk) {
        0x30...0x39,
        0x41...0x5A,
        0x20,
        0xBA...0xC0,
        0xDB...0xDE,
        => true,
        else => false,
    };
}

fn isAltGr(mods: input.Mods) bool {
    return mods.ctrl and mods.alt and mods.sides.alt == .right;
}

fn shouldDispatchKeyPress(vk: win32.WPARAM, mods: input.Mods) bool {
    if (!isTextVirtualKey(vk)) return true;
    if (mods.super) return true;
    if (mods.alt and !isAltGr(mods)) return true;
    if (mods.ctrl and !isAltGr(mods)) return true;
    return false;
}

fn unshiftedCodepoint(vk: win32.WPARAM) u21 {
    return switch (vk) {
        0x41...0x5A => @intCast(vk + ('a' - 'A')),
        0x30...0x39 => @intCast(vk),
        0x20 => ' ',
        0xBA => ';',
        0xBB => '=',
        0xBC => ',',
        0xBD => '-',
        0xBE => '.',
        0xBF => '/',
        0xC0 => '`',
        0xDB => '[',
        0xDC => '\\',
        0xDD => ']',
        0xDE => '\'',
        else => 0,
    };
}

fn decodeUtf16CodeUnit(pending: *?u16, unit: u16) ?u21 {
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        pending.* = unit;
        return null;
    }

    if (unit >= 0xDC00 and unit <= 0xDFFF) {
        const high = pending.* orelse return null;
        pending.* = null;
        return 0x10000 +
            (@as(u21, high - 0xD800) << 10) +
            @as(u21, unit - 0xDC00);
    }

    pending.* = null;
    return unit;
}

fn handleTextInput(app: *App, wparam: win32.WPARAM) win32.LRESULT {
    const unit: u16 = @truncate(wparam);
    const codepoint = decodeUtf16CodeUnit(&app.pending_high_surrogate, unit) orelse
        return 0;
    defer app.pending_text_key = null;

    // Control characters are already represented by their WM_KEYDOWN event.
    if (codepoint < 0x20 or codepoint == 0x7F) return 0;

    const core = app.surface.core_surface orelse return 0;
    const pending = app.pending_text_key;
    const mods = if (pending) |value| value.mods else getModifiers();

    // Left-Alt shortcuts were dispatched as physical key events. WM_SYSCHAR
    // must not send a second text event for the same keystroke.
    if (mods.alt and !isAltGr(mods) and pending == null) return 0;

    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return 0;
    var consumed_mods: input.Mods = .{};
    if (isAltGr(mods)) {
        consumed_mods.ctrl = true;
        consumed_mods.alt = true;
    }

    const event: input.KeyEvent = .{
        .action = if (pending) |value| value.action else .press,
        .key = if (pending) |value| value.key else .unidentified,
        .mods = mods,
        .consumed_mods = consumed_mods,
        .utf8 = utf8_buf[0..len],
        .unshifted_codepoint = if (pending) |value|
            value.unshifted_codepoint
        else
            0,
    };
    _ = core.keyCallback(event) catch |err| {
        log.err("key callback error: {}", .{err});
    };
    return 0;
}

fn wndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_CLOSE => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_SIZE => {
            if (getApp(hwnd)) |app| {
                const width: u32 = @intCast(lparam & 0xFFFF);
                const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
                if (width > 0 and height > 0) {
                    app.surface.width = width;
                    app.surface.height = height;
                    if (app.surface.core_surface) |core| {
                        core.sizeCallback(.{
                            .width = width,
                            .height = height,
                        }) catch |err| {
                            log.err("size callback error: {}", .{err});
                        };
                    }
                }
            }
            return 0;
        },
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = std.mem.zeroes(win32.PAINTSTRUCT);
            _ = win32.BeginPaint(hwnd, &ps);
            if (getApp(hwnd)) |app| app.surface.swapBuffers();
            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        win32.WM_CHAR, win32.WM_SYSCHAR => {
            if (getApp(hwnd)) |app| return handleTextInput(app, wparam);
            return 0;
        },
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => {
            if (getApp(hwnd)) |app| {
                if (app.surface.core_surface) |core| {
                    const mods = getModifiers();
                    const key = mapVirtualKey(wparam, lparam);

                    if (!shouldDispatchKeyPress(wparam, mods)) {
                        app.pending_text_key = .{
                            .action = keyAction(lparam),
                            .key = key,
                            .mods = mods,
                            .unshifted_codepoint = unshiftedCodepoint(wparam),
                        };
                        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                    }

                    app.pending_text_key = null;
                    if (key != .unidentified) {
                        const effect = core.keyCallback(.{
                            .action = keyAction(lparam),
                            .key = key,
                            .mods = mods,
                            .unshifted_codepoint = unshiftedCodepoint(wparam),
                        }) catch |err| {
                            log.err("key callback error: {}", .{err});
                            return 0;
                        };
                        if (effect == .consumed or effect == .closed) return 0;
                    }
                }
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_KEYUP, win32.WM_SYSKEYUP => {
            if (getApp(hwnd)) |app| {
                if (app.surface.core_surface) |core| {
                    const key = mapVirtualKey(wparam, lparam);
                    if (key != .unidentified) {
                        _ = core.keyCallback(.{
                            .action = .release,
                            .key = key,
                            .mods = getModifiers(),
                            .unshifted_codepoint = unshiftedCodepoint(wparam),
                        }) catch |err| {
                            log.err("key release callback error: {}", .{err});
                        };
                    }
                }
            }
            return 0;
        },
        WM_WAKEUP => {
            if (getApp(hwnd)) |app| {
                app.core_app.tick(app) catch |err| {
                    log.err("core app tick failed: {}", .{err});
                };
            }
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

test "map Win32 virtual keys" {
    try std.testing.expectEqual(input.Key.key_a, mapVirtualKey(0x41, 0));
    try std.testing.expectEqual(input.Key.arrow_left, mapVirtualKey(0x25, 0));
    try std.testing.expectEqual(input.Key.numpad_enter, mapVirtualKey(0x0D, 1 << 24));
    try std.testing.expectEqual(input.Key.control_right, mapVirtualKey(0x11, 1 << 24));
    try std.testing.expectEqual(input.Key.unidentified, mapVirtualKey(0xFF, 0));
}

test "classify Win32 text keys" {
    try std.testing.expect(isTextVirtualKey(0x41));
    try std.testing.expect(isTextVirtualKey(0xDE));
    try std.testing.expect(!isTextVirtualKey(0x25));

    try std.testing.expectEqual(input.Action.press, keyAction(0));
    try std.testing.expectEqual(input.Action.repeat, keyAction(1 << 30));
    try std.testing.expectEqual(@as(u21, 'a'), unshiftedCodepoint(0x41));

    var altgr: input.Mods = .{ .ctrl = true, .alt = true };
    altgr.sides.alt = .right;
    try std.testing.expect(!shouldDispatchKeyPress(0x41, altgr));

    var left_alt: input.Mods = .{ .alt = true };
    left_alt.sides.alt = .left;
    try std.testing.expect(shouldDispatchKeyPress(0x41, left_alt));
}

test "decode Win32 UTF-16 input" {
    var pending: ?u16 = null;
    try std.testing.expectEqual(@as(?u21, 'A'), decodeUtf16CodeUnit(&pending, 'A'));
    try std.testing.expectEqual(@as(?u21, null), decodeUtf16CodeUnit(&pending, 0xD83D));
    try std.testing.expectEqual(@as(?u21, 0x1F600), decodeUtf16CodeUnit(&pending, 0xDE00));
    try std.testing.expectEqual(@as(?u16, null), pending);
}
