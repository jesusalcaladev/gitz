const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const zlib_mod = @import("zlib.zig");
const packindex_mod = @import("packindex.zig");
const packfile_mod = @import("packfile.zig");
const object_mod = @import("object.zig");
const mmap_mod = @import("mmap.zig");
const loose_mod = @import("loose.zig");

const GitObject = object_mod.GitObject;
const ObjectType = object_mod.ObjectType;
const PackIndex = packindex_mod.PackIndex;

/// Read objects out of `objects/pack/pack-*.pack`.
///
/// GitZ could already *write* packfiles and had a working `.idx` binary search
/// and pack header parser, but nothing on the read path used them: the storage
/// union only had `loose` and `shard` variants. So a repository whose history
/// had been packed -- which is what every real `git gc` produces -- was
/// invisible: `gitz log` reported the handful of loose objects and nothing else.
///
/// The layout is git's, so a pack written by git reads here and vice versa.
/// A `.idx` is memory mapped, and an object is found by binary search over the
/// sorted SHA list rather than by scanning.
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    packs: []Pack,
    /// Consulted for `ref_delta` bases, and as a fallback for objects that are
    /// not packed. A thin pack omits bases it expects the client to have, and
    /// even a full one can be read alongside loose objects during a fetch.
    loose: loose_mod.LooseStore,

    pub const Pack = struct {
        index: PackIndex,
        data: []const u8,
        pub fn close(self: *Pack) void {
            self.index.close();
        }

        /// The real offset of an object.
        ///
        /// A 32-bit offset with the top bit set is an index into the index's
        /// 64-bit table rather than an offset. Returning it as-is would send the
        /// reader to a position billions of bytes past the end of the pack.
        pub fn offsetOf(self: Pack, raw: u32) ?usize {
            if (raw & 0x8000_0000 == 0) return raw;
            const at = raw & 0x7fff_ffff;
            const v = self.index.largeOffsetAt(at) orelse return null;
            if (v > self.data.len) return null;
            return @intCast(v);
        }
    };

    /// Open every pack in `<repo>/objects/pack/`. An absent or unreadable pack
    /// is skipped rather than fatal: loose objects may still hold what is
    /// wanted, and a repository with no packs is the normal case here.
    ///
    /// `repo_dir` is the directory holding `objects/`, matching `LooseStore`.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, repo_dir: []const u8) !Store {
        const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{repo_dir});
        defer allocator.free(pack_dir);

        var packs: std.ArrayList(Pack) = .empty;
        errdefer {
            for (packs.items) |*p| p.close();
            packs.deinit(allocator);
        }

        var dir = std.Io.Dir.cwd().openDir(io, pack_dir, .{ .iterate = true }) catch
            return .{
                .allocator = allocator,
                .io = io,
                .packs = &.{},
                .loose = loose_mod.LooseStore.init(repo_dir),
            };
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
            if (std.mem.endsWith(u8, entry.name, ".rev")) continue;

            const stem = entry.name[0 .. entry.name.len - 4];
            const idx_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
            defer allocator.free(idx_path);
            const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}.pack", .{ pack_dir, stem });
            defer allocator.free(pack_path);

            var idx = PackIndex.open(idx_path) catch continue;
            errdefer idx.close();

            // mmap_mod gives the reader its own view; the pack itself is read
            // into memory because object offsets are absolute into it.
            const raw = std.Io.Dir.cwd().readFileAlloc(io, pack_path, allocator, .unlimited) catch {
                idx.close();
                continue;
            };

            try packs.append(allocator, .{
                .index = idx,
                .data = raw,
            });
        }

        return .{
            .allocator = allocator,
            .io = io,
            .packs = try packs.toOwnedSlice(allocator),
            .loose = loose_mod.LooseStore.init(repo_dir),
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.packs) |*p| {
            p.close();
            self.allocator.free(p.data);
        }
        self.allocator.free(self.packs);
    }

    pub fn count(self: Store) usize {
        return self.packs.len;
    }

    /// Read an object by id, from any pack or from the loose store.
    pub fn read(self: Store, allocator: std.mem.Allocator, sha: [20]u8) anyerror!GitObject {
        for (self.packs) |*pack| {
            const raw = pack.index.find(sha) orelse continue;
            const offset = pack.offsetOf(raw) orelse continue;
            const found = try self.readAt(allocator, pack, offset, 0);
            return found.toObject(allocator);
        }
        return self.loose.read(allocator, self.io, sha);
    }

    /// Read an object by id and return it as type plus bare content, with no
    /// `"type <len>\0"` header.
    ///
    /// `read` deserializes into a `GitObject`, which is what commands want, but
    /// resolving a delta needs the content itself: a delta applies to the
    /// base's bytes, not to a re-serialized object.
    pub fn readRawContent(self: Store, allocator: std.mem.Allocator, sha: [20]u8) anyerror!Raw {
        for (self.packs) |*pack| {
            const raw = pack.index.find(sha) orelse continue;
            const offset = pack.offsetOf(raw) orelse continue;
            return self.readAt(allocator, pack, offset, 0);
        }

        // A base that is not packed at all: read the loose file and strip the
        // header, which is the one transformation between the two forms.
        const obj = try self.loose.read(allocator, self.io, sha);
        defer obj.deinit(allocator);
        const serialized = try obj.serialize(allocator);
        defer allocator.free(serialized);

        const nul = std.mem.indexOfScalar(u8, serialized, 0) orelse return error.InvalidObject;
        const header = serialized[0..nul];
        const space = std.mem.indexOfScalar(u8, header, ' ') orelse return error.InvalidObject;
        const type_name = header[0..space];

        const obj_type: packfile_mod.ObjectType = if (std.mem.eql(u8, type_name, "blob"))
            .blob
        else if (std.mem.eql(u8, type_name, "tree"))
            .tree
        else if (std.mem.eql(u8, type_name, "commit"))
            .commit
        else if (std.mem.eql(u8, type_name, "tag"))
            .tag
        else
            return error.InvalidObject;

        return .{
            .obj_type = obj_type,
            .data = try allocator.dupe(u8, serialized[nul + 1 ..]),
        };
    }

    /// Whether the object is available, without inflating anything.
    pub fn exists(self: Store, sha: [20]u8) bool {
        for (self.packs) |*pack| {
            if (pack.index.find(sha)) |raw| {
                if (pack.offsetOf(raw) != null) return true;
            }
        }
        return self.loose.exists(self.io, sha);
    }

    /// Read an object that may be a delta, following the chain to a base
    /// object and rebuilding the content on the way back up.
    ///
    /// The return type is spelled out rather than inferred: `read` and `readAt`
    /// are mutually recursive -- a `ref_delta` base is looked up by id, which
    /// can land in another pack -- and two functions inferring each other's error
    /// set is a dependency cycle the compiler rejects.
    fn readAt(self: Store, allocator: std.mem.Allocator, pack: *const Pack, offset: usize, depth: u32) anyerror!Raw {
        if (depth > max_chain_depth) return error.DeltaChainTooDeep;

        const header = try packfile_mod.PackReader.init(pack.data);
        const h = try header.getObjectAt(offset);

        switch (h.obj_type) {
            .commit, .tree, .blob, .tag => {
                const data = try zlib_mod.zlib.decompressCounted(allocator, pack.data[h.data_offset..]);
                return .{ .obj_type = h.obj_type, .data = data.data };
            },

            .ofs_delta => {
                // The base is expressed as a distance back from this object, so
                // it is always earlier in the same pack.
                const distance = try parseOfsBase(pack.data, h.data_offset);
                if (distance > offset) return error.InvalidDeltaBase;
                const base = try self.readAt(allocator, pack, offset - distance, depth + 1);
                defer allocator.free(base.data);

                const delta = try zlib_mod.zlib.decompressCounted(allocator, pack.data[h.data_offset + ofsLen(pack.data[h.data_offset..])..]);
                defer allocator.free(delta.data);

                return .{
                    .obj_type = base.obj_type,
                    .data = try delta_apply(allocator, base.data, delta.data),
                };
            },

            .ref_delta => {
                const base_sha = h.ref_delta_sha orelse return error.InvalidDeltaBase;
                // The base may live in another pack, or not be packed at all.
                //
                // It is read as raw content rather than through `read`, because a
                // delta is defined against the base's *content*, and the packed
                // `ofs_delta` path above works on content for exactly that
                // reason. Going via `GitObject.serialize` would prepend the
                // `"blob <len>\0"` header and every delta would apply to the
                // wrong bytes.
                const base = try self.readRawContent(allocator, base_sha);
                defer allocator.free(base.data);

                // `data_offset` already sits past the base id: `getObjectAt` consumes the
                // 20 bytes of the `ref_delta` header. Adding another 20 landed 20
                // bytes into the compressed stream, which inflated to nothing and
                // made `applyDelta` fail reading the base size.
                const delta = try zlib_mod.zlib.decompressCounted(allocator, pack.data[h.data_offset..]);
                defer allocator.free(delta.data);

                // The base's type is the delta's type, carried in the pack's
                // own enum rather than the object union's.
                const out_type: packfile_mod.ObjectType = base.obj_type;
                return .{
                    .obj_type = out_type,
                    .data = try delta_apply(allocator, base.data, delta.data),
                };
            },
        }
    }

    /// A server will not build a chain this long; a hostile pack could, and
    /// resolving one recursively without a bound is a stack overflow.
    const max_chain_depth = 64;

    const Raw = struct {
        obj_type: packfile_mod.ObjectType,
        data: []u8,

        /// The pack stores type and content separately, with no "type size\0"
        /// header; the same deserializer the loose store uses turns the content
        /// into a `GitObject`. The blob's content is borrowed, as it is there.
        fn toObject(self: Raw, allocator: std.mem.Allocator) !GitObject {
            const t: ObjectType = switch (self.obj_type) {
                .commit => .commit,
                .tree => .tree,
                .blob => .blob,
                .tag => .tag,
                else => return error.NotABaseObject,
            };
            return object_mod.deserialize(allocator, t, self.data);
        }
    };
};

