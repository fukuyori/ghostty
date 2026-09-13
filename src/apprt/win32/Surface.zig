/// Win32 surface - represents a terminal surface within a window.
/// Manages the WGL OpenGL context and provides the interface expected by
/// CoreSurface.
const Self = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const global = @import("../../global.zig");

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
    _: *Self,
    _: apprt.Clipboard,
    _: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    return .unsupported;
}

pub fn setClipboard(
    _: *Self,
    _: apprt.Clipboard,
    _: []const apprt.ClipboardContent,
    _: bool,
) !void {}

pub fn defaultTermioEnv(_: *Self) !std.process.Environ.Map {
    return try global.environMap();
}

pub fn redrawInspector(_: *Self) void {}
