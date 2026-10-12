//! Opening URLs and files with the Windows shell, including the safety
//! policy for links that come from terminal output (OSC 8).

const std = @import("std");
const brand = @import("../../brand.zig");
const win32 = @import("win32").everything;
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");

const log = std.log.scoped(.win32);

/// `open_url` requests waiting for `drain`. Owned by `App`.
pub const Queue = std.ArrayListUnmanaged(Request);

const Request = struct {
    kind: apprt.action.OpenUrl.Kind,
    url: []u8,
    parent: ?win32.HWND,
};

/// Queue an `open_url` request for `drain`.
///
/// The core calls `open_url` from `processLinks` with the renderer state
/// mutex held. The policy dialogs and the shell both run modal or message
/// loops, and a message dispatched there (focus, keys) re-enters the core,
/// which locks the same mutex on the same thread and deadlocks (#36). So
/// nothing here may wait on the UI thread; the request runs after the core
/// callback has returned.
pub fn openUrl(
    self: *App,
    target: apprt.Target,
    value: apprt.action.OpenUrl,
) bool {
    // OSC 8 targets must never reach the unrestricted core fallback, so even
    // a request that cannot be queued reports that it was handled.
    const handled_on_failure = value.kind == .osc8;

    const url = self.alloc.dupe(u8, value.url) catch |err| {
        log.warn("failed to queue URL: {}", .{err});
        return handled_on_failure;
    };
    self.pending_opens.append(self.alloc, .{
        .kind = value.kind,
        .url = url,
        .parent = actionParentWindow(self, target),
    }) catch |err| {
        self.alloc.free(url);
        log.warn("failed to queue URL: {}", .{err});
        return handled_on_failure;
    };

    armDrainTimer(self);
    return true;
}

/// Timer on the wakeup window that keeps the outermost message loop
/// returning until `drain` has run. A single posted wakeup is not enough: a
/// modal loop (moving or sizing a window, for example) may dispatch it, and
/// when that loop was entered from a message sent to `GetMessageW`, nothing
/// may be left to make the outer `GetMessageW` return. The timer keeps
/// firing until `drain` stops it.
const drain_timer_id: usize = 0x3601;
const drain_timer_ms: u32 = 50;