/// OFS_DELTA encodes its base as a distance backwards, seven bits per byte,
/// with a continuation bit. Each continuation shifts the accumulated value left
/// by seven *after* adding one, which is not the same as a plain shift.
fn parseOfsBase(data: []const u8, at: usize) !usize {
    if (at >= data.len) return error.PackTruncated;
    var pos = at;
    var b = data[pos];
    pos += 1;
    var value: usize = b & 0x7f;
    while (b & 0x80 != 0) {
        if (pos >= data.len) return error.PackTruncated;
        b = data[pos];
        pos += 1;
        value = ((value + 1) << 7) | (b & 0x7f);
    }
    return value;
}

/// How many bytes the base-distance varint at `at` occupies, so the delta data
/// can be located after it.
fn ofsLen(at_data: []const u8) usize {
    if (at_data.len == 0) return 1;
    var n: usize = 1;
    while (n < at_data.len and at_data[n - 1] & 0x80 != 0) n += 1;
    return n;
}

fn delta_apply(allocator: std.mem.Allocator, base: []const u8, delta: []const u8) ![]u8 {
    return @import("delta.zig").applyDelta(allocator, base, delta);
}

// ============================================================================
// TESTS
// ============================================================================

/// Append `value` as a 7-bits-per-byte little-endian varint with a continuation
/// bit on every byte but the last.
fn appendVarint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: usize) !void {
    var v = value;
    while (v >= 0x80) {
        try out.append(allocator, @as(u8, @intCast(v & 0x7f)) | 0x80);
        v >>= 7;
    }
    try out.append(allocator, @as(u8, @intCast(v)));
}

