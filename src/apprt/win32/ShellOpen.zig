//! Opening URLs and files with the Windows shell, including the safety
//! policy for links that come from terminal output (OSC 8).

const std = @import("std");
const win32 = @import("win32").everything;
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");

const log = std.log.scoped(.win32);

pub fn openUrl(
    self: *App,
    target: apprt.Target,
    value: apprt.action.OpenUrl,
) bool {
    if (value.kind != .osc8) {
        shellOpen(self, target, value.url) catch |err| {
            log.warn("failed to open URL: {}", .{err});
            return false;
        };
        return true;
    }

    switch (classifyUntrustedUrl(value.url)) {
        .allow => shellOpen(self, target, value.url) catch |err| {
            log.warn("failed to open trusted OSC 8 URL: {}", .{err});
        },
        .confirm => if (confirmUntrustedUrl(self, target, value.url)) {
            shellOpen(self, target, value.url) catch |err| {
                log.warn("failed to open confirmed OSC 8 URL: {}", .{err});
            };
        },
        .deny => |reason| showBlockedUrl(self, target, reason, value.url),
    }

    // OSC 8 targets must never reach the unrestricted core fallback. Even a
    // rejected target is handled here so terminal output cannot bypass this
    // policy by making the platform handler return false.
    return true;
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
    target: apprt.Target,
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
        actionParentWindow(self, target),
        message_wide,
        caption,
        style,
    ) == win32.IDYES;
}

fn showBlockedUrl(
    self: *App,
    target: apprt.Target,
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
        "Ghostty Blocked This Link",
    );
    const style: win32.MESSAGEBOX_STYLE = .{ .ICONHAND = 1 };
    _ = win32.MessageBoxW(
        actionParentWindow(self, target),
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

pub fn shellOpen(self: *App, target: apprt.Target, value: []const u8) !void {
    const value_wide = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, value);
    defer self.alloc.free(value_wide);

    const result = win32.ShellExecuteW(
        actionParentWindow(self, target),
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        value_wide,
        null,
        null,
        @bitCast(win32.SW_SHOWNORMAL),
    ) orelse return error.ShellExecuteFailed;

    if (@intFromPtr(result) <= 32) return error.ShellExecuteFailed;
}

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
