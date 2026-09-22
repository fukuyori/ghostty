/// Win32 surface - represents a terminal surface within a window.
/// Manages native renderer state and provides the interface expected by
/// CoreSurface.
const Self = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const build_config = @import("../../build_config.zig");
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");

const log = std.log.scoped(.win32_surface);
const App = @import("App.zig");
const Backdrop = @import("Backdrop.zig");

/// Child window used exclusively by the terminal renderer and input path.
hwnd: win32.HWND,

/// Top-level native window that owns this surface. Keeping these handles
/// separate allows additional child surfaces to share the same frame.
window_hwnd: win32.HWND,
app: ?*App = null,
hdc: ?win32.HDC = null,
hglrc: ?win32.HGLRC = null,
core_surface: ?*CoreSurface = null,
/// Successful renderer GPU resource rebuilds. This is observed only by the
/// opt-in Windows recovery regression hook.
gpu_recovery_count: std.atomic.Value(u32) = .init(0),
/// Controlled failures consumed by the renderer recovery regression hook.
gpu_recovery_failures_remaining: u32 = 0,
/// Renderer recovery cycles scheduled since the renderer was last healthy.
/// Each cycle is a bounded series of retries on the renderer thread; the
/// app stops scheduling new cycles once this reaches the configured limit.
gpu_recovery_cycles: u32 = 0,
/// True while a close request for this surface is queued in the message
/// loop. The core can ask to close a surface more than once before the
/// posted request runs; only the first request may be delivered.
close_requested: bool = false,
width: u32 = 800,
height: u32 = 600,
cursor_pos: apprt.CursorPos = .{ .x = 0, .y = 0 },
title: ?[:0]const u8 = null,
search_bar: ?*@import("SearchBar.zig") = null,
mouse_shape: terminal.MouseShape = .text,
mouse_visible: bool = true,

/// Adjustable Host Backdrop composition layer attached below this surface's
/// renderer target on the same child HWND.
background_blur: ?Backdrop = null,

/// Initial client size requested by the core. Later updates replace the
/// default used by reset_window_size without resizing an already visible
/// window.
initial_client_size: ?apprt.action.InitialSize = null,

/// True after the native window has been shown for the first time.
shown: bool = false,

/// Whether reset_window_size should return this window to a maximized state.
default_maximized: bool = false,

/// Whether a new window should enter native fullscreen after it is shown.
default_fullscreen: bool = false,

/// Current Win32 fullscreen state and the native state needed to restore the
/// window exactly, including a maximized pre-fullscreen placement.
fullscreen: bool = false,
windowed_style: ?u32 = null,
windowed_placement: ?win32.WINDOWPLACEMENT = null,

/// Desired decoration state. Fullscreen always hides decorations, but a
/// toggle made while fullscreen is applied when the window is restored.
decorated: bool = true,

/// Whether this window is currently in the Win32 topmost band.
always_on_top: bool = false,

/// Set only for windows hidden by the app-wide toggle_visibility action so a
/// second invocation doesn't reveal windows the user had hidden separately.
hidden_by_visibility_toggle: bool = false,

/// Identifies which hidden window should regain focus when app-wide
/// visibility is restored.
focused_before_visibility_toggle: bool = false,

/// Metadata from a text-producing keydown, merged into the following
/// WM_CHAR/WM_SYSCHAR event so the core receives one complete key event.
pending_text_key: ?PendingTextKey = null,

/// WM_CHAR transports supplementary Unicode characters as a UTF-16
/// surrogate pair, one message at a time.
pending_high_surrogate: ?u16 = null,

/// Buttons captured by this window. Keeping this separately from WPARAM lets
/// us release core state when Windows cancels capture unexpectedly.
mouse_buttons_down: u8 = 0,

/// Set when the core leaves a right press unconsumed, so the context menu
/// opens when the button is released.
context_menu_pending: bool = false,

/// True while TrackMouseEvent is waiting to deliver WM_MOUSELEAVE.
tracking_mouse_leave: bool = false,

/// WM_MOUSEHWHEEL may report partial wheel ticks. The core treats horizontal
/// non-precision events as whole ticks, so retain the remainder here.
horizontal_wheel_remainder: i32 = 0,

