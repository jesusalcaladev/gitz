const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const zlib_mod = @import("zlib.zig");
const delta_mod = @import("delta.zig");
const object = @import("object.zig");
const storage_mod = @import("storage.zig").StorageBackend;

/// Unpack a packfile received over the wire into loose objects.
///
/// The transports' own packfile path only handled the four base object types
/// and stopped at the first `else => break`, so it silently dropped everything
/// from the first delta onwards. A real server is asked for `ofs-delta` and
/// duly sends a pack that is mostly deltas, so a clone taken over the native
/// transport lost most of its objects and then failed to check out.
///
/// This walks the pack by offset, which is what delta bases are expressed in,
/// and keeps a SHA-to-offset map so a `ref-delta` base still resolves. A thin
/// pack is never requested, so every base is inside this pack; a base that
/// cannot be found is a hard error rather than something to skip, because
/// skipping would leave a commit pointing at a blob that does not exist.
pub const Ingest = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_dir: []const u8,

    /// A server will not build a chain this long, but a hostile pack could, and
    /// resolving one recursively without a bound is a stack overflow.
    const max_chain_depth = 64;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, repo_dir: []const u8) Ingest {
        return .{ .allocator = allocator, .io = io, .repo_dir = repo_dir };
    }

    /// Number of objects written.
    pub fn run(self: Ingest, pack: []const u8) !u32 {
        if (pack.len < 12) return error.PackTooShort;
        if (!std.mem.eql(u8, pack[0..4], "PACK")) return error.NotAPackfile;

        const version = std.mem.readInt(u32, pack[4..8], .big);
        if (version != 2 and version != 3) return error.UnsupportedPackVersion;
        const count = std.mem.readInt(u32, pack[8..12], .big);

        var by_sha = std.AutoHashMap([20]u8, usize).init(self.allocator);
        defer by_sha.deinit();

        var pos: usize = 12;
        var written: u32 = 0;

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (pos >= pack.len) return error.PackTruncated;

            // The offset this object *starts* at is what a later ref-delta needs
            // to find it. Advancing `pos` first and passing the new value
            // registered every SHA one object too far along, so a ref-delta
            // resolved against its neighbour's data.
            const obj_start = pos;
            const resolved = try self.resolveAt(pack, obj_start, &by_sha, 0);
            try self.write(resolved.resolved_type, resolved.data, &by_sha, obj_start);
            pos = resolved.next_offset;
            written += 1;
        }

        return written;
    }

    const Resolved = struct {
        /// The object's real type, after any delta chain.
        resolved_type: delta_mod.ObjType,
        /// Owned by the caller.
        data: []u8,
        next_offset: usize,
    };

    /// Materialise the object at `offset`, following its delta chain.
    fn resolveAt(
        self: Ingest,
        pack: []const u8,
        offset: usize,
        by_sha: *std.AutoHashMap([20]u8, usize),
        depth: u32,
    ) !Resolved {
        if (depth > max_chain_depth) return error.DeltaChainTooDeep;

        const hdr = try delta_mod.parsePackHeader(pack, offset);

        switch (hdr.obj_type) {
            .commit, .tree, .blob, .tag => {
                const data = try delta_mod.decompressZlibAt(self.allocator, pack, hdr.content_start);
                return .{
                    .resolved_type = hdr.obj_type,
                    .data = data,
                    .next_offset = try self.endOfStream(pack, hdr.content_start),
                };
            },

            .ofs_delta => {
                const distance = try parseOfsBase(pack, hdr.content_start);
                // The encoding is the distance back from *this* object.
                if (distance > offset) return error.InvalidDeltaBase;
                const at = offset - distance;

                const base = try self.resolveAt(pack, at, by_sha, depth + 1);
                defer self.allocator.free(base.data);

                const delta = try delta_mod.decompressZlibAt(self.allocator, pack, hdr.content_start_after_ofs);
                defer self.allocator.free(delta);
                const out = try delta_mod.applyDelta(self.allocator, base.data, delta);

                return .{
                    .resolved_type = base.resolved_type,
                    .data = out,
                    .next_offset = try self.endOfStream(pack, hdr.content_start_after_ofs),
                };
            },

            .ref_delta => {
                const base_sha = delta_mod.readSha(pack, hdr.content_start);
                const at = by_sha.get(base_sha) orelse return error.BaseObjectNotFound;

                const base = try self.resolveAt(pack, at, by_sha, depth + 1);
                defer self.allocator.free(base.data);

                const delta = try delta_mod.decompressZlibAt(self.allocator, pack, hdr.content_start_after_ofs);
                defer self.allocator.free(delta);
                const out = try delta_mod.applyDelta(self.allocator, base.data, delta);

                return .{
                    .resolved_type = base.resolved_type,
                    .data = out,
                    .next_offset = try self.endOfStream(pack, hdr.content_start_after_ofs),
                };
            },
        }
    }

    fn write(
        self: Ingest,
        obj_type: delta_mod.ObjType,
        data: []const u8,
        by_sha: *std.AutoHashMap([20]u8, usize),
        offset: usize,
    ) !void {
        const type_str = typeName(obj_type) orelse return error.UnknownObjectType;

        // A loose object is "<type> <size>\0<content>", and that is also the
        // input to its SHA-1, so one buffer serves both.
        const header = try std.fmt.allocPrint(self.allocator, "{s} {d}\x00", .{ type_str, data.len });
        defer self.allocator.free(header);

        const full = try self.allocator.alloc(u8, header.len + data.len);
        defer self.allocator.free(full);
        @memcpy(full[0..header.len], header);
        @memcpy(full[header.len..], data);

        const sha = Sha1.hash(full);
        // A ref-delta later in the pack can name this object as its base.
        try by_sha.put(sha, offset);

        const obj_type_enum: object.ObjectType = switch (obj_type) {
            .commit => .commit,
            .tree => .tree,
            .blob => .blob,
            .tag => .tag,
            else => return error.UnknownObjectType,
        };

        const backend = storage_mod.fromConfig(self.repo_dir, null);
        try backend.writeRaw(self.allocator, self.io, obj_type_enum, full);
    }

    /// Where the next object begins: the byte after this zlib stream ends.
    ///
    /// `decompressCounted` reports the compressed length it consumed, which is
    /// the only exact answer. Falling back to the inflated size keeps the walk
    /// making progress rather than looping, should a stream ever be unreadable.
    fn endOfStream(self: Ingest, pack: []const u8, start: usize) !usize {
        const result = zlib_mod.zlib.decompressCounted(self.allocator, pack[start..]) catch {
            return start + 1;
        };
        defer self.allocator.free(result.data);
        return start + result.consumed;
    }
};

