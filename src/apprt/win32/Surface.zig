/// Win32 surface - represents a terminal surface within a window.
/// Manages the WGL OpenGL context and provides the interface expected by
/// CoreSurface.
const Self = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const global = @import("../../global.zig");
const terminal = @import("../../terminal/main.zig");

const log = std.log.scoped(.win32_surface);
const App = @import("App.zig");

hwnd: win32.HWND,
app: ?*App = null,
hdc: ?win32.HDC = null,
hglrc: ?win32.HGLRC = null,
core_surface: ?*CoreSurface = null,
width: u32 = 800,
height: u32 = 600,

pub fn core(self: *Self) *CoreSurface {
    return self.core_surface.?;
}

pub fn rtApp(self: *Self) *App {
    return self.app.?;
}

pub fn init(self: *Self, hwnd: win32.HWND) !void {
    self.* = .{ .hwnd = hwnd };
    try self.initOpenGL();
}

pub fn deinit(self: *Self) void {
    if (self.core_surface) |surface| surface.deinit();
    if (self.hglrc) |hglrc| {
        _ = win32.wglMakeCurrent(null, null);
        _ = win32.wglDeleteContext(hglrc);
    }
    if (self.hdc) |hdc| _ = win32.ReleaseDC(self.hwnd, hdc);
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
}

pub fn swapBuffers(self: *Self) void {
    if (self.hdc) |hdc| {
        if (win32.SwapBuffers(hdc) == 0) {
            log.warn("SwapBuffers failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
    }
}

pub fn makeContextCurrent(self: *Self) void {
    if (self.hdc) |hdc| {
        if (self.hglrc) |hglrc| {
            if (win32.wglMakeCurrent(hdc, hglrc) == 0) {
                log.warn("wglMakeCurrent failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            }
        }
    }
}

pub fn releaseContext() void {
    if (win32.wglMakeCurrent(null, null) == 0) {
        log.warn("wglMakeCurrent(null) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    }
}

pub fn releaseMainThreadContext(_: *Self) void {
    releaseContext();
}

pub fn getContentScale(_: *const Self) !apprt.ContentScale {
    return .{ .x = 1.0, .y = 1.0 };
}

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    return .{ .width = self.width, .height = self.height };
}

pub fn getCursorPos(_: *const Self) !apprt.CursorPos {
    return .{ .x = 0, .y = 0 };
}

pub fn getTitle(_: *Self) ?[:0]const u8 {
    return null;
}

pub fn close(_: *Self, _: bool) void {}

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
        if (win32.OpenClipboard(self.hwnd) != 0) return true;
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
    return win32.MessageBoxW(self.hwnd, message, caption, style) == win32.IDYES;
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
