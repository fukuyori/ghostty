//! System-wide `global:` keybindings for the Win32 runtime. Each eligible
//! binding is registered with RegisterHotKey on the app's message-only wakeup
//! window, and WM_HOTKEY performs the binding's action app-wide.
//!
//! Like GTK, only bindings with exactly one action are registered. Triggers
//! are translated to a virtual key with the GUI thread's keyboard layout at
//! registration time. A trigger must name the keys that are pressed, so a
//! character that needs Shift or AltGr on the layout is rejected.
//!
//! A `global:` binding that cannot be registered, for whatever reason, is
//! removed from the configuration before the core receives it, so it does not
//! work inside Ghostty either, and a configuration diagnostic reports it.
const GlobalHotkeys = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const cli = @import("../../cli.zig");
const input = @import("../../input.zig");
const Binding = input.Binding;
const Config = @import("../../config.zig").Config;

const log = std.log.scoped(.win32);

/// RegisterHotKey identifiers for applications must be below 0xC000. The
/// identifier encodes a registration generation so a WM_HOTKEY queued before
/// re-registration cannot run an action from the replaced configuration.
const max_entries = 256;
const generations = 0xC000 / max_entries;

pub const Chord = struct {
    modifiers: win32.HOT_KEY_MODIFIERS,
    vk: u32,

    fn eql(a: Chord, b: Chord) bool {
        return a.vk == b.vk and
            @as(u32, @bitCast(a.modifiers)) == @as(u32, @bitCast(b.modifiers));
    }
};

const Entry = struct {
    id: i32,
    chord: Chord,
    trigger: Binding.Trigger,
    action: Binding.Action,
};

arena: ?std.heap.ArenaAllocator = null,
entries: std.ArrayListUnmanaged(Entry) = .empty,
hwnd: ?win32.HWND = null,
generation: u32 = 0,
/// Keyboard layout the triggers were translated with.
layout: ?win32.HKL = null,

const Rejection = struct {
    trigger: Binding.Trigger,
    reason: []const u8,
};

/// Unregister the previous set and register every `global:` binding in
/// `config`. Bindings that cannot be registered are removed from `config`
/// and reported in its diagnostics. Returns the number removed. Actions are
/// cloned so no registration refers to config memory.
pub fn register(
    self: *GlobalHotkeys,
    alloc: std.mem.Allocator,
    hwnd: ?win32.HWND,
    config: *Config,
) usize {
    self.unregister();
    self.generation = (self.generation + 1) % generations;
    self.hwnd = hwnd;
    self.arena = .init(alloc);
    const arena = self.arena.?.allocator();

    var scratch: std.heap.ArenaAllocator = .init(alloc);
    defer scratch.deinit();
    var rejected: std.ArrayListUnmanaged(Rejection) = .empty;
    const reject = struct {
        fn add(list: *std.ArrayListUnmanaged(Rejection), a: std.mem.Allocator, trigger: Binding.Trigger, reason: []const u8) void {
            list.append(a, .{ .trigger = trigger, .reason = reason }) catch {
                log.warn("global keybinding {f}: {s}", .{ trigger, reason });
            };
        }
    }.add;

    var candidates: std.ArrayListUnmanaged(Entry) = .empty;
    const layout = win32.GetKeyboardLayout(0);
    self.layout = layout;
    var it = config.keybind.set.bindings.iterator();
    while (it.next()) |binding| {
        const leaf: Binding.Set.GenericLeaf = switch (binding.value_ptr.*) {
            .leader => continue,
            inline .leaf, .leaf_chained => |leaf| leaf.generic(),
        };
        if (!leaf.flags.global) continue;
        const trigger = binding.key_ptr.*;
        if (hwnd == null) {
            reject(&rejected, scratch.allocator(), trigger, "global keybindings are unavailable");
            continue;
        }
        const actions = leaf.actionsSlice();
        if (actions.len != 1) {
            reject(&rejected, scratch.allocator(), trigger, "a global keybinding must have exactly one action");
            continue;
        }
        const chord = chordForTrigger(trigger, layout) catch |err| {
            reject(&rejected, scratch.allocator(), trigger, reasonFor(err));
            continue;
        };
        if (candidates.items.len >= max_entries) {
            reject(&rejected, scratch.allocator(), trigger, "too many global keybindings");
            continue;
        }
        const action = actions[0].clone(arena) catch {
            reject(&rejected, scratch.allocator(), trigger, "out of memory");
            continue;
        };
        candidates.append(arena, .{
            .id = 0,
            .chord = chord,
            .trigger = trigger,
            .action = action,
        }) catch {
            reject(&rejected, scratch.allocator(), trigger, "out of memory");
            continue;
        };
    }

    for (candidates.items, 0..) |candidate, i| {
        if (chordCollides(candidates.items, i)) {
            reject(&rejected, scratch.allocator(), candidate.trigger, "uses the same keys as another global keybinding");
            continue;
        }
        var entry = candidate;
        entry.id = @intCast(self.generation * max_entries + i);
        if (win32.RegisterHotKey(hwnd, entry.id, entry.chord.modifiers, entry.chord.vk) == 0) {
            log.warn("RegisterHotKey({f}, vk=0x{x:0>2}, mods=0x{x}) failed: err={d}", .{
                entry.trigger,
                entry.chord.vk,
                @as(u32, @bitCast(entry.chord.modifiers)),
                @backingInt(win32.GetLastError()),
            });
            reject(&rejected, scratch.allocator(), entry.trigger, "the keys are already used by another application or by Windows");
            continue;
        }
        self.entries.append(arena, entry) catch {
            _ = win32.UnregisterHotKey(hwnd, entry.id);
            reject(&rejected, scratch.allocator(), entry.trigger, "out of memory");
            continue;
        };
        log.info("registered global keybinding {f}", .{entry.trigger});
    }

    for (rejected.items) |rejection| disable(config, rejection);
    return rejected.items.len;
}

