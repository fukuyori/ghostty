// The required comptime API for any apprt.
pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = @import("../os/main.zig").resourcesDir;

const config_actions = @import("win32/ConfigActions.zig");
const context_menu = @import("win32/ContextMenu.zig");
const recovery = @import("win32/Recovery.zig");
const split_tree = @import("win32/SplitTree.zig");
const tab_titles = @import("win32/TabTitles.zig");
const window = @import("win32/Window.zig");

test {
    _ = config_actions;
    _ = context_menu;
    _ = recovery;
    _ = split_tree;
    _ = tab_titles;
    _ = window;
    @import("std").testing.refAllDecls(@This());
}
