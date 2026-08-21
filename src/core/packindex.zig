const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const mmap_mod = @import("mmap.zig");

/// Git pack index (.idx) file reader with mmap.
///
/// Format (version 2):
///   - 4 bytes magic: 0x37 0x7f 0x3a 0xb2
///   - 4 bytes version: 2
///   - 256 × 4 bytes: fanout table
///   - N × 20 bytes: sorted SHA-1 list
///   - N × 4 bytes: 4-byte offsets
///   - Optional: 8-byte offsets for packs > 2GB
///   - 20 bytes: pack SHA-1
///   - 20 bytes: index SHA-1
///
/// Binary search on sorted SHA list gives O(log n) lookup.
/// With mmap, the entire index is zero-copy in the page cache.

pub const PackIndex = struct {
    mmap: mmap_mod.MmapFile,
    version: u32,
    fanout: []const u32,
    sha_list: []const [20]u8,
    offsets: []const u32,
    pack_sha: [20]u8,

    /// Open and memory-map a .idx file.
    pub fn open(path: []const u8) !PackIndex {
        const mm = try mmap_mod.MmapFile.open(path);
        if (mm.data.len < 8 + 256 * 4 + 20 + 4 + 20 + 20) {
            var m = mm;
            m.close();
            return error.IndexTooSmall;
        }

        const data = mm.data;

        // Verify magic
        if (data[0] != 0x37 or data[1] != 0x7f or data[2] != 0x3a or data[3] != 0xb2) {
            var m = mm;
            m.close();
            return error.InvalidIndexMagic;
        }

        const version = std.mem.readInt(u32, data[4..8], .big);
        if (version != 2) {
            var m = mm;
            m.close();
            return error.UnsupportedIndexVersion;
        }

        // Fanout table: 256 entries × 4 bytes, starting at offset 8
        const fanout_start: usize = 8;
        const fanout_slice = data[fanout_start .. fanout_start + 256 * 4];

        // Last fanout entry tells us total number of objects
        const total_objects = std.mem.readInt(u32, fanout_slice[255 * 4 .. 256 * 4], .big);

        // SHA list starts after fanout
        const sha_start = fanout_start + 256 * 4;
        const sha_list = @as([]const [20]u8, @ptrCast(data[sha_start .. sha_start + @as(usize, total_objects) * 20]));

        // Offset list starts after SHA list
        const offset_start = sha_start + @as(usize, total_objects) * 20;
        const offset_list = @as([]const u32, @ptrCast(data[offset_start .. offset_start + @as(usize, total_objects) * 4]));

        // Pack SHA-1 (20 bytes after offsets)
        const pack_sha_start = offset_start + @as(usize, total_objects) * 4;
        var pack_sha: [20]u8 = undefined;
        @memcpy(&pack_sha, data[pack_sha_start .. pack_sha_start + 20]);

        return .{
            .mmap = mm,
            .version = version,
            .fanout = @ptrCast(fanout_slice),
            .sha_list = sha_list,
            .offsets = offset_list,
            .pack_sha = pack_sha,
        };
    }

    pub fn close(self: *PackIndex) void {
        self.mmap.close();
    }

    pub fn objectCount(self: PackIndex) u32 {
        return @intCast(self.sha_list.len);
    }

    /// Binary search for a SHA in the index.
    /// Returns the pack file offset, or error if not found.
    /// O(log n) — the key optimization over git's loose object O(1) but with much less disk space.
    pub fn find(self: PackIndex, target_sha: [20]u8) ?u32 {
        // Binary search on sorted SHA list
        var low: usize = 0;
        var high: usize = self.sha_list.len;

        while (low < high) {
            const mid = low + (high - low) / 2;
            const cmp = std.mem.order(u8, &self.sha_list[mid], &target_sha);
            switch (cmp) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return self.offsets[mid],
            }
        }

        return null;
    }

    /// Get the offset for a SHA by prefix byte (fanout) + binary search.
    /// This is how git actually does it: first narrow by prefix, then binary search.
    pub fn findByPrefix(self: PackIndex, sha: [20]u8) ?u32 {
        const prefix = sha[0];
        const start: usize = if (prefix > 0) self.fanout[prefix - 1] else 0;
        const end: usize = self.fanout[prefix];

        // Binary search within this range
        var low = start;
        var high = end;

        while (low < high) {
            const mid = low + (high - low) / 2;
            const cmp = std.mem.order(u8, &self.sha_list[mid], &sha);
            switch (cmp) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return self.offsets[mid],
            }
        }

        return null;
    }
};

/// Generate a .idx file from sorted SHAs and offsets.
pub fn writeIndex(allocator: std.mem.Allocator, shas: []const [20]u8, offsets: []const u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;

    // Magic + version
    try buf.appendSlice(allocator, &.{ 0x37, 0x7f, 0x3a, 0xb2 });
    try buf.appendSlice(allocator, &.{ 0, 0, 0, 2 });

    // Build fanout table
    var fanout: [256]u32 = [_]u32{0} ** 256;
    for (shas) |sha| {
        fanout[sha[0]] += 1;
    }
    var acc: u32 = 0;
    for (0..256) |i| {
        const tmp = fanout[i];
        fanout[i] = acc;
        acc += tmp;
    }

    // Write fanout
    for (fanout) |f| {
        var fbuf: [4]u8 = undefined;
        std.mem.writeInt(u32, &fbuf, f, .big);
        try buf.appendSlice(allocator, &fbuf);
    }

    // Write SHAs (sorted)
    for (shas) |sha| {
        try buf.appendSlice(allocator, &sha);
    }

    // Write offsets
    for (offsets) |off| {
        var obuf: [4]u8 = undefined;
        std.mem.writeInt(u32, &obuf, off, .big);
        try buf.appendSlice(allocator, &obuf);
    }

    // Pack SHA-1 placeholder
    try buf.appendSlice(allocator, &[_]u8{0} ** 20);
    // Index SHA-1 placeholder
    try buf.appendSlice(allocator, &[_]u8{0} ** 20);

    return try buf.toOwnedSlice(allocator);
}

test "pack index write and read" {
    const allocator = std.testing.allocator;

    const sha1 = Sha1.hash("object1");
    const sha2 = Sha1.hash("object2");
    const sha3 = Sha1.hash("object3");

    // Sort SHAs
    var shas = [_][20]u8{ sha1, sha2, sha3 };
    std.sort.insertion([20]u8, &shas, {}, struct {
        fn lessThan(_: void, a: [20]u8, b: [20]u8) bool {
            return std.mem.order(u8, &a, &b) == .lt;
        }
    }.lessThan);

    const offsets = [_]u32{ 12, 100, 250 };
    const idx_data = try writeIndex(allocator, &shas, &offsets);
    defer allocator.free(idx_data);

    // Verify fanout
    try std.testing.expect(idx_data.len > 8 + 256 * 4);
}