fn armDrainTimer(self: *App) void {
    if (self.wakeup_hwnd) |hwnd| {
        if (win32.SetTimer(hwnd, drain_timer_id, drain_timer_ms, null) != 0) return;
        log.warn("SetTimer for queued URLs failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
    }
    self.wakeup();
}

/// Run the queued `open_url` requests. Called only from the outermost
/// message loop, never from a window procedure or a modal loop, so the core
/// holds no lock here. A request queued while a dialog below is open runs in
/// the same call.
pub fn drain(self: *App) void {
    if (self.pending_opens.items.len == 0) return;
    defer if (self.wakeup_hwnd) |hwnd| {
        _ = win32.KillTimer(hwnd, drain_timer_id);
    };

    while (self.pending_opens.items.len > 0) {
        // Once the application is quitting, open nothing more, even if a
        // dialog below let the quit request in.
        var msg: win32.MSG = undefined;
        if (win32.PeekMessageW(
            &msg,
            null,
            win32.WM_QUIT,
            win32.WM_QUIT,
            .{},
        ) != 0) {
            log.info("discarding {d} queued URLs at quit", .{self.pending_opens.items.len});
            discardPending(self);
            return;
        }

        const request = self.pending_opens.orderedRemove(0);
        defer self.alloc.free(request.url);
        openQueuedUrl(self, request);
    }
}

/// Free queued requests without running them.
pub fn discardPending(self: *App) void {
    for (self.pending_opens.items) |request| self.alloc.free(request.url);
    self.pending_opens.deinit(self.alloc);
    self.pending_opens = .empty;
}

fn openQueuedUrl(self: *App, request: Request) void {
    // The window may have closed since the request was queued.
    const parent = if (request.parent) |hwnd|
        if (ownsWindow(self, hwnd)) hwnd else null
    else
        null;

    if (request.kind != .osc8) {
        shellOpen(self, request.url) catch |err| {
            log.warn("failed to open URL: {}", .{err});
        };
        return;
    }

    switch (classifyUntrustedUrl(request.url)) {
        .allow => shellOpen(self, request.url) catch |err| {
            log.warn("failed to open trusted OSC 8 URL: {}", .{err});
        },
        .confirm => if (confirmUntrustedUrl(self, parent, request.url)) {
            shellOpen(self, request.url) catch |err| {
                log.warn("failed to open confirmed OSC 8 URL: {}", .{err});
            };
        },
        .deny => |reason| showBlockedUrl(self, parent, reason, request.url),
    }
}

/// Whether `hwnd` is still one of our windows. A closed window's handle can
/// be reused by a newer Ghostty window, which then parents the dialog; it can
/// never be another application's window.
fn ownsWindow(self: *App, hwnd: win32.HWND) bool {
    for (self.windows.items) |window| {
        if (window.hwnd == hwnd) return true;
    }
    return false;
}

const UntrustedUrlDenial = enum {
    malformed_url,
    unsafe_characters,
    invalid_web_url,
    unsafe_file,

    fn message(self: UntrustedUrlDenial) []const u8 {
        return switch (self) {
            .malformed_url => "The target is not an absolute URL with a scheme.",
            .unsafe_characters => "The target contains invisible or line-breaking characters.",
            .invalid_web_url => "The web target does not contain a valid host.",
            .unsafe_file => "Opening local files from terminal output is blocked on Windows.",
        };
    }
};

const UntrustedUrlDecision = union(enum) {
    allow,
    confirm,
    deny: UntrustedUrlDenial,
};

fn classifyUntrustedUrl(url: []const u8) UntrustedUrlDecision {
    if (url.len == 0) return .{ .deny = .malformed_url };

    const view = std.unicode.Utf8View.init(url) catch
        return .{ .deny = .malformed_url };
    var codepoints = view.iterator();
    while (codepoints.nextCodepoint()) |cp| {
        if (isUnsafeUrlCodepoint(cp)) {
            return .{ .deny = .unsafe_characters };
        }
    }

    // RFC 3986 considers a drive letter to be a scheme, but on Windows this
    // spelling is a local path. Do not let it enter the custom-scheme prompt.
    if (url.len >= 3 and
        std.ascii.isAlphabetic(url[0]) and
        url[1] == ':' and
        (url[2] == '\\' or url[2] == '/'))
    {
        return .{ .deny = .malformed_url };
    }

    const uri = std.Uri.parse(url) catch
        return .{ .deny = .malformed_url };
    if (uri.scheme.len == 0) return .{ .deny = .malformed_url };

    if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        std.ascii.eqlIgnoreCase(uri.scheme, "https"))
    {
        const host = uri.host orelse
            return .{ .deny = .invalid_web_url };
        if (host.percent_encoded.len == 0) {
            return .{ .deny = .invalid_web_url };
        }
        return .allow;
    }

    if (std.ascii.eqlIgnoreCase(uri.scheme, "mailto")) {
        if (uri.path.percent_encoded.len == 0) {
            return .{ .deny = .malformed_url };
        }
        return .allow;
    }

    // ShellExecute may dispatch a local file to an executable handler. Until
    // Win32 has canonical-path and file-type checks equivalent to macOS, keep
    // every file URL supplied by terminal output out of the shell entirely.
    if (std.ascii.eqlIgnoreCase(uri.scheme, "file")) {
        return .{ .deny = .unsafe_file };
    }

    // Custom schemes may invoke any registered application, so require an
    // explicit user decision with Cancel as the default action.
    return .confirm;
}

fn isUnsafeUrlCodepoint(cp: u21) bool {
    return switch (cp) {
        0x00...0x1F,
        0x7F...0x9F,
        0x061C,
        0x200B...0x200F,
        0x2028...0x202E,
        0x2060,
        0x2066...0x2069,
        0xFEFF,
        => true,
        else => false,
    };
}

