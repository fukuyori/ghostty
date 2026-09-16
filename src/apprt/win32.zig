// The required comptime API for any apprt.
pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = @import("../os/main.zig").resourcesDir;

const context_menu = @import("win32/ContextMenu.zig");
const split_tree = @import("win32/SplitTree.zig");
const window = @import("win32/Window.zig");

test {
    _ = context_menu;
    _ = split_tree;
    _ = window;
    @import("std").testing.refAllDecls(@This());
}
