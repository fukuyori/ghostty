// The required comptime API for any apprt.
pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = @import("../os/main.zig").resourcesDir;

const split_tree = @import("win32/SplitTree.zig");

test {
    _ = split_tree;
    @import("std").testing.refAllDecls(@This());
}