fn confirmUntrustedUrl(
    self: *App,
    parent: ?win32.HWND,
    url: []const u8,
) bool {
    const message = std.fmt.allocPrint(
        self.alloc,
        "This link may open another application. Only continue if you recognize and trust the destination.\r\n\r\nTarget:\r\n{s}",
        .{url},
    ) catch |err| {
        log.warn("failed to format OSC 8 confirmation: {}", .{err});
        return false;
    };
    defer self.alloc.free(message);

    const message_wide = std.unicode.utf8ToUtf16LeAllocZ(
        self.alloc,
        message,
    ) catch |err| {
        log.warn("failed to convert OSC 8 confirmation: {}", .{err});
        return false;
    };
    defer self.alloc.free(message_wide);

    const caption = std.unicode.utf8ToUtf16LeStringLiteral(
        "Open Link from Terminal Output?",
    );
    const style: win32.MESSAGEBOX_STYLE = .{
        .YESNO = 1,
        .ICONQUESTION = 1,
        .DEFBUTTON2 = 1,
    };
    return win32.MessageBoxW(
        parent,
        message_wide,
        caption,
        style,
    ) == win32.IDYES;
}

fn showBlockedUrl(
    self: *App,
    parent: ?win32.HWND,
    reason: UntrustedUrlDenial,
    url: []const u8,
) void {
    const display = formatUntrustedUrlForDisplay(self.alloc, url) catch |err| {
        log.warn("failed to format blocked OSC 8 target: {}", .{err});
        return;
    };
    defer self.alloc.free(display);

    const message = std.fmt.allocPrint(
        self.alloc,
        "{s}\r\n\r\nTarget:\r\n{s}",
        .{ reason.message(), display },
    ) catch |err| {
        log.warn("failed to format blocked OSC 8 message: {}", .{err});
        return;
    };
    defer self.alloc.free(message);

    const message_wide = std.unicode.utf8ToUtf16LeAllocZ(
        self.alloc,
        message,
    ) catch |err| {
        log.warn("failed to convert blocked OSC 8 message: {}", .{err});
        return;
    };
    defer self.alloc.free(message_wide);

    const caption = std.unicode.utf8ToUtf16LeStringLiteral(
        brand.display_name ++ " Blocked This Link",
    );
    const style: win32.MESSAGEBOX_STYLE = .{ .ICONHAND = 1 };
    _ = win32.MessageBoxW(
        parent,
        message_wide,
        caption,
        style,
    );
}

fn formatUntrustedUrlForDisplay(
    alloc: Allocator,
    url: []const u8,
) Allocator.Error![]u8 {
    const view = std.unicode.Utf8View.init(url) catch
        return try alloc.dupe(u8, "<invalid UTF-8 target>");

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();
    var codepoints = view.iterator();
    while (codepoints.nextCodepoint()) |cp| {
        if (isUnsafeUrlCodepoint(cp)) {
            buffer.writer.print("\\u{{{X}}}", .{cp}) catch
                return error.OutOfMemory;
        } else {
            buffer.writer.print("{u}", .{cp}) catch
                return error.OutOfMemory;
        }
    }
    return try buffer.toOwnedSlice();
}

/// Open a URL or file with the shell on a worker thread. Success means the
/// request was handed to the worker; a shell failure is only logged.
///
/// `ShellExecuteW` dispatches window messages while it waits, and the first
/// call in a process is slow, so it does not run on the UI thread (#36). The
/// shell documentation also asks for COM to be initialized, which the UI
/// thread does not do. The call has no owner window, because the worker
/// cannot keep a window of the UI thread alive.
///
/// Nothing waits for the worker, so it may still be running while the
/// application shuts down; its memory comes from `job_alloc`, which outlives
/// the application's allocator.
pub fn shellOpen(_: *App, value: []const u8) !void {
    const job = try job_alloc.create(ShellJob);
    errdefer job_alloc.destroy(job);
    const value_wide = try std.unicode.utf8ToUtf16LeAllocZ(job_alloc, value);
    errdefer job_alloc.free(value_wide);

    const id = next_shell_job_id.fetchAdd(1, .monotonic);
    job.* = .{
        .id = id,
        .value = value_wide,
    };
    const thread = try std.Thread.spawn(.{}, ShellJob.run, .{job});
    thread.detach();
    log.debug("shell open started id={d}", .{id});
}