/// OFS_DELTA encodes the base as a distance backwards, in 7-bit groups,
/// big-endian, where a continuation bit on any byte means another group follows.
fn parseOfsBase(pack: []const u8, at: usize) !usize {
    if (at >= pack.len) return error.PackTruncated;
    var pos = at;
    var byte = pack[pos];
    pos += 1;
    var value: usize = byte & 0x7f;
    while (byte & 0x80 != 0) {
        if (pos >= pack.len) return error.PackTruncated;
        byte = pack[pos];
        pos += 1;
        value = ((value + 1) << 7) | (byte & 0x7f);
    }
    return value;
}

fn typeName(t: delta_mod.ObjType) ?[]const u8 {
    return switch (t) {
        .commit => "commit",
        .tree => "tree",
        .blob => "blob",
        .tag => "tag",
        else => null,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ofs-delta base distance, single byte" {
    const bytes = [_]u8{0x05};
    try std.testing.expectEqual(@as(usize, 5), try parseOfsBase(&bytes, 0));
}

test "ofs-delta base distance, two bytes" {
    // git's rule is: on each continuation byte, add one, shift left by seven,
    // then OR in the low seven bits. So 0x82 0x07 is (2 + 1) << 7 | 7 = 391 --
    // not the 263 a plain "shift and OR" reading would give.
    const bytes = [_]u8{ 0x82, 0x07 };
    try std.testing.expectEqual(@as(usize, 391), try parseOfsBase(&bytes, 0));
}

test "ofs-delta base distance, three bytes" {
    const bytes = [_]u8{ 0xff, 0x80, 0x00 };
    try std.testing.expectEqual(@as(usize, 2097280), try parseOfsBase(&bytes, 0));
}

test "ofs-delta base distance matches git's algorithm across encodings" {
    // 0x9b 0x21 appears in git's own packfile tests as a two-byte offset.
    const bytes = [_]u8{ 0x9b, 0x21 };
    try std.testing.expectEqual(@as(usize, 3617), try parseOfsBase(&bytes, 0));
}

test "a stream that is not a packfile is rejected" {
    const gitz = Ingest.init(std.testing.allocator, std.testing.io, "/tmp/gitz-test-ingest-nope");
    try std.testing.expectError(error.NotAPackfile, gitz.run("NOPE not a pack at all"));
}