test "an object stored only in a packfile reads back with the right content" {
    const allocator = std.testing.allocator;
    const content = "the quick brown fox";
    const sha = Sha1.hash(content);

    // Build a one-object pack: header, then the object header and its zlib
    // stream, then the trailing checksum.
    const compressed = try zlib_mod.zlib.compress(allocator, content);
    defer allocator.free(compressed);

    var pack: std.ArrayList(u8) = .empty;
    defer pack.deinit(allocator);
    try pack.appendSlice(allocator, "PACK");
    var num: [4]u8 = undefined;
    std.mem.writeInt(u32, &num, 2, .big);
    try pack.appendSlice(allocator, &num);
    std.mem.writeInt(u32, &num, 1, .big);
    try pack.appendSlice(allocator, &num);
    // Type 3 (blob) with the size in the low four bits.
    try pack.append(allocator, 0x30 | @as(u8, @intCast(content.len)));
    try pack.appendSlice(allocator, compressed);
    try pack.appendSlice(allocator, &[_]u8{0} ** 20);

    const shas = [_][20]u8{sha};
    const offsets = [_]u32{12};
    const idx_data = try @import("packindex.zig").writeIndex(allocator, &shas, &offsets);
    defer allocator.free(idx_data);

    // The store looks in `<repo>/objects/pack`, so give it that shape.
    const repo = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/gitz-store-{x}", .{@intFromPtr(&idx_data)});
    defer allocator.free(repo);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, repo);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, repo) catch {};
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{repo});
    defer allocator.free(pack_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, pack_dir);
    {
        const p_path = try std.fmt.allocPrint(allocator, "{s}/gitz-store-test.pack", .{pack_dir});
        defer allocator.free(p_path);
        const i_path = try std.fmt.allocPrint(allocator, "{s}/gitz-store-test.idx", .{pack_dir});
        defer allocator.free(i_path);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = p_path, .data = pack.items });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = i_path, .data = idx_data });
    }

    var store = try Store.open(allocator, std.testing.io, repo);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expect(store.exists(sha));

    const obj = try store.read(allocator, sha);
    defer obj.deinit(allocator);
    try std.testing.expectEqualStrings(content, obj.blob.content);
}

