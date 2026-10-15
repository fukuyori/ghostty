//! Keyboard input for the Win32 runtime: key translation, key and character
//! message handling, IME process keys and composition-window placement, and
//! the per-surface suppression state with its reset on focus loss.

const std = @import("std");
const win32 = @import("win32").everything;
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const App = @import("App.zig");
const Mouse = @import("Mouse.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32);

/// VK_PROCESSKEY. Windows substitutes this virtual key in keyboard messages
/// for every keystroke an active IME consumes, leaving the physical scan
/// code untouched.
const vk_processkey: win32.WPARAM = @intFromEnum(win32.VK_PROCESSKEY);

pub fn getModifiers() input.Mods {
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

fn keyRepeatCount(lparam: win32.LPARAM) u16 {
    const bits: usize = @bitCast(lparam);
    const count: u16 = @truncate(bits);
    return if (count == 0) 1 else count;
}

fn isExtendedKey(lparam: win32.LPARAM) bool {
    const bits: usize = @bitCast(lparam);
    return (bits & (@as(usize, 1) << 24)) != 0;
}

/// Hardware scan code carried in bits 16-23 of a keyboard message.
fn scanCode(lparam: win32.LPARAM) u32 {
    const bits: usize = @bitCast(lparam);
    return @intCast((bits >> 16) & 0xFF);
}

/// Scan code with the extended-key prefix folded in the way the Chromium
/// keycode table behind `input.keycodes` expects (0xE000 marks extended
/// keys). Zero means the message carried no scan code.
fn nativeKeycode(lparam: win32.LPARAM) u32 {
    const scan = scanCode(lparam);
    if (scan == 0) return 0;
    return if (isExtendedKey(lparam)) 0xE000 | scan else scan;
}

/// Identity shared by a key message and the character messages generated for
/// it. Repeat and key-state bits deliberately do not participate: one keydown
/// can produce multiple UTF-16 code units, all carrying the same scan code and
/// extended-key flag.
fn characterMessageKey(lparam: win32.LPARAM) ?u32 {
    const native = nativeKeycode(lparam);
    return if (native == 0) null else native;
}

fn shouldSuppressCharacter(expected: ?u32, lparam: win32.LPARAM) bool {
    const actual = characterMessageKey(lparam) orelse return false;
    return expected != null and expected.? == actual;
}

/// Physical key from the scan code. Scan codes identify key positions, so
/// the key at the US `[` position is `bracket_left` on every layout, which
/// is what `physical:` bindings and the default split bindings expect.
fn keyFromScanCode(lparam: win32.LPARAM) input.Key {
    const native = nativeKeycode(lparam);
    if (native == 0) return .unidentified;
    for (input.keycodes.entries) |entry| {
        if (entry.native == native) return entry.key;
    }
    return .unidentified;
}

/// Resolve the physical key for a keyboard message. The scan code is
/// authoritative; messages synthesized without one (PostMessage from
/// automation, for example) fall back to the virtual-key table, which is
/// only exact for the US layout.
fn mapKey(wparam: win32.WPARAM, lparam: win32.LPARAM) input.Key {
    const key = keyFromScanCode(lparam);
    if (key != .unidentified) return key;
    return mapVirtualKey(wparam, lparam);
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
        // VK_OEM_4..VK_OEM_8 and VK_OEM_102: the last two only exist on
        // non-US layouts (for example the key left of Z on ISO keyboards).
        0xDB...0xDF,
        0xE2,
        // VK_NUMPAD0..VK_DIVIDE: with NumLock on, the numpad also produces
        // WM_CHAR. Dispatching the key press as well would send its digit or
        // operator twice, so it travels with the text like the main-row keys.
        // With NumLock off these keys arrive as navigation virtual keys.
        0x60...0x6F,
        => true,
        else => false,
    };
}

fn isAltGr(mods: input.Mods) bool {
    return mods.ctrl and mods.alt and mods.sides.alt == .right;
}

fn consumedTextModifiers(mods: input.Mods) input.Mods {
    var consumed: input.Mods = .{};
    if (isAltGr(mods)) {
        consumed.ctrl = true;
        consumed.alt = true;
    }
    if (mods.shift) {
        consumed.shift = true;
    }
    return consumed;
}

fn shouldDispatchKeyPress(vk: win32.WPARAM, mods: input.Mods) bool {
    if (!isTextVirtualKey(vk)) return true;
    if (mods.super) return true;
    if (mods.alt and !isAltGr(mods)) return true;
    if (mods.ctrl and !isAltGr(mods)) return true;
    return false;
}

fn win32ControlKeyState(mods: input.Mods, lparam: win32.LPARAM) u16 {
    var state: u16 = 0;
    if (mods.alt) state |= if (mods.sides.alt == .right) 0x0001 else 0x0002;
    if (mods.ctrl) state |= if (mods.sides.ctrl == .right) 0x0004 else 0x0008;
    if (mods.shift) state |= 0x0010;
    if (mods.num_lock) state |= 0x0020;
    if ((win32.GetKeyState(0x91) & 1) != 0) state |= 0x0040;
    if (mods.caps_lock) state |= 0x0080;
    if (isExtendedKey(lparam)) state |= 0x0100;
    return state;
}

const Win32Unicode = struct {
    units: [2]u16 = .{ 0, 0 },
    len: u2 = 1,
};

fn unicodeFromCodepoint(codepoint: u21) Win32Unicode {
    if (codepoint <= 0xFFFF) return .{ .units = .{ @intCast(codepoint), 0 } };
    const value: u21 = codepoint - 0x10000;
    return .{
        .units = .{
            @intCast(0xD800 + (value >> 10)),
            @intCast(0xDC00 + (value & 0x3FF)),
        },
        .len = 2,
    };
}

/// Translate a physical key with its actual modifier state without changing
/// the thread's dead-key state. This mirrors the character value that conhost
/// places in a KEY_EVENT_RECORD for Ctrl/Alt-modified key events.
fn modifiedUnicode(vk: win32.WPARAM, lparam: win32.LPARAM, mods: input.Mods) Win32Unicode {
    var key_state = [_]u8{0} ** 256;
    if (mods.shift) {
        key_state[0x10] = 0x80;
        key_state[if (mods.sides.shift == .right) 0xA1 else 0xA0] = 0x80;
    }
    if (mods.ctrl) {
        key_state[0x11] = 0x80;
        key_state[if (mods.sides.ctrl == .right) 0xA3 else 0xA2] = 0x80;
    }
    if (mods.alt) {
        key_state[0x12] = 0x80;
        key_state[if (mods.sides.alt == .right) 0xA5 else 0xA4] = 0x80;
    }
    if (mods.caps_lock) key_state[0x14] = 0x01;
    if (mods.num_lock) key_state[0x90] = 0x01;
    if ((win32.GetKeyState(0x91) & 1) != 0) key_state[0x91] = 0x01;

    var buffer: [4:0]u16 = .{ 0, 0, 0, 0 };
    const written = win32.ToUnicodeEx(
        @intCast(vk),
        scanCode(lparam),
        &key_state,
        &buffer,
        buffer.len,
        0x4,
        win32.GetKeyboardLayout(0),
    );
    if (written <= 0) return .{};
    return .{
        .units = .{ buffer[0], if (written > 1) buffer[1] else 0 },
        .len = if (written > 1) 2 else 1,
    };
}

fn win32KeyMetadata(
    vk: win32.WPARAM,
    lparam: win32.LPARAM,
    mods: input.Mods,
    action: input.Action,
) input.KeyEvent.Win32 {
    const unicode = modifiedUnicode(vk, lparam, mods);
    return .{
        .virtual_key = @truncate(vk),
        .scan_code = @intCast(scanCode(lparam)),
        .unicode = unicode.units,
        .unicode_len = unicode.len,
        .key_down = action != .release,
        .control_key_state = win32ControlKeyState(mods, lparam),
        .repeat_count = keyRepeatCount(lparam),
    };
}

fn virtualKeyForText(lparam: win32.LPARAM, codepoint: u21) u16 {
    const layout = win32.GetKeyboardLayout(0);
    if (scanCode(lparam) != 0) {
        const mapped = win32.MapVirtualKeyExW(nativeKeycode(lparam), 3, layout);
        if (mapped != 0) return @truncate(mapped);
    }
    if (codepoint <= 0xFFFF) {
        const mapped = win32.VkKeyScanExW(@intCast(codepoint), layout);
        if (mapped != -1) return @as(u16, @bitCast(mapped)) & 0xFF;
    }
    return 0;
}

fn win32TextMetadata(
    pending: ?Surface.PendingTextKey,
    lparam: win32.LPARAM,
    mods: input.Mods,
    codepoint: u21,
) input.KeyEvent.Win32 {
    var native = if (pending) |value|
        value.win32
    else
        win32KeyMetadata(virtualKeyForText(lparam, codepoint), lparam, mods, .press);
    const unicode = unicodeFromCodepoint(codepoint);
    native.unicode = unicode.units;
    native.unicode_len = unicode.len;
    return native;
}

/// Codepoint the key produces with no modifier held in the active keyboard
/// layout. Bindings written as `ctrl+;` must match the key that types `;`
/// on the user's layout, not the US position of VK_OEM_1.
fn unshiftedCodepoint(vk: win32.WPARAM, lparam: win32.LPARAM) u21 {
    if (layoutUnshiftedCodepoint(vk, lparam)) |codepoint| return codepoint;
    return unshiftedCodepointUS(vk);
}

/// Translate the key through the active layout with an empty modifier
/// state. Returns null for dead keys and keys without a text translation,
/// leaving the caller to decide on a fallback.
fn layoutUnshiftedCodepoint(vk: win32.WPARAM, lparam: win32.LPARAM) ?u21 {
    var key_state = [_]u8{0} ** 256;
    var buffer: [4:0]u16 = .{ 0, 0, 0, 0 };
    const layout = win32.GetKeyboardLayout(0);
    // Flag 0x4 (Windows 10 1607+) keeps the thread's dead-key state intact
    // so this lookup never swallows a pending accent.
    const written = win32.ToUnicodeEx(
        @intCast(vk),
        scanCode(lparam),
        &key_state,
        &buffer,
        buffer.len,
        0x4,
        layout,
    );
    if (written <= 0) return null;

    var pending: ?u16 = null;
    const codepoint = decodeUtf16CodeUnit(&pending, buffer[0]) orelse first: {
        if (written < 2) return null;
        break :first decodeUtf16CodeUnit(&pending, buffer[1]) orelse return null;
    };
    if (codepoint < 0x20 or codepoint == 0x7F) return null;
    return codepoint;
}

/// US layout fallback for the unshifted codepoint when the active layout
/// has no translation for the key.
fn unshiftedCodepointUS(vk: win32.WPARAM) u21 {
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

fn handleTextInput(
    surface: *Surface,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) win32.LRESULT {
    if (shouldSuppressCharacter(surface.suppressed_char_keycode, lparam)) {
        surface.pending_text_key = null;
        surface.pending_high_surrogate = null;
        return 0;
    }

    const unit: u16 = @truncate(wparam);
    const codepoint = decodeUtf16CodeUnit(&surface.pending_high_surrogate, unit) orelse
        return 0;
    defer surface.pending_text_key = null;

    // Control characters are already represented by their WM_KEYDOWN event.
    if (codepoint < 0x20 or codepoint == 0x7F) return 0;

    const core = surface.core_surface orelse return 0;
    const pending = surface.pending_text_key;
    const mods = if (pending) |value| value.mods else getModifiers();

    // Left-Alt shortcuts were dispatched as physical key events. WM_SYSCHAR
    // must not send a second text event for the same keystroke.
    if (mods.alt and !isAltGr(mods) and pending == null) return 0;

    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return 0;
    const consumed_mods = consumedTextModifiers(mods);

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
        .win32 = win32TextMetadata(pending, lparam, mods, codepoint),
    };
    _ = core.keyCallback(event) catch |err| {
        log.err("key callback error: {}", .{err});
    };
    return 0;
}

pub fn handleFocus(surface: *Surface, focused: bool) void {
    if (!focused) {
        surface.pending_text_key = null;
        surface.pending_high_surrogate = null;
        surface.suppressed_char_keycode = null;
        Mouse.releaseMouseButtons(surface);
    }

    surface.rtApp().core_app.focusEvent(focused);
    if (surface.core_surface) |core| {
        core.focusCallback(focused) catch |err| {
            log.err("focus callback error: {}", .{err});
        };
    }
}

fn handleImeStartComposition(surface: *Surface, hwnd: win32.HWND) void {
    const core = surface.core_surface orelse return;

    const cursor = cursor: {
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        break :cursor core.renderer_state.terminal.screens.active.cursor;
    };

    const context = win32.ImmGetContext(hwnd) orelse {
        log.debug("IME composition started without an input context", .{});
        return;
    };
    defer _ = win32.ImmReleaseContext(hwnd, context);

    const point: win32.POINT = .{
        .x = @intCast(cursor.x * core.size.cell.width + core.size.padding.left),
        .y = @intCast(cursor.y * core.size.cell.height + core.size.padding.top),
    };
    var form: win32.COMPOSITIONFORM = .{
        .dwStyle = win32.CFS_POINT,
        .ptCurrentPos = point,
        .rcArea = std.mem.zeroes(win32.RECT),
    };
    if (win32.ImmSetCompositionWindow(context, &form) == 0) {
        log.warn("ImmSetCompositionWindow failed", .{});
    } else {
        log.debug("positioned IME composition window x={d} y={d}", .{ point.x, point.y });
    }
}

pub fn imeStartComposition(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) win32.LRESULT {
    if (App.getSurface(hwnd)) |surface| {
        if (hwnd == surface.hwnd) handleImeStartComposition(surface, hwnd);
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn character(hwnd: win32.HWND, wparam: win32.WPARAM, lparam: win32.LPARAM) win32.LRESULT {
    if (App.getSurface(hwnd)) |surface| {
        if (hwnd == surface.hwnd) return handleTextInput(surface, wparam, lparam);
    }
    return 0;
}

pub fn keyDown(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) win32.LRESULT {
    if (App.getSurface(hwnd)) |surface| {
        if (hwnd == surface.hwnd) surface.suppressed_char_keycode = null;
    }

    // Keystrokes the IME consumes arrive with the virtual key
    // replaced by VK_PROCESSKEY while the scan code still names the
    // physical key. Because keys are resolved from the scan code,
    // dispatching these would send the composition keys (Enter,
    // Backspace, Tab, arrows) to the terminal on top of the IME's own
    // handling. Hand them to the IME instead, and drop pending key
    // metadata: the text the IME commits later belongs to the
    // composition, not to one physical keystroke.
    if (wparam == vk_processkey) {
        if (App.getSurface(hwnd)) |surface| {
            if (hwnd == surface.hwnd) surface.pending_text_key = null;
        }
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    if (App.getSurface(hwnd)) |surface| {
        if (hwnd == surface.hwnd) {
            if (surface.core_surface) |core| {
                const mods = getModifiers();
                const key = mapKey(wparam, lparam);
                const action = keyAction(lparam);
                const native = win32KeyMetadata(wparam, lparam, mods, action);

                if (!shouldDispatchKeyPress(wparam, mods)) {
                    surface.pending_text_key = .{
                        .action = action,
                        .key = key,
                        .mods = mods,
                        .unshifted_codepoint = unshiftedCodepoint(wparam, lparam),
                        .win32 = native,
                    };
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                }

                surface.pending_text_key = null;
                const effect = core.keyCallback(.{
                    .action = action,
                    .key = key,
                    .mods = mods,
                    .unshifted_codepoint = unshiftedCodepoint(wparam, lparam),
                    .win32 = native,
                }) catch |err| {
                    log.err("key callback error: {}", .{err});
                    return 0;
                };
                if (effect == .consumed or effect == .closed) {
                    surface.suppressed_char_keycode = characterMessageKey(lparam);
                    return 0;
                }
            }
        }
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn keyUp(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) win32.LRESULT {
    if (App.getSurface(hwnd)) |surface| {
        if (hwnd == surface.hwnd) surface.suppressed_char_keycode = null;
    }

    // See the VK_PROCESSKEY note on WM_KEYDOWN.
    if (wparam == vk_processkey) {
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    if (App.getSurface(hwnd)) |surface| {
        if (hwnd == surface.hwnd) {
            if (surface.core_surface) |core| {
                const key = mapKey(wparam, lparam);
                const mods = getModifiers();
                _ = core.keyCallback(.{
                    .action = .release,
                    .key = key,
                    .mods = mods,
                    .unshifted_codepoint = unshiftedCodepoint(wparam, lparam),
                    .win32 = win32KeyMetadata(wparam, lparam, mods, .release),
                }) catch |err| {
                    log.err("key release callback error: {}", .{err});
                };
            }
        }
    }
    return 0;
}

test "map Win32 virtual keys" {
    try std.testing.expectEqual(input.Key.key_a, mapVirtualKey(0x41, 0));
    try std.testing.expectEqual(input.Key.arrow_left, mapVirtualKey(0x25, 0));
    try std.testing.expectEqual(input.Key.bracket_left, mapVirtualKey(0xDB, 0));
    try std.testing.expectEqual(input.Key.bracket_right, mapVirtualKey(0xDD, 0));
    try std.testing.expectEqual(input.Key.numpad_enter, mapVirtualKey(0x0D, 1 << 24));
    try std.testing.expectEqual(input.Key.control_right, mapVirtualKey(0x11, 1 << 24));
    try std.testing.expectEqual(input.Key.unidentified, mapVirtualKey(0xFF, 0));
}

test "map Win32 scan codes to physical keys" {
    const scan = struct {
        fn lparam(code: usize, extended: bool) win32.LPARAM {
            var bits: usize = code << 16;
            if (extended) bits |= @as(usize, 1) << 24;
            return @bitCast(bits);
        }
    };

    // Layout independent positions from the Chromium table.
    try std.testing.expectEqual(input.Key.key_a, keyFromScanCode(scan.lparam(0x1E, false)));
    try std.testing.expectEqual(input.Key.bracket_left, keyFromScanCode(scan.lparam(0x1A, false)));
    try std.testing.expectEqual(input.Key.semicolon, keyFromScanCode(scan.lparam(0x27, false)));
    try std.testing.expectEqual(input.Key.control_left, keyFromScanCode(scan.lparam(0x1D, false)));
    try std.testing.expectEqual(input.Key.control_right, keyFromScanCode(scan.lparam(0x1D, true)));
    try std.testing.expectEqual(input.Key.numpad_enter, keyFromScanCode(scan.lparam(0x1C, true)));
    try std.testing.expectEqual(input.Key.backquote, keyFromScanCode(scan.lparam(0x29, false)));
    try std.testing.expectEqual(input.Key.unidentified, keyFromScanCode(0));

    // The scan code wins over a virtual key that disagrees with it: on a
    // German layout VK_OEM_1 sits on the physical `;` position, but here the
    // scan code says the key is at the US `[` position.
    try std.testing.expectEqual(input.Key.bracket_left, mapKey(0xBA, scan.lparam(0x1A, false)));

    // Messages without a scan code keep the virtual-key fallback.
    try std.testing.expectEqual(input.Key.f5, mapKey(0x74, 0));
    try std.testing.expectEqual(@as(u32, 0), nativeKeycode(0));
    try std.testing.expectEqual(@as(u32, 0xE01D), nativeKeycode(scan.lparam(0x1D, true)));

    // The active layout translates the letter key without modifiers to a
    // lowercase letter (never the uppercase form MapVirtualKey would give),
    // and non-text keys have no translation.
    const letter = layoutUnshiftedCodepoint(0x41, scan.lparam(0x1E, false)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(letter >= 0x20);
    try std.testing.expect(!(letter >= 'A' and letter <= 'Z'));
    try std.testing.expectEqual(@as(?u21, null), layoutUnshiftedCodepoint(0x25, scan.lparam(0x4B, true)));
    try std.testing.expectEqual(@as(u21, 0), unshiftedCodepoint(0x25, scan.lparam(0x4B, true)));
}

test "Win32 IME process keys are not terminal keys" {
    const scan = struct {
        fn lparam(code: usize) win32.LPARAM {
            return @bitCast(code << 16);
        }
    };

    // VK_PROCESSKEY messages keep the physical scan code, so the key mapping
    // resolves them to real keys. That is exactly why the message handlers
    // must reject them before mapping: otherwise every key the IME consumes
    // would also reach the terminal.
    try std.testing.expectEqual(
        input.Key.enter,
        mapKey(vk_processkey, scan.lparam(0x1C)),
    );
    try std.testing.expectEqual(
        input.Key.backspace,
        mapKey(vk_processkey, scan.lparam(0x0E)),
    );

    // The dispatch gate does not stop them either: VK_PROCESSKEY is not a
    // text virtual key, so it takes the "send to the core" path.
    try std.testing.expect(shouldDispatchKeyPress(vk_processkey, .{}));

    try std.testing.expectEqual(@as(win32.WPARAM, 0xE5), vk_processkey);
}

test "classify Win32 text keys" {
    try std.testing.expect(isTextVirtualKey(0x41));
    try std.testing.expect(isTextVirtualKey(0xDE));
    try std.testing.expect(!isTextVirtualKey(0x25));

    // Numpad digits and operators produce WM_CHAR, so their key press is
    // held for the text instead of being dispatched on its own.
    for ([_]win32.WPARAM{ 0x60, 0x65, 0x69, 0x6A, 0x6B, 0x6D, 0x6E, 0x6F }) |vk| {
        try std.testing.expect(isTextVirtualKey(vk));
        try std.testing.expect(!shouldDispatchKeyPress(vk, .{}));
    }
    // With NumLock off the numpad reports navigation keys (VK_INSERT,
    // VK_END), which have no text and are still dispatched.
    try std.testing.expect(shouldDispatchKeyPress(0x2D, .{}));
    try std.testing.expect(shouldDispatchKeyPress(0x23, .{}));

    try std.testing.expectEqual(input.Action.press, keyAction(0));
    try std.testing.expectEqual(input.Action.repeat, keyAction(1 << 30));
    try std.testing.expectEqual(@as(u21, 'a'), unshiftedCodepointUS(0x41));

    var altgr: input.Mods = .{ .ctrl = true, .alt = true };
    altgr.sides.alt = .right;
    try std.testing.expect(!shouldDispatchKeyPress(0x41, altgr));

    var left_alt: input.Mods = .{ .alt = true };
    left_alt.sides.alt = .left;
    try std.testing.expect(shouldDispatchKeyPress(0x41, left_alt));
}

test "Win32 input metadata for Ctrl+Space" {
    const lparam: win32.LPARAM = @bitCast(
        @as(usize, 1) |
            (@as(usize, 0x39) << 16),
    );
    const mods: input.Mods = .{ .ctrl = true };
    const native = win32KeyMetadata(0x20, lparam, mods, .press);
    try std.testing.expectEqual(@as(u16, 0x20), native.virtual_key);
    try std.testing.expectEqual(@as(u16, 0x39), native.scan_code);
    try std.testing.expectEqual(@as(u16, 0x20), native.unicode[0]);
    try std.testing.expectEqual(@as(u2, 1), native.unicode_len);
    try std.testing.expect(native.key_down);
    try std.testing.expectEqual(@as(u16, 0x08), native.control_key_state & ~@as(u16, 0x40));
    try std.testing.expectEqual(@as(u16, 1), native.repeat_count);
    try std.testing.expectEqual(@as(u16, 0x20), virtualKeyForText(lparam, ' '));
}

test "Win32 input metadata preserves supplementary Unicode" {
    const native = unicodeFromCodepoint(0x1F600);
    try std.testing.expectEqual(@as(u2, 2), native.len);
    try std.testing.expectEqual(@as(u16, 0xD83D), native.units[0]);
    try std.testing.expectEqual(@as(u16, 0xDE00), native.units[1]);
}

test "Win32 text metadata uses the WM_CHAR Unicode value" {
    const lparam: win32.LPARAM = @bitCast(
        @as(usize, 1) |
            (@as(usize, 0x1E) << 16),
    );
    const pending: Surface.PendingTextKey = .{
        .action = .press,
        .key = .key_a,
        .mods = .{ .shift = true },
        .unshifted_codepoint = 'a',
        .win32 = .{
            .virtual_key = 0x41,
            .scan_code = 0x1E,
            .unicode = .{ 'a', 0 },
            .control_key_state = 0x10,
        },
    };
    const text = win32TextMetadata(pending, lparam, pending.mods, 'A');
    try std.testing.expectEqual(@as(u16, 0x41), text.virtual_key);
    try std.testing.expectEqual(@as(u16, 0x1E), text.scan_code);
    try std.testing.expectEqual(@as(u16, 'A'), text.unicode[0]);
    try std.testing.expectEqual(@as(u16, 0x10), text.control_key_state);

    // A committed character without a pending physical key follows the same
    // path and derives the best available virtual key from the character.
    const committed = win32TextMetadata(null, 0, .{}, ' ');
    try std.testing.expectEqual(@as(u16, 0x20), committed.virtual_key);
    try std.testing.expectEqual(@as(u16, ' '), committed.unicode[0]);
}

test "match Win32 character messages to consumed physical keys" {
    const scan = struct {
        fn lparam(code: usize, extended: bool, repeat: usize) win32.LPARAM {
            return @bitCast(
                (repeat & 0xFFFF) |
                    (code << 16) |
                    (@as(usize, @intFromBool(extended)) << 24),
            );
        }
    };

    const space = scan.lparam(0x39, false, 1);
    const expected = characterMessageKey(space);
    try std.testing.expectEqual(@as(?u32, 0x39), expected);
    try std.testing.expect(shouldSuppressCharacter(expected, space));

    // Repeat count and other key-state bits do not change the identity.
    try std.testing.expect(shouldSuppressCharacter(
        expected,
        scan.lparam(0x39, false, 3),
    ));

    try std.testing.expect(!shouldSuppressCharacter(
        expected,
        scan.lparam(0x39, true, 1),
    ));
    try std.testing.expect(!shouldSuppressCharacter(
        expected,
        scan.lparam(0x1E, false, 1),
    ));
    try std.testing.expect(!shouldSuppressCharacter(null, space));
    try std.testing.expect(!shouldSuppressCharacter(expected, 0));
}

test "Win32 consumed text modifiers" {
    const shift: input.Mods = .{ .shift = true };
    try std.testing.expect(consumedTextModifiers(shift).shift);
    try std.testing.expect(!consumedTextModifiers(shift).ctrl);

    var altgr: input.Mods = .{ .ctrl = true, .alt = true };
    altgr.sides.alt = .right;
    const consumed_altgr = consumedTextModifiers(altgr);
    try std.testing.expect(consumed_altgr.ctrl);
    try std.testing.expect(consumed_altgr.alt);
    try std.testing.expect(!consumed_altgr.shift);

    var altgr_shift = altgr;
    altgr_shift.shift = true;
    const consumed_both = consumedTextModifiers(altgr_shift);
    try std.testing.expect(consumed_both.ctrl);
    try std.testing.expect(consumed_both.alt);
    try std.testing.expect(consumed_both.shift);
}

test "decode Win32 UTF-16 input" {
    var pending: ?u16 = null;
    try std.testing.expectEqual(@as(?u21, 'A'), decodeUtf16CodeUnit(&pending, 'A'));
    try std.testing.expectEqual(@as(?u21, null), decodeUtf16CodeUnit(&pending, 0xD83D));
    try std.testing.expectEqual(@as(?u21, 0x1F600), decodeUtf16CodeUnit(&pending, 0xDE00));
    try std.testing.expectEqual(@as(?u16, null), pending);
}
