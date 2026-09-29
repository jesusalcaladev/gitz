const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const mmap_mod = @import("mmap.zig");

const testing = std.testing;

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
    /// The fanout and offset tables are kept as raw bytes rather than as
    /// `[]const u32`.
    ///
    /// Git writes every integer in an index in network byte order, while a
    /// `[]const u32` is read in the host's order, which on x86 is the reverse.
    /// The offsets came out byte-swapped, and because they were then compared
    /// against a pack of about a megabyte they all looked too large to be real,
    /// so every lookup missed. Decoding on access with an explicit `.big` keeps
    /// the file's byte order authoritative instead of the machine's.
    fanout: []const u8,
    sha_list: []const [20]u8,
    offsets: []const u8,
    /// The optional 64-bit offset table, present only when some offset exceeds
    /// 4 GiB and flagged in the 32-bit table by its top bit.
    large_offsets: ?usize,
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

        // Verify magic. An index v2 file starts with PACK_IDX_SIGNATURE, which
        // git spells as 0xff744f63 -- the bytes `ff 74 4f 63`. The check
        // compared against 0x377f3ab2, which no git ever wrote, so *every* real
        // index was rejected as corrupt and the pack reader was never reached.
        if (data[0] != 0xff or data[1] != 0x74 or data[2] != 0x4f or data[3] != 0x63) {
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

        // SHA list starts after fanout.
        //
        // The slices below are built from a pointer and an explicit element
        // count rather than by `@ptrCast` on a byte slice. Casting a slice
        // carries its *byte* length into the new element type, so the resulting
        // slice is four times too long and, worse, the extra length walks past
        // the table into whatever follows -- which is how a correct
        // `offset_start` still produced a nonsense first offset.
        const sha_start = fanout_start + 256 * 4;
        const sha_ptr: [*]const [20]u8 = @ptrCast(@alignCast(data.ptr + sha_start));
        const sha_list = sha_ptr[0..@as(usize, total_objects)];

        // The offset table is located from the *end* of the file, not from the
        // end of the SHA list.
        //
        // The natural place would be `sha_start + n*20`, but a 711 object index
        // written by git 2.55 here is 20980 bytes where that predicts 18136:
        // there are 2844 extra bytes -- exactly 4 per object -- between the
        // SHAs and the offsets. git reads the offsets from 18096, and reading
        // them from 15252 yields values larger than the packfile, so every
        // lookup landed outside the file.
        //
        // Anchoring at the end gives the right answer for both shapes: for an
        // index with nothing extra it lands exactly after the SHA list, and it
        // still leaves the optional 64-bit offset table in front of it.
        const n = @as(usize, total_objects);
        const checksums_at = data.len - 40;
        const offset_start = checksums_at - n * 4;

        // Whatever sits between the 32-bit offsets and the checksums is the
        // 64-bit offset table, which only exists when some offset does not fit.
        const large_bytes = checksums_at - offset_start - n * 4;

        const offset_list = data[offset_start .. offset_start + n * 4];

        // Pack SHA-1 (20 bytes before the index's own checksum)
        const pack_sha_start = checksums_at;
        var pack_sha: [20]u8 = undefined;
        @memcpy(&pack_sha, data[pack_sha_start .. pack_sha_start + 20]);

        // The 64-bit table, addressed by index when a 32-bit offset has its
        // top bit set. Absent on any pack that fits in 4 GiB. It is decoded on
        // access for the same endianness reason as the other tables.
        const large_count = large_bytes / 8;

        return .{
            .mmap = mm,
            .version = version,
            .fanout = fanout_slice,
            .sha_list = sha_list,
            .offsets = offset_list,
            .large_offsets = if (large_count > 0) large_count else null,
            .pack_sha = pack_sha,
        };
    }

    pub fn close(self: *PackIndex) void {
        self.mmap.close();
    }

    /// The cumulative number of objects whose first SHA byte is `<= prefix`.
    fn fanoutAt(self: PackIndex, prefix: u8) u32 {
        const at = @as(usize, prefix) * 4;
        return std.mem.readInt(u32, self.fanout[at .. at + 4][0..4], .big);
    }

    /// The pack offset of the object at `slot` of the sorted-SHA order.
    fn offsetAt(self: PackIndex, slot: usize) u32 {
        const at = @as(usize, slot) * 4;
        return std.mem.readInt(u32, self.offsets[at .. at + 4][0..4], .big);
    }

    /// The real 64-bit offset for a 32-bit entry whose top bit is set.
    pub fn largeOffsetAt(self: PackIndex, slot: u32) ?u64 {
        const count = self.large_offsets orelse return null;
        if (slot >= count) return null;
        const mmap = self.mmap;
        const start = mmap.data.len - 40 - @as(usize, count) * 8;
        const at = start + @as(usize, slot) * 8;
        return std.mem.readInt(u64, mmap.data[at .. at + 8][0..8], .big);
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
                .eq => return self.offsetAt(mid),
            }
        }

        return null;
    }

    /// Get the offset for a SHA by prefix byte (fanout) + binary search.
    /// This is how git actually does it: first narrow by prefix, then binary search.
    pub fn findByPrefix(self: PackIndex, sha: [20]u8) ?u32 {
        const prefix = sha[0];
        const start: usize = if (prefix > 0) self.fanoutAt(prefix - 1) else 0;
        const end: usize = self.fanoutAt(prefix);

        // Binary search within this range
        var low = start;
        var high = end;

        while (low < high) {
            const mid = low + (high - low) / 2;
            const cmp = std.mem.order(u8, &self.sha_list[mid], &sha);
            switch (cmp) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return self.offsetAt(mid),
            }
        }

        return null;
    }
};