// A `ref_delta` names its base by id, and the base need not be in the same
// pack, so this checks the shallow case where the base lives in a loose object.
test "a delta whose base is loose resolves through the loose store" {
    const allocator = std.testing.allocator;
    const base_content = "aaaaabbbbcccccdddddeeeeefffffggggg";
    const base_sha = Sha1.hash(base_content);

    // A delta inserting "XY" after the first five bytes. The stream opens with
    // the base size and the result size as varints, both of which
    // `applyDelta` checks, so they have to be right.
    var delta: std.ArrayList(u8) = .empty;
    defer delta.deinit(allocator);
    // The two sizes are varints, one byte each while they stay under 128, not
    // decimal text: 35 is the byte 0x23, whereas "35" read as a varint is 51.
    try appendVarint(allocator, &delta, base_content.len);
    try appendVarint(allocator, &delta, base_content.len + 2);
    // Copy the first five bytes: 0x80 marks a copy and 0x10 says a one byte length
    // follows. The offset defaults to zero.
    try delta.append(allocator, 0x90);
    try delta.append(allocator, 5);
    // Insert two literal bytes.
    try delta.append(allocator, 2);
    try delta.appendSlice(allocator, "XY");
    // Copy the rest from offset five: the low offset bit set makes a one byte
    // offset follow the length, and without it the copy would start at zero
    // again and repeat the first five bytes.
    try delta.append(allocator, 0x91);
    try delta.append(allocator, 5);
    try delta.append(allocator, base_content.len - 5);

    var target: std.ArrayList(u8) = .empty;
    defer target.deinit(allocator);
    try target.appendSlice(allocator, base_content[0..5]);
    try target.appendSlice(allocator, "XY");
    try target.appendSlice(allocator, base_content[5..]);

    const expected_sha = Sha1.hash(target.items);

    const compressed = try zlib_mod.zlib.compress(allocator, delta.items);
    defer allocator.free(compressed);

    var pack: std.ArrayList(u8) = .empty;
    defer pack.deinit(allocator);
    try pack.appendSlice(allocator, "PACK");
    var num: [4]u8 = undefined;
    std.mem.writeInt(u32, &num, 2, .big);
    try pack.appendSlice(allocator, &num);
    std.mem.writeInt(u32, &num, 1, .big);
    try pack.appendSlice(allocator, &num);
    try pack.append(allocator, 0x70); // type 7, ref_delta
    try pack.appendSlice(allocator, &base_sha);
    try pack.appendSlice(allocator, compressed);
    try pack.appendSlice(allocator, &[_]u8{0} ** 20);

    const shas = [_][20]u8{expected_sha};
    const offsets = [_]u32{12};
    const idx_data = try @import("packindex.zig").writeIndex(allocator, &shas, &offsets);
    defer allocator.free(idx_data);

    const repo = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/gitz-delta-{x}", .{@intFromPtr(&idx_data)});
    defer allocator.free(repo);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, repo);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, repo) catch {};
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{repo});
    defer allocator.free(pack_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, pack_dir);
    const p_path = try std.fmt.allocPrint(allocator, "{s}/t.pack", .{pack_dir});
    defer allocator.free(p_path);
    const i_path = try std.fmt.allocPrint(allocator, "{s}/t.idx", .{pack_dir});
    defer allocator.free(i_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = p_path, .data = pack.items });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = i_path, .data = idx_data });

    // The base goes in as a loose object, the way a thin pack's base would be.
    // The loose layout is `objects/<first two hex digits>/<remaining 38>`,
    // which is exactly what `LooseStore` builds the path from.
    const base_hex = Sha1.hex(base_sha);
    const loose_dir = try std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ repo, base_hex[0..2] });
    defer allocator.free(loose_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, loose_dir);
    var loose: std.ArrayList(u8) = .empty;
    defer loose.deinit(allocator);
    try loose.appendSlice(allocator, "blob ");
    var num_buf: [24]u8 = undefined;
    try loose.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{base_content.len}));
    try loose.append(allocator, 0);
    try loose.appendSlice(allocator, base_content);

    // A loose object is stored zlib compressed, and `LooseStore` falls back to
    // treating the file as uncompressed only if inflation fails -- which for a
    // header beginning "blob " it may not, silently yielding garbage.
    const loose_compressed = try zlib_mod.zlib.compress(allocator, loose.items);
    defer allocator.free(loose_compressed);
    const loose_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ loose_dir, base_hex[2..] });
    defer allocator.free(loose_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = loose_path, .data = loose_compressed });

    var store = try Store.open(allocator, std.testing.io, repo);
    defer store.deinit();

    const obj = try store.read(allocator, expected_sha);
    defer obj.deinit(allocator);
    try std.testing.expectEqualStrings(target.items, obj.blob.content);
}
