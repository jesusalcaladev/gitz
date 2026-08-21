const std = @import("std");

/// Simple zlib compress/decompress wrappers for git loose objects.
pub const zlib = struct {
    /// Compress data using zlib format.
    pub fn compress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const max_out = data.len + data.len / 10 + 64;
        const out_buf = try allocator.alloc(u8, max_out);
        errdefer allocator.free(out_buf);

        var out_writer = std.Io.Writer.fixed(out_buf);

        var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var comp = try std.compress.flate.Compress.init(
            &out_writer,
            &flate_buf,
            .zlib,
            .{
                .good = 128,
                .nice = 258,
                .lazy = 4,
                .chain = 128,
            },
        );

        try comp.writer.writeAll(data);
        try comp.finish();

        const written = out_writer.buffered();
        const result = try allocator.realloc(out_buf, written.len);
        return result;
    }

    /// Decompress zlib-format data using streamRemaining.
    pub fn decompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        var reader = std.Io.Reader.fixed(data);

        var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var decomp = std.compress.flate.Decompress.init(&reader, .zlib, &decomp_buf);

        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();

        _ = decomp.reader.streamRemaining(&aw.writer) catch 0;

        return try aw.toOwnedSlice();
    }
};

test "zlib roundtrip" {
    const original = "Hello, world! This is a test of zlib compression for git objects.\n";
    const compressed = try zlib.compress(std.testing.allocator, original);
    defer std.testing.allocator.free(compressed);

    const decompressed = try zlib.decompress(std.testing.allocator, compressed);
    defer std.testing.allocator.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}