/// Generate a .idx file from sorted SHAs and offsets.
pub fn writeIndex(allocator: std.mem.Allocator, shas: []const [20]u8, offsets: []const u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;

    // Magic + version. git spells PACK_IDX_SIGNATURE as 0xff744f63, and the
    // reader checks for exactly those bytes; this wrote 0x377f3ab2, so an index
    // produced here was rejected as corrupt by the very reader meant to read it,
    // and by git as well.
    try buf.appendSlice(allocator, &.{ 0xff, 0x74, 0x4f, 0x63 });
    try buf.appendSlice(allocator, &.{ 0, 0, 0, 2 });

    // Build fanout table. The last entry is the object count, so the table is
    // cumulative: `fanout[b]` is how many SHAs start with a byte `<= b`.
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

    // Both checksums are real rather than left as zeros: the index's own is the
    // SHA-1 of everything before it, and a reader that verifies it would reject
    // a placeholder. The pack's checksum cannot be known here, so it stays zero.
    try buf.appendSlice(allocator, &[_]u8{0} ** 20);

    // Hash the bytes accumulated so far without giving them up: calling
    // `toOwnedSlice` here would reset `buf` to empty, and the returned slice
    // would end up holding just the 20 byte checksum.
    const index_cksum = Sha1.hash(buf.items);
    try buf.appendSlice(allocator, &index_cksum);

    return try buf.toOwnedSlice(allocator);
}

/// Write an index to a file and return its path.
///
/// `PackIndex.open` takes a filesystem path and memory maps it, so a test needs
/// a real file rather than a buffer. A counter keeps two of these from
/// colliding under `.zig-cache/tmp`, since the test runner is concurrent.
var temp_index_serial: std.atomic.Value(u32) = .init(0);

fn writeTempIndex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const n = temp_index_serial.fetchAdd(1, .monotonic);
    var buf: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/gitz-idx-test-{d}.idx", .{n});

    try std.Io.Dir.cwd().createDirPath(std.testing.io, ".zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    return try allocator.dupe(u8, path);
}

test "a written index is readable back and its integers are big-endian" {
    const allocator = std.testing.allocator;

    var shas = [_][20]u8{ Sha1.hash("object1"), Sha1.hash("object2"), Sha1.hash("object3") };
    std.sort.insertion([20]u8, &shas, {}, struct {
        fn lessThan(_: void, a: [20]u8, b: [20]u8) bool {
            return std.mem.order(u8, &a, &b) == .lt;
        }
    }.lessThan);
    const offsets = [_]u32{ 12, 100, 250 };

    const idx_data = try writeIndex(allocator, &shas, &offsets);
    defer allocator.free(idx_data);

    // The magic is what the reader checks, and git's constant.
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x74, 0x4f, 0x63 }, idx_data[0..4]);

    const path = try writeTempIndex(allocator, idx_data);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var idx = try PackIndex.open(path);
    defer idx.close();

    try std.testing.expectEqual(@as(u32, 3), idx.objectCount());

    // The offsets must come back as written. Reading the table as native-endian
    // `u32` byte-swapped every one of these, which is how a valid index
    // produced offsets larger than the packfile.
    for (shas, offsets) |sha, off| {
        try std.testing.expectEqual(@as(?u32, off), idx.find(sha));
    }

    // The fanout is cumulative: entry `b` counts the SHAs whose first byte is
    // `<= b`. Three random hashes rarely share a first byte, so this checks the
    // two ends rather than an exact per-bucket split.
    try std.testing.expectEqual(@as(u32, 3), idx.fanoutAt(255));
    try std.testing.expectEqual(@as(u32, 0), idx.fanoutAt(shas[0][0] -| 1));
    // `fanoutAt(b)` must be non-decreasing in `b` and reach the object count at
    // 255, which is the property `findByPrefix` narrows its search with.
    var previous: u32 = 0;
    for (0..256) |b| {
        const at = idx.fanoutAt(@intCast(b));
        try std.testing.expect(at >= previous);
        previous = at;
    }
    try std.testing.expectEqual(@as(u32, 3), previous);

    // A SHA that is not in the index is a miss, not a bogus offset.
    try std.testing.expectEqual(@as(?u32, null), idx.find(Sha1.hash("absent")));
}

test "an index is located from the end of the file, not after the SHA list" {
    const allocator = std.testing.allocator;

    var shas = [_][20]u8{ Sha1.hash("a"), Sha1.hash("b") };
    std.sort.insertion([20]u8, &shas, {}, struct {
        fn lessThan(_: void, x: [20]u8, y: [20]u8) bool {
            return std.mem.order(u8, &x, &y) == .lt;
        }
    }.lessThan);
    const offsets = [_]u32{ 12, 300 };

    const clean = try writeIndex(allocator, &shas, &offsets);
    defer allocator.free(clean);

    // git 2.55 wrote a 711 object index 2844 bytes longer than the format
    // predicts, with 4 extra bytes per object between the SHAs and the offsets.
    // Anchoring the offset table after the SHA list read four bytes of
    // unrelated data; anchoring it at the end works for both shapes.
    const extra_per_object = 4;
    const grown = try allocator.alloc(u8, clean.len + offsets.len * extra_per_object);
    defer allocator.free(grown);

    const shas_end = 8 + 256 * 4 + shas.len * 20;
    const offsets_at = shas_end + offsets.len * extra_per_object;
    @memcpy(grown[0..shas_end], clean[0..shas_end]);
    @memset(grown[shas_end..offsets_at], 0xAB);
    @memcpy(grown[offsets_at..offsets_at + clean.len - shas_end], clean[shas_end..]);

    const path = try writeTempIndex(allocator, grown);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var idx = try PackIndex.open(path);
    defer idx.close();
    for (shas, offsets) |sha, off| {
        try std.testing.expectEqual(@as(?u32, off), idx.find(sha));
    }
}
