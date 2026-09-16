//! Which ConPTY host we drive a Windows pty with.
//!
//! Windows ships a ConPTY in kernel32, and that host rebuilds the child's
//! output from a text screen buffer before handing it to us. Anything it
//! does not model is dropped on the way, and that includes APC
//! (`ESC _ ... ESC \`), the envelope the Kitty graphics protocol travels in.
//! A program running under that host cannot show us an image at all: the
//! escape never arrives, so there is nothing for the terminal to draw.
//!
//! The OpenConsole host from the Microsoft Terminal project passes those
//! sequences through untouched. It ships as `conpty.dll` plus its
//! `OpenConsole.exe` helper, placed next to the executable. So we prefer a
//! sideloaded pair when it is there, and fall back to kernel32 when it is
//! not, which is exactly what WezTerm does for the same reason.
//!
//! The DLL is loaded by its full path under our own executable, never by
//! bare name, so a `conpty.dll` sitting in the working directory can't be
//! picked up instead.

const std = @import("std");
const builtin = @import("builtin");
const windows = @import("windows.zig");

const log = std.log.scoped(.conpty);

/// The name of the sideloaded host. `OpenConsole.exe` has to sit beside it;
/// the DLL finds its helper relative to itself.
const dll_name = "conpty.dll";

/// The three entry points a pty needs. Resolved once, from one module, so a
/// console is always closed by the same host that created it.
pub const Functions = struct {
    CreatePseudoConsole: *const fn (
        size: windows.COORD,
        hInput: windows.HANDLE,
        hOutput: windows.HANDLE,
        dwFlags: windows.DWORD,
        phPC: *windows.HPCON,
    ) callconv(.winapi) windows.HRESULT,

    ResizePseudoConsole: *const fn (
        hPC: windows.HPCON,
        size: windows.COORD,
    ) callconv(.winapi) windows.HRESULT,

    ClosePseudoConsole: *const fn (
        hPC: windows.HPCON,
    ) callconv(.winapi) void,
};

/// The host Windows ships. Its entry points are known at compile time.
const kernel32_functions: Functions = .{
    .CreatePseudoConsole = &windows.exp.kernel32.CreatePseudoConsole,
    .ResizePseudoConsole = &windows.exp.kernel32.ResizePseudoConsole,
    .ClosePseudoConsole = &windows.exp.kernel32.ClosePseudoConsole,
};

/// Filled in by whichever thread wins `claimed`, and only read through
/// `active` afterwards.
var sideloaded_functions: Functions = undefined;

/// Elects the one thread that resolves.
var claimed: std.atomic.Value(bool) = .init(false);

/// The answer, once there is one.
var active: std.atomic.Value(?*const Functions) = .init(null);

/// The ConPTY entry points to use. Resolved on the first call and kept for
/// the life of the process; the returned pointer stays valid.
pub fn get() *const Functions {
    comptime assertWindows();

    if (active.load(.acquire)) |funcs| return funcs;

    // Unlike the usual "let both threads build one and drop the loser's"
    // pattern, every pty has to end up on the *same* host: a pseudoconsole
    // must be closed by whoever created it. So one thread resolves and the
    // rest wait for its answer. That wait is a LoadLibrary and three symbol
    // lookups long, and happens once per process.
    if (claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        while (true) {
            if (active.load(.acquire)) |funcs| return funcs;
            std.Thread.yield() catch {};
        }
    }

    const resolved = resolve();
    active.store(resolved, .release);
    return resolved;
}

fn assertWindows() void {
    if (builtin.os.tag != .windows) {
        @compileError("the ConPTY host is Windows-only");
    }
}