/// Remove `global:` bindings that are not currently registered from a
/// configuration that applies to a single surface.
pub fn removeUnregistered(self: *const GlobalHotkeys, alloc: std.mem.Allocator, config: *Config) void {
    var triggers: std.ArrayListUnmanaged(Binding.Trigger) = .empty;
    defer triggers.deinit(alloc);
    var it = config.keybind.set.bindings.iterator();
    while (it.next()) |binding| {
        const global = switch (binding.value_ptr.*) {
            .leader => false,
            inline .leaf, .leaf_chained => |leaf| leaf.flags.global,
        };
        if (!global or self.registered(binding.key_ptr.*)) continue;
        triggers.append(alloc, binding.key_ptr.*) catch return;
    }
    for (triggers.items) |trigger| disable(config, .{
        .trigger = trigger,
        .reason = "the global keybinding is not registered",
    });
}

fn registered(self: *const GlobalHotkeys, trigger: Binding.Trigger) bool {
    for (self.entries.items) |entry| {
        if (std.meta.eql(entry.trigger, trigger)) return true;
    }
    return false;
}

/// Remove the binding from the configuration and add a diagnostic for it.
fn disable(config: *Config, rejection: Rejection) void {
    log.warn("global keybinding {f} disabled: {s}", .{ rejection.trigger, rejection.reason });
    const alloc = config.arenaAlloc();
    config.keybind.set.remove(alloc, rejection.trigger);
    const message = alloc.printSentinel(
        "global:{f}: {s}; the keybinding is disabled",
        .{ rejection.trigger, rejection.reason },
        0,
    ) catch return;
    config._diagnostics.append(alloc, .{ .key = "keybind", .message = message }) catch {};
}

fn reasonFor(err: TranslateError) []const u8 {
    return switch (err) {
        error.CatchAllTrigger => "catch_all cannot be a global keybinding",
        error.LockModifier => "caps_lock and num_lock cannot be used in a global keybinding",
        error.ModifierKey => "a modifier key alone cannot be a global keybinding",
        error.UnmappedKey => "the key is not available on the current keyboard layout",
        error.AmbiguousKey => "Windows cannot tell this key apart from another key",
        error.ShiftedCharacter => "the character needs Shift or AltGr on the current keyboard layout; write the keys that are pressed",
    };
}

pub fn unregister(self: *GlobalHotkeys) void {
    if (self.hwnd) |hwnd| {
        for (self.entries.items) |entry| {
            if (win32.UnregisterHotKey(hwnd, entry.id) == 0) {
                log.warn("UnregisterHotKey failed: err={d}", .{@backingInt(win32.GetLastError())});
            }
        }
    }
    if (self.arena) |*arena| arena.deinit();
    const generation = self.generation;
    self.* = .{ .generation = generation };
}

/// True when the GUI thread's keyboard layout differs from the one the
/// current registration was translated with.
pub fn layoutChanged(self: *const GlobalHotkeys) bool {
    if (self.hwnd == null) return false;
    return win32.GetKeyboardLayout(0) != self.layout;
}

/// Number of global keybindings currently registered with Windows.
pub fn count(self: *const GlobalHotkeys) usize {
    return self.entries.items.len;
}

/// The action registered under a WM_HOTKEY identifier, or null for an
/// identifier from a replaced registration.
pub fn actionFor(self: *const GlobalHotkeys, id: usize) ?Binding.Action {
    for (self.entries.items) |entry| {
        if (entry.id == id) return entry.action;
    }
    return null;
}

fn chordCollides(entries: []const Entry, index: usize) bool {
    for (entries, 0..) |other, i| {
        if (i != index and other.chord.eql(entries[index].chord)) return true;
    }
    return false;
}