pub const PendingTextKey = struct {
    action: input.Action,
    key: input.Key,
    mods: input.Mods,
    unshifted_codepoint: u21,
};

pub fn core(self: *Self) *CoreSurface {
    return self.core_surface.?;
}

pub fn rtApp(self: *Self) *App {
    return self.app.?;
}

pub fn init(
    self: *Self,
    app: *App,
    window_hwnd: win32.HWND,
    hwnd: win32.HWND,
) !void {
    self.* = .{
        .hwnd = hwnd,
        .window_hwnd = window_hwnd,
        .app = app,
        .gpu_recovery_failures_remaining = app.test_device_recovery_failures,
    };
    errdefer self.deinit();
    self.updateClientSize();
    if (comptime build_config.renderer == .opengl) try self.initOpenGL();
}

pub fn deinit(self: *Self) void {
    if (self.search_bar) |bar| {
        bar.deinit();
        self.rtApp().alloc.destroy(bar);
        self.search_bar = null;
    }
    if (self.core_surface) |surface| {
        const app = self.rtApp();
        app.core_app.deleteSurface(self);
        surface.deinit();
        app.alloc.destroy(surface);
        self.core_surface = null;
    }
    if (self.background_blur) |*backdrop| {
        backdrop.deinit();
        self.background_blur = null;
    }
    if (self.title) |title| {
        self.rtApp().alloc.free(title);
        self.title = null;
    }
    if (self.hglrc) |hglrc| {
        _ = win32.wglMakeCurrent(null, null);
        _ = win32.wglDeleteContext(hglrc);
        self.hglrc = null;
    }
    if (self.hdc) |hdc| {
        _ = win32.ReleaseDC(self.hwnd, hdc);
        self.hdc = null;
    }
}

fn updateClientSize(self: *Self) void {
    var rect: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(self.hwnd, &rect) == 0) {
        log.warn("GetClientRect failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return;
    }

    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;
    if (width > 0 and height > 0) {
        self.width = @intCast(width);
        self.height = @intCast(height);
    }
}

