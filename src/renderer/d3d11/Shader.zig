//! Runtime HLSL compilation helpers for the D3D11 renderer.

const std = @import("std");
const win32 = @import("win32").everything;
const global = @import("../../global.zig");

const log = std.log.scoped(.d3d11_shader);

/// Compiled bytecode is device independent, so it is kept for the life of
/// the process. Device recovery rebuilds every pipeline; without this cache
/// each rebuild recompiled every stage on the renderer thread.
const CacheEntry = struct {
    source: []const u8,
    entrypoint: [:0]const u8,
    stage: Stage,
    blob: *win32.ID3DBlob,
};

const cache_capacity = 16;
var cache_mutex: std.Io.Mutex = .init;
var cache_entries: [cache_capacity]CacheEntry = undefined;
var cache_len: usize = 0;

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
    cache_mutex.lockUncancelable(global.io());
    defer cache_mutex.unlock(global.io());

    if (cachedBlob(source, entrypoint, stage)) |blob| {
        _ = blob.IUnknown.AddRef();
        return .{ .blob = blob };
    }

    const bytecode = try compileUncached(source, entrypoint, stage);
    if (cache_len < cache_capacity) {
        _ = bytecode.blob.IUnknown.AddRef();
        cache_entries[cache_len] = .{
            .source = source,
            .entrypoint = entrypoint,
            .stage = stage,
            .blob = bytecode.blob,
        };
        cache_len += 1;
    }
    return bytecode;
}

/// Caller must hold `cache_mutex`. Sources are comptime strings, so pointer
/// identity plus the entrypoint name is a sufficient key.
fn cachedBlob(
    source: []const u8,
    entrypoint: [:0]const u8,
    stage: Stage,
) ?*win32.ID3DBlob {
    for (cache_entries[0..cache_len]) |entry| {
        if (entry.stage != stage) continue;
        if (entry.source.ptr != source.ptr or entry.source.len != source.len) continue;
        if (!std.mem.eql(u8, entry.entrypoint, entrypoint)) continue;
        return entry.blob;
    }
    return null;
}

fn compileUncached(
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

test "D3D11 shader bytecode cache reuses compiled blobs" {
    const source =
        \\float4 main() : SV_Position { return float4(0, 0, 0, 1); }
    ;
    const first = try compile(source, "main", .vertex);
    defer first.deinit();
    const second = try compile(source, "main", .vertex);
    defer second.deinit();
    try std.testing.expect(first.blob == second.blob);
    try std.testing.expect(first.bytes().len > 0);

    // A different stage or entrypoint must not alias the cached blob.
    const pixel_source =
        \\float4 main() : SV_Target { return float4(0, 0, 0, 1); }
    ;
    const pixel = try compile(pixel_source, "main", .pixel);
    defer pixel.deinit();
    try std.testing.expect(pixel.blob != first.blob);
}

test "D3D11 shader stages select shader model 5 profiles" {
    try std.testing.expectEqualStrings("vs_5_0", Stage.vertex.target());
    try std.testing.expectEqualStrings("ps_5_0", Stage.pixel.target());
}