pub const TranslateError = error{
    CatchAllTrigger,
    LockModifier,
    ModifierKey,
    UnmappedKey,
    AmbiguousKey,
    ShiftedCharacter,
};

/// Translate a trigger to the RegisterHotKey modifiers and virtual key.
pub fn chordForTrigger(trigger: Binding.Trigger, layout: ?win32.HKL) TranslateError!Chord {
    const modifiers = try modifiersFor(trigger.mods);
    const vk: u32 = switch (trigger.key) {
        .catch_all => return error.CatchAllTrigger,
        .physical => |key| vk: {
            // A numpad digit's VK depends on NumLock (VK_NUMPAD3 or VK_NEXT),
            // so no single registration matches only that key.
            if (isNumLockDependent(key)) return error.AmbiguousKey;
            const native = nativeKeycode(key) orelse return error.UnmappedKey;
            // MAPVK_VSC_TO_VK_EX understands the 0xE0 extended-key prefix.
            const mapped = win32.MapVirtualKeyExW(native, 3, layout);
            if (mapped == 0) return error.UnmappedKey;
            // RegisterHotKey identifies keys by VK only. Reject keys that
            // share their VK with another physical key, such as numpad Enter
            // and Enter: MAPVK_VK_TO_VSC_EX then names the other scan code.
            // The extended navigation keys are accepted even though their
            // numpad twins produce the same VK while NumLock is off.
            const back = win32.MapVirtualKeyExW(mapped, 4, layout);
            if (back != native and !(isNavigationVirtualKey(mapped) and (back | 0xE000) == native)) {
                return error.AmbiguousKey;
            }
            break :vk mapped;
        },
        .unicode => |codepoint| vk: {
            if (codepoint > 0xFFFF) return error.UnmappedKey;
            const scan = win32.VkKeyScanExW(@intCast(codepoint), layout);
            if (scan == -1) return error.UnmappedKey;
            const bits: u16 = @bitCast(scan);
            // The high byte holds the shift state the character requires.
            // Bindings match the unshifted codepoint, so such a character
            // never matches a key press in the terminal either.
            if (bits >> 8 != 0) return error.ShiftedCharacter;
            break :vk bits & 0xFF;
        },
    };
    if (isModifierVirtualKey(vk)) return error.ModifierKey;
    return .{ .modifiers = modifiers, .vk = vk };
}

fn modifiersFor(mods: input.Mods) TranslateError!win32.HOT_KEY_MODIFIERS {
    if (mods.caps_lock or mods.num_lock) return error.LockModifier;
    return .{
        .ALT = @intFromBool(mods.alt),
        .CONTROL = @intFromBool(mods.ctrl),
        .SHIFT = @intFromBool(mods.shift),
        .WIN = @intFromBool(mods.super),
        // Holding the chord performs the action once.
        .NOREPEAT = 1,
    };
}

fn nativeKeycode(key: input.Key) ?u32 {
    if (key == .unidentified) return null;
    for (input.keycodes.entries) |entry| {
        if (entry.key == key) return if (entry.native == 0) null else entry.native;
    }
    return null;
}

fn isNumLockDependent(key: input.Key) bool {
    return switch (key) {
        .numpad_0,
        .numpad_1,
        .numpad_2,
        .numpad_3,
        .numpad_4,
        .numpad_5,
        .numpad_6,
        .numpad_7,
        .numpad_8,
        .numpad_9,
        .numpad_decimal,
        => true,
        else => false,
    };
}

/// VK_PRIOR through VK_DOWN, VK_INSERT and VK_DELETE.
fn isNavigationVirtualKey(vk: u32) bool {
    return switch (vk) {
        0x21...0x28, 0x2D, 0x2E => true,
        else => false,
    };
}

fn isModifierVirtualKey(vk: u32) bool {
    return switch (vk) {
        0x10, 0x11, 0x12, 0x14, 0x5B, 0x5C, 0x90, 0x91, 0xA0...0xA5 => true,
        else => false,
    };
}

test "Win32 global keybinding modifiers" {
    const testing = std.testing;
    const mods = try modifiersFor(.{ .ctrl = true, .shift = true, .super = true });
    try testing.expectEqual(@as(u1, 1), mods.CONTROL);
    try testing.expectEqual(@as(u1, 1), mods.SHIFT);
    try testing.expectEqual(@as(u1, 1), mods.WIN);
    try testing.expectEqual(@as(u1, 0), mods.ALT);
    try testing.expectEqual(@as(u1, 1), mods.NOREPEAT);

    // Sides are not distinguishable with RegisterHotKey and are ignored.
    const sided = try modifiersFor(.{ .alt = true, .sides = .{ .alt = .right } });
    try testing.expectEqual(@as(u1, 1), sided.ALT);

    try testing.expectError(error.LockModifier, modifiersFor(.{ .caps_lock = true }));
}