fn initOpenGL(self: *Self) !void {
    self.hdc = win32.GetDC(self.hwnd) orelse {
        log.err("GetDC failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };

    var pfd: win32.PIXELFORMATDESCRIPTOR = std.mem.zeroes(win32.PIXELFORMATDESCRIPTOR);
    pfd.nSize = @sizeOf(win32.PIXELFORMATDESCRIPTOR);
    pfd.nVersion = 1;
    pfd.dwFlags = .{ .DRAW_TO_WINDOW = 1, .SUPPORT_OPENGL = 1, .DOUBLEBUFFER = 1 };
    pfd.iPixelType = .RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;
    pfd.iLayerType = .MAIN_PLANE;

    const pixel_format = win32.ChoosePixelFormat(self.hdc, &pfd);
    if (pixel_format == 0) {
        log.err("ChoosePixelFormat failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    if (win32.SetPixelFormat(self.hdc, pixel_format, &pfd) == 0) {
        log.err("SetPixelFormat failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    self.hglrc = win32.wglCreateContext(self.hdc) orelse {
        log.err("wglCreateContext failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };

    if (win32.wglMakeCurrent(self.hdc, self.hglrc) == 0) {
        log.err("wglMakeCurrent failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    self.updateViewport();
}

pub fn swapBuffers(self: *Self) void {
    if (comptime build_config.renderer != .opengl) return;
    if (self.hdc) |hdc| {
        if (win32.SwapBuffers(hdc) == 0) {
            log.warn("SwapBuffers failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
    }
}

/// Keep the default framebuffer viewport synchronized with the drawable
/// client area. The renderer thread calls this while it owns the WGL context.
pub fn updateViewport(self: *const Self) void {
    if (comptime build_config.renderer != .opengl) return;
    win32.glViewport(
        0,
        0,
        @intCast(self.width),
        @intCast(self.height),
    );
}

pub fn makeContextCurrent(self: *Self) void {
    if (comptime build_config.renderer != .opengl) return;
    if (self.hdc) |hdc| {
        if (self.hglrc) |hglrc| {
            if (win32.wglMakeCurrent(hdc, hglrc) == 0) {
                log.warn("wglMakeCurrent failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            }
        }
    }
}

pub fn releaseContext() void {
    if (comptime build_config.renderer != .opengl) return;
    if (win32.wglMakeCurrent(null, null) == 0) {
        log.warn("wglMakeCurrent(null) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    }
}

pub fn releaseMainThreadContext(_: *Self) void {
    releaseContext();
}

pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    const dpi = win32.GetDpiForWindow(self.window_hwnd);
    if (dpi == 0) {
        log.warn("GetDpiForWindow failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return .{ .x = 1.0, .y = 1.0 };
    }
    return contentScaleForDpi(dpi, dpi);
}

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    return .{ .width = self.width, .height = self.height };
}

pub fn getCursorPos(self: *const Self) !apprt.CursorPos {
    return self.cursor_pos;
}

pub fn getTitle(self: *Self) ?[:0]const u8 {
    return self.title;
}

pub fn setTitle(self: *Self, value: [:0]const u8) !void {
    const alloc = self.rtApp().alloc;
    const title = try alloc.dupeZ(u8, value);
    errdefer alloc.free(title);

    if (self.title) |old| alloc.free(old);
    self.title = title;
    self.rtApp().tabTitleChanged(self);
    if (self.rtApp().surfaceIsFocused(self)) self.syncTitle();
}

/// Apply this surface's title to its shared top-level window. Background
/// splits retain their titles without replacing the focused split's title.
pub fn syncTitle(self: *Self) void {
    self.rtApp().syncWindowTitle(self);
}

pub fn applyTitle(self: *Self, value: [:0]const u8) !void {
    const alloc = self.rtApp().alloc;
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, value);
    defer alloc.free(wide);
    if (win32.SetWindowTextW(self.window_hwnd, wide) == 0) {
        log.err("SetWindowTextW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }
}

pub fn close(self: *Self, confirm: bool) void {
    self.rtApp().requestSurfaceClose(self, confirm);
}

pub fn windowHwnd(self: *const Self) win32.HWND {
    return self.window_hwnd;
}

pub fn supportsClipboard(_: *Self, clipboard: apprt.Clipboard) bool {
    return clipboard == .standard;
}

pub fn clipboardRequest(
    self: *Self,
    clipboard: apprt.Clipboard,
    req: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    if (!self.supportsClipboard(clipboard)) return .unsupported;

    // Kitty writes carry their contents in the request and don't need to
    // inspect the clipboard before entering the permission flow.
    if (req == .kitty_write) {
        self.completeClipboardRequest(req, &.{}, &.{});
        return .started;
    }

    const format: u32 = @intFromEnum(win32.CF_UNICODETEXT);
    if (win32.IsClipboardFormatAvailable(format) == 0) return .unavailable;

    // Paste events only need a MIME listing, not the clipboard contents.
    if (req == .list) {
        self.completeClipboardRequest(req, &.{}, &.{"text/plain"});
        return .started;
    }

    const alloc = self.core().alloc;
    const text = text: {
        if (!self.openClipboard()) {
            log.warn("OpenClipboard failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            return .unavailable;
        }
        defer if (win32.CloseClipboard() == 0) {
            log.warn("CloseClipboard failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        };

        const handle = win32.GetClipboardData(format) orelse {
            log.warn("GetClipboardData failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            return .unavailable;
        };
        const hglobal: isize = @bitCast(@intFromPtr(handle));
        const raw = win32.GlobalLock(hglobal) orelse {
            log.warn("GlobalLock failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            return .unavailable;
        };
        defer _ = win32.GlobalUnlock(hglobal);

        const byte_len = win32.GlobalSize(hglobal);
        if (byte_len < @sizeOf(u16)) return .unavailable;
        const wide_ptr: [*]const u16 = @ptrCast(@alignCast(raw));
        const wide_all = wide_ptr[0 .. byte_len / @sizeOf(u16)];
        const wide_len = std.mem.indexOfScalar(u16, wide_all, 0) orelse {
            log.warn("CF_UNICODETEXT data is not null terminated", .{});
            return .unavailable;
        };
        const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, wide_all[0..wide_len]) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                log.warn("clipboard contains invalid UTF-16: {}", .{err});
                return .unavailable;
            },
        };
        defer alloc.free(utf8);

        break :text try normalizeClipboardRead(alloc, utf8);
    };
    defer alloc.free(text);

    // The clipboard must be closed before a confirmation dialog is shown.
    const contents = [_]terminal.clipboard.Content{.{
        .mime = "text/plain",
        .data = text,
    }};
    self.completeClipboardRequest(req, &contents, &.{"text/plain"});
    return .started;
}

fn openClipboard(self: *Self) bool {
    for (0..5) |attempt| {
        if (win32.OpenClipboard(self.window_hwnd) != 0) return true;
        if (attempt < 4) win32.Sleep(5);
    }
    return false;
}

pub fn setClipboard(
    self: *Self,
    clipboard: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    if (!self.supportsClipboard(clipboard)) return error.UnsupportedClipboard;
    if (confirm and !self.confirmClipboardAccess(.write)) return;

    const text = clipboardTextContent(contents);
    if (contents.len > 0 and text == null) return error.UnsupportedClipboardContent;

    var hglobal: isize = 0;
    defer {
        if (hglobal != 0) _ = win32.GlobalFree(hglobal);
    }
    if (text) |value| {
        const alloc = self.core().alloc;
        const normalized = try normalizeClipboardWrite(alloc, value);
        defer alloc.free(normalized);

        const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, normalized);
        defer alloc.free(utf16);

        hglobal = win32.GlobalAlloc(
            win32.GMEM_MOVEABLE,
            (utf16.len + 1) * @sizeOf(u16),
        );
        if (hglobal == 0) {
            log.err("GlobalAlloc failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            return error.Win32Clipboard;
        }

        const raw = win32.GlobalLock(hglobal) orelse {
            log.err("GlobalLock failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            return error.Win32Clipboard;
        };
        const dst: [*]u16 = @ptrCast(@alignCast(raw));
        @memcpy(dst[0 .. utf16.len + 1], utf16.ptr[0 .. utf16.len + 1]);
        _ = win32.GlobalUnlock(hglobal);
    }

    if (!self.openClipboard()) {
        log.warn("OpenClipboard failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Clipboard;
    }
    defer if (win32.CloseClipboard() == 0) {
        log.warn("CloseClipboard failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    };

    if (win32.EmptyClipboard() == 0) {
        log.err("EmptyClipboard failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Clipboard;
    }

    // No representations means clear the destination clipboard.
    if (text == null) return;

    const handle: win32.HANDLE = @ptrFromInt(@as(usize, @bitCast(hglobal)));
    if (win32.SetClipboardData(@intFromEnum(win32.CF_UNICODETEXT), handle) == null) {
        log.err("SetClipboardData failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Clipboard;
    }

    // SetClipboardData transfers ownership to Windows on success.
    hglobal = 0;
}

const ClipboardAccess = enum { read, write };

fn completeClipboardRequest(
    self: *Self,
    req: apprt.ClipboardRequest,
    contents: []const terminal.clipboard.Content,
    available: []const []const u8,
) void {
    self.core().completeClipboardRequest(req, .{
        .contents = contents,
        .available = available,
    }) catch |err| switch (err) {
        error.UnsafePaste, error.UnauthorizedPaste => {
            const access: ClipboardAccess = switch (req) {
                .osc_52_write, .kitty_write => .write,
                else => .read,
            };
            if (!self.confirmClipboardAccess(access)) {
                self.core().denyClipboardRequest(req);
                return;
            }

            self.core().completeClipboardRequest(req, .{
                .contents = contents,
                .available = available,
                .confirmed = true,
            }) catch |complete_err| {
                log.err("failed to complete confirmed clipboard request: {}", .{complete_err});
            };
        },

        else => log.err("failed to complete clipboard request: {}", .{err}),
    };
}

fn confirmClipboardAccess(self: *Self, access: ClipboardAccess) bool {
    const caption = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty clipboard access");
    const message = switch (access) {
        .read => std.unicode.utf8ToUtf16LeStringLiteral(
            "Clipboard access was requested. Allow clipboard contents to be pasted or read?",
        ),
        .write => std.unicode.utf8ToUtf16LeStringLiteral(
            "A terminal program requested permission to write to the clipboard. Allow it?",
        ),
    };
    const style: win32.MESSAGEBOX_STYLE = .{
        .YESNO = 1,
        .ICONHAND = 1,
        .ICONQUESTION = 1,
    };
    return win32.MessageBoxW(self.window_hwnd, message, caption, style) == win32.IDYES;
}

fn clipboardTextContent(contents: []const apprt.ClipboardContent) ?[]const u8 {
    for (contents) |content| {
        if (terminal.clipboard.isTextMime(content.mime)) return content.data;
    }
    return null;
}

/// Convert Windows clipboard line endings to the terminal's LF convention.
fn normalizeClipboardRead(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var len = text.len;
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] == '\r' and text[i + 1] == '\n') {
            len -= 1;
            i += 1;
        }
    }

    const result = try alloc.alloc(u8, len);
    i = 0;
    var out: usize = 0;
    while (i < text.len) {
        if (text[i] == '\r') {
            result[out] = '\n';
            out += 1;
            i += 1;
            if (i < text.len and text[i] == '\n') i += 1;
        } else {
            result[out] = text[i];
            out += 1;
            i += 1;
        }
    }
    return result;
}

/// Convert LF or CR line endings to the CRLF convention used by CF_UNICODETEXT.
fn normalizeClipboardWrite(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var len = text.len;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\r') {
            len += @intFromBool(i + 1 >= text.len or text[i + 1] != '\n');
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
        } else if (text[i] == '\n') {
            len += 1;
        }
        i += 1;
    }

    const result = try alloc.alloc(u8, len);
    i = 0;
    var out: usize = 0;
    while (i < text.len) {
        if (text[i] == '\r') {
            result[out] = '\r';
            result[out + 1] = '\n';
            out += 2;
            i += 1;
            if (i < text.len and text[i] == '\n') i += 1;
        } else if (text[i] == '\n') {
            result[out] = '\r';
            result[out + 1] = '\n';
            out += 2;
            i += 1;
        } else {
            result[out] = text[i];
            out += 1;
            i += 1;
        }
    }
    return result;
}

pub fn defaultTermioEnv(_: *Self) !std.process.Environ.Map {
    return try global.environMap();
}

pub fn redrawInspector(_: *Self) void {}

fn contentScaleForDpi(x: u32, y: u32) apprt.ContentScale {
    const default_dpi: f32 = @floatFromInt(win32.USER_DEFAULT_SCREEN_DPI);
    return .{
        .x = @as(f32, @floatFromInt(x)) / default_dpi,
        .y = @as(f32, @floatFromInt(y)) / default_dpi,
    };
}

test "Win32 clipboard normalizes line endings when reading" {
    const value = try normalizeClipboardRead(std.testing.allocator, "a\r\nb\rc\nd");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("a\nb\nc\nd", value);
}

test "Win32 clipboard normalizes line endings when writing" {
    const value = try normalizeClipboardWrite(std.testing.allocator, "a\r\nb\rc\nd");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("a\r\nb\r\nc\r\nd", value);
}

test "Win32 clipboard selects the first text representation" {
    const contents = [_]apprt.ClipboardContent{
        .{ .mime = "image/png", .data = "binary" },
        .{ .mime = "UTF8_STRING", .data = "text" },
    };
    try std.testing.expectEqualStrings("text", clipboardTextContent(&contents).?);
}

test "Win32 content scale follows monitor DPI" {
    try std.testing.expectEqual(
        apprt.ContentScale{ .x = 1.0, .y = 1.0 },
        contentScaleForDpi(96, 96),
    );
    try std.testing.expectEqual(
        apprt.ContentScale{ .x = 1.5, .y = 2.0 },
        contentScaleForDpi(144, 192),
    );
}
