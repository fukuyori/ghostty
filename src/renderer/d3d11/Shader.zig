//! Runtime HLSL compilation helpers for the D3D11 renderer.

const std = @import("std");
const win32 = @import("win32").everything;

const log = std.log.scoped(.d3d11_shader);

pub const Stage = enum {
    vertex,
    pixel,

    fn target(self: Stage) [:0]const u8 {
        return switch (self) {
            .vertex => "vs_5_0",
            .pixel => "ps_5_0",
        };
    }
};

pub const Error = error{CompileShader};

pub const Bytecode = struct {
    blob: *win32.ID3DBlob,

    pub fn deinit(self: Bytecode) void {
        _ = self.blob.IUnknown.Release();
    }

    pub fn bytes(self: Bytecode) []const u8 {
        const data: [*]const u8 = @ptrCast(self.blob.GetBufferPointer());
        return data[0..self.blob.GetBufferSize()];
    }
};

pub fn compile(
    source: []const u8,
    entrypoint: [:0]const u8,
    stage: Stage,
) Error!Bytecode {
    var code: ?*win32.ID3DBlob = null;
    var messages: ?*win32.ID3DBlob = null;
    defer {
        if (messages) |blob| _ = blob.IUnknown.Release();
    }

    const result = win32.D3DCompile(
        source.ptr,
        source.len,
        null,
        null,
        null,
        entrypoint.ptr,
        stage.target().ptr,
        win32.D3DCOMPILE_ENABLE_STRICTNESS,
        0,
        &code,
        &messages,
    );
    if (!win32.SUCCEEDED(result)) {
        if (messages) |blob| {
            const data: [*]const u8 = @ptrCast(blob.GetBufferPointer());
            const text = std.mem.trim(u8, data[0..blob.GetBufferSize()], "\x00\r\n");
            log.err("HLSL {s} compilation failed: {s}", .{ @tagName(stage), text });
        } else {
            log.err("HLSL {s} compilation failed: hresult=0x{x}", .{
                @tagName(stage),
                @as(u32, @bitCast(result)),
            });
        }
        return error.CompileShader;
    }

    return .{ .blob = code orelse return error.CompileShader };
}

test "D3D11 shader stages select shader model 5 profiles" {
    try std.testing.expectEqualStrings("vs_5_0", Stage.vertex.target());
    try std.testing.expectEqualStrings("ps_5_0", Stage.pixel.target());
}