fn resolve() *const Functions {
    if (sideloaded()) |funcs| {
        sideloaded_functions = funcs;
        log.info("using the sideloaded {s} next to our executable", .{dll_name});
        return &sideloaded_functions;
    }

    // The kernel32 host drops APC, so Kitty graphics won't reach us. Say so
    // once, here, rather than leaving it to be rediscovered from a blank
    // window.
    log.info(
        "no {s} next to our executable, using the ConPTY in kernel32; " ++
            "programs that draw with the Kitty graphics protocol will not " ++
            "be able to show images",
        .{dll_name},
    );
    return &kernel32_functions;
}

/// Load `conpty.dll` from our own directory and resolve all three entry
/// points from it. Null if it isn't there or doesn't export the full set;
/// a partial set is no use, because the console has to be created and
/// closed by the same host.
fn sideloaded() ?Functions {
    var path_buf: [windows.MAX_PATH]u16 = undefined;
    const path = dllPath(&path_buf) orelse return null;

    const module = windows.exp.kernel32.LoadLibraryExW(
        path.ptr,
        null,
        // OpenConsole.exe is found relative to the DLL, so the DLL's own
        // directory has to lead the search.
        windows.LOAD_WITH_ALTERED_SEARCH_PATH,
    ) orelse {
        // Not being there is the normal case, so this isn't a warning.
        log.debug("no sideloaded {s}: {}", .{ dll_name, windows.GetLastError() });
        return null;
    };

    const funcs: Functions = .{
        .CreatePseudoConsole = @ptrCast(
            proc(module, "CreatePseudoConsole") orelse return null,
        ),
        .ResizePseudoConsole = @ptrCast(
            proc(module, "ResizePseudoConsole") orelse return null,
        ),
        .ClosePseudoConsole = @ptrCast(
            proc(module, "ClosePseudoConsole") orelse return null,
        ),
    };

    // The module is deliberately never freed: the function pointers outlive
    // this call and every pty that uses them.
    return funcs;
}

fn proc(module: windows.HMODULE, comptime name: [:0]const u8) ?windows.FARPROC {
    return windows.exp.kernel32.GetProcAddress(module, name.ptr) orelse {
        log.warn("{s} has no {s}, falling back to kernel32", .{ dll_name, name });
        return null;
    };
}

/// Write `<directory of our executable>\conpty.dll` into `buf`.
///
/// `MAX_PATH` is enough here and a longer path is not worth chasing: the
/// DLL has to sit beside an executable we already launched from, and the
/// fallback below it is a working ConPTY, not a failure.
fn dllPath(buf: []u16) ?[:0]const u16 {
    const written = windows.exp.kernel32.GetModuleFileNameW(
        null,
        buf.ptr,
        @intCast(buf.len),
    );
    // Zero is failure, and a full buffer means the path was truncated. Both
    // leave us without a path we can trust.
    if (written == 0 or written >= buf.len) {
        log.debug("could not read our own executable path", .{});
        return null;
    }

    const exe = buf[0..written];
    const sep = std.mem.lastIndexOfAny(u16, exe, &[_]u16{ '\\', '/' }) orelse {
        log.debug("our executable path has no directory", .{});
        return null;
    };

    // Overwrite the executable's own file name with the DLL's, in place.
    const dir_len = sep + 1;
    if (dir_len + dll_name.len >= buf.len) {
        log.debug("no room to build the {s} path", .{dll_name});
        return null;
    }
    for (dll_name, 0..) |c, i| buf[dir_len + i] = c;
    buf[dir_len + dll_name.len] = 0;

    return buf[0 .. dir_len + dll_name.len :0];
}

test "dllPath replaces the executable name" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    var buf: [windows.MAX_PATH]u16 = undefined;
    const path = dllPath(&buf) orelse return error.SkipZigTest;

    var utf8_buf: [windows.MAX_PATH * 3]u8 = undefined;
    const len = try std.unicode.utf16LeToUtf8(&utf8_buf, path);
    const utf8 = utf8_buf[0..len];

    try testing.expect(std.mem.endsWith(u8, utf8, "\\" ++ dll_name));
    try testing.expect(!std.mem.endsWith(u8, utf8, ".exe"));
}