test "Win32 global keybinding translates layout-independent physical keys" {
    const testing = std.testing;
    const layout = win32.GetKeyboardLayout(0);

    const f1 = try chordForTrigger(.{
        .key = .{ .physical = .f1 },
        .mods = .{ .ctrl = true },
    }, layout);
    try testing.expectEqual(@as(u32, 0x70), f1.vk);
    try testing.expectEqual(@as(u1, 1), f1.modifiers.CONTROL);

    // Extended keys keep their 0xE0 prefix through the translation.
    const page_down = try chordForTrigger(.{ .key = .{ .physical = .page_down } }, layout);
    try testing.expectEqual(@as(u32, 0x22), page_down.vk);

    // Numpad Enter shares VK_RETURN with Enter, so a VK-only registration
    // would also fire for the main Enter key.
    try testing.expectError(error.AmbiguousKey, chordForTrigger(.{
        .key = .{ .physical = .numpad_enter },
        .mods = .{ .ctrl = true },
    }, layout));
    const enter = try chordForTrigger(.{ .key = .{ .physical = .enter }, .mods = .{ .ctrl = true } }, layout);
    try testing.expectEqual(@as(u32, 0x0D), enter.vk);
    try testing.expectError(error.AmbiguousKey, chordForTrigger(.{
        .key = .{ .physical = .numpad_3 },
        .mods = .{ .ctrl = true },
    }, layout));

    try testing.expectError(error.CatchAllTrigger, chordForTrigger(.{ .key = .catch_all }, layout));
    try testing.expectError(error.ModifierKey, chordForTrigger(.{
        .key = .{ .physical = .shift_left },
        .mods = .{ .ctrl = true },
    }, layout));
    try testing.expectError(error.UnmappedKey, chordForTrigger(.{ .key = .{ .physical = .unidentified } }, layout));
    try testing.expectError(error.UnmappedKey, chordForTrigger(.{ .key = .{ .unicode = 0x1F600 } }, layout));
}

test "Win32 global keybinding that cannot be registered is removed and reported" {
    const testing = std.testing;
    var config = try Config.default(testing.allocator);
    defer config.deinit();
    try config.keybind.parseCLI(config.arenaAlloc(), "global:ctrl+alt+f12=toggle_quick_terminal");
    try config.keybind.parseCLI(config.arenaAlloc(), "ctrl+alt+f11=toggle_quick_terminal");
    const global_trigger: Binding.Trigger = .{ .key = .{ .physical = .f12 }, .mods = .{ .ctrl = true, .alt = true } };
    const local_trigger: Binding.Trigger = .{ .key = .{ .physical = .f11 }, .mods = .{ .ctrl = true, .alt = true } };
    try testing.expect(config.keybind.set.get(global_trigger) != null);
    const diagnostics_before = config._diagnostics.items().len;

    // Without a message window nothing can be registered.
    var hotkeys: GlobalHotkeys = .{};
    defer hotkeys.unregister();
    try testing.expectEqual(@as(usize, 1), hotkeys.register(testing.allocator, null, &config));
    try testing.expectEqual(@as(usize, 0), hotkeys.count());

    // The global binding no longer works inside Ghostty either; ordinary
    // bindings are untouched.
    try testing.expect(config.keybind.set.get(global_trigger) == null);
    try testing.expect(config.keybind.set.get(local_trigger) != null);

    const diagnostics = config._diagnostics.items();
    try testing.expectEqual(diagnostics_before + 1, diagnostics.len);
    try testing.expectEqualStrings("keybind", diagnostics[diagnostics.len - 1].key);
    try testing.expect(std.mem.indexOf(u8, diagnostics[diagnostics.len - 1].message, "ctrl+alt+f12") != null);
    try testing.expect(std.mem.endsWith(u8, diagnostics[diagnostics.len - 1].message, "the keybinding is disabled"));
}

test "Win32 global keybinding chord collisions" {
    const testing = std.testing;
    const chord: Chord = .{ .modifiers = .{ .CONTROL = 1 }, .vk = 0x41 };
    const other: Chord = .{ .modifiers = .{ .ALT = 1 }, .vk = 0x41 };
    const entries = [_]Entry{
        .{ .id = 0, .chord = chord, .trigger = .{}, .action = .ignore },
        .{ .id = 0, .chord = other, .trigger = .{}, .action = .ignore },
        .{ .id = 0, .chord = chord, .trigger = .{}, .action = .ignore },
    };
    try testing.expect(chordCollides(&entries, 0));
    try testing.expect(!chordCollides(&entries, 1));
    try testing.expect(chordCollides(&entries, 2));
}
