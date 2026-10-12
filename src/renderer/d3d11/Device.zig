//! The app-scoped render device for Direct3D 11.
//!
//! Each surface still creates its own D3D11 device and DirectComposition
//! presenter (see `D3D11.init`). This type only satisfies the app-scoped
//! `renderer.Device` interface and holds no state.
const Device = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn init(self: *Device, alloc: Allocator) !void {
    _ = alloc;
    self.* = .{};
}

pub fn deinit(self: *Device) void {
    self.* = undefined;
}