/// Identifies shell opens in the log without logging their targets.
var next_shell_job_id: std.atomic.Value(u32) = .init(1);

/// Process-lifetime, thread-safe allocator for detached shell workers. The
/// application's allocator is torn down at exit without waiting for them.
const job_alloc = std.heap.page_allocator;

const ShellJob = struct {
    id: u32,
    value: [:0]u16,

    fn run(self: *ShellJob) void {
        defer {
            job_alloc.free(self.value);
            job_alloc.destroy(self);
        }

        // Some shell extensions require a single-threaded apartment.
        const hr = win32.CoInitializeEx(null, .{
            .APARTMENTTHREADED = 1,
            .DISABLE_OLE1DDE = 1,
        });
        defer if (hr >= 0) win32.CoUninitialize();
        if (hr < 0) log.warn("CoInitializeEx failed for shell open id={d} hr=0x{x}", .{
            self.id,
            @as(u32, @bitCast(hr)),
        });

        const result = win32.ShellExecuteW(
            null,
            std.unicode.utf8ToUtf16LeStringLiteral("open"),
            self.value,
            null,
            null,
            @bitCast(win32.SW_SHOWNORMAL),
        );
        const code = if (result) |value| @intFromPtr(value) else 0;
        if (code <= 32) {
            log.warn("ShellExecuteW failed id={d} code={d} err={d}", .{
                self.id,
                code,
                @intFromEnum(win32.GetLastError()),
            });
        }
    }
};

fn actionParentWindow(self: *App, target: apprt.Target) ?win32.HWND {
    return switch (target) {
        .surface => |surface| surface.rt_surface.windowHwnd(),
        .app => if (self.windows.items.len > 0)
            self.windows.items[0].hwnd
        else
            null,
    };
}

test "classify safe Win32 OSC 8 URLs" {
    try std.testing.expectEqual(
        UntrustedUrlDecision.allow,
        classifyUntrustedUrl("https://example.com/path"),
    );
    try std.testing.expectEqual(
        UntrustedUrlDecision.allow,
        classifyUntrustedUrl("HTTP://EXAMPLE.COM"),
    );
    try std.testing.expectEqual(
        UntrustedUrlDecision.allow,
        classifyUntrustedUrl("mailto:user@example.com"),
    );
    try std.testing.expectEqual(
        UntrustedUrlDecision.confirm,
        classifyUntrustedUrl("vscode://file/C:/project/main.zig"),
    );
}

test "block unsafe Win32 OSC 8 URLs" {
    const testing = std.testing;

    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .malformed_url },
        classifyUntrustedUrl(""),
    );
    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .malformed_url },
        classifyUntrustedUrl("C:\\payload.exe"),
    );
    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .malformed_url },
        classifyUntrustedUrl("/tmp/payload"),
    );
    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .invalid_web_url },
        classifyUntrustedUrl("https:relative"),
    );
    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .malformed_url },
        classifyUntrustedUrl("mailto:"),
    );
    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .unsafe_file },
        classifyUntrustedUrl("file:///C:/payload.exe"),
    );
    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .unsafe_characters },
        classifyUntrustedUrl("https://example.com/a\nb"),
    );
    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .unsafe_characters },
        classifyUntrustedUrl("https://example.com/a\xE2\x80\xAEb"),
    );
}

test "escape unsafe Win32 OSC 8 URL display characters" {
    const testing = std.testing;
    const display = try formatUntrustedUrlForDisplay(
        testing.allocator,
        "https://example.com/a\n\xE2\x80\xAEb",
    );
    defer testing.allocator.free(display);

    try testing.expectEqualStrings(
        "https://example.com/a\\u{A}\\u{202E}b",
        display,
    );
}
