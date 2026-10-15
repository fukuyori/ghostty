// The required comptime API for any apprt.
pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = @import("../os/main.zig").resourcesDir;

const command_palette = @import("win32/CommandPalette.zig");
const config_actions = @import("win32/ConfigActions.zig");
const deferred_actions = @import("win32/DeferredActions.zig");
const context_menu = @import("win32/ContextMenu.zig");
const file_drop = @import("win32/FileDrop.zig");
const keyboard = @import("win32/Keyboard.zig");
const mouse = @import("win32/Mouse.zig");
const native_window = @import("win32/NativeWindow.zig");
const recovery = @import("win32/Recovery.zig");
const split_divider = @import("win32/SplitDivider.zig");
const split_tree = @import("win32/SplitTree.zig");
const tab_bar_accessibility = @import("win32/TabBarAccessibility.zig");
const tab_bar_controller = @import("win32/TabBarController.zig");
const tab_titles = @import("win32/TabTitles.zig");
const window = @import("win32/Window.zig");
const window_appearance = @import("win32/WindowAppearance.zig");
const window_commands = @import("win32/WindowCommands.zig");
const window_layout = @import("win32/WindowLayout.zig");
const window_lifecycle = @import("win32/WindowLifecycle.zig");
const wnd_proc = @import("win32/WndProc.zig");

test {
    _ = command_palette;
    _ = config_actions;
    _ = deferred_actions;
    _ = context_menu;
    _ = file_drop;
    _ = keyboard;
    _ = mouse;
    _ = native_window;
    _ = recovery;
    _ = split_divider;
    _ = split_tree;
    _ = tab_bar_accessibility;
    _ = tab_bar_controller;
    _ = tab_titles;
    _ = window;
    _ = window_appearance;
    _ = window_commands;
    _ = window_layout;
    _ = window_lifecycle;
    _ = wnd_proc;
    @import("std").testing.refAllDecls(@This());
}
