const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const object = @import("object.zig");
const zlib_mod = @import("zlib.zig");
const loose_mod = @import("loose.zig");
const shard_mod = @import("shard_store.zig");

const GitObject = object.GitObject;
const ObjectType = object.ObjectType;

/// Object alternates — the GitZ alternative to Git's "clone copies everything".
///
/// A clone that references a source repo instead of copying objects is
/// implemented through an alternates file: `objects/info/alternates`.
///
/// Each line in the file is the path to another repository's *object
/// directory* (or a directory containing loose objects). When an object is not
/// found in the local store, GitZ falls back to checking each alternate in
/// order. This gives us:
///
///   - Instant clones (no object transfer speed / disk cost for existing data)
///   - Shared physical storage for many clones of the same history (dedup)
///   - A scaling path: a large "base" repo can back thousands of cheap clones
///     without duplicating gigabytes of objects
pub const Alternates = struct {
    git_dir: []const u8,

    pub fn init(git_dir: []const u8) Alternates {
        return .{ .git_dir = git_dir };
    }

    /// Path to the alternates file: git_dir/objects/info/alternates
    pub fn filePath(self: Alternates, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/objects/info/alternates", .{self.git_dir});
    }

    /// Write the alternates file. `paths` are the object directories to
    /// reference (one per line). Creates objects/info/ as needed.
    pub fn write(self: Alternates, allocator: std.mem.Allocator, io: std.Io, paths: []const []const u8) !void {
        const info_dir = try std.fmt.allocPrint(allocator, "{s}/objects/info", .{self.git_dir});
        defer allocator.free(info_dir);
        try std.Io.Dir.cwd().createDirPath(io, info_dir);

        const file_path = try self.filePath(allocator);
        defer allocator.free(file_path);

        var f = try std.Io.Dir.cwd().createFile(io, file_path, .{});
        defer f.close(io);

        for (paths) |p| {
            try std.Io.File.writeStreamingAll(f, io, p);
            try std.Io.File.writeStreamingAll(f, io, "\n");
        }
    }

    /// Read the list of alternate object directories. Returns an empty slice
    /// if the file does not exist or is empty. The caller owns the returned
    /// slice and its strings.
    pub fn read(self: Alternates, allocator: std.mem.Allocator, io: std.Io) ![][]const u8 {
        const file_path = self.filePath(allocator) catch return &.{};
        defer allocator.free(file_path);

        const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .unlimited) catch return &.{};
        defer allocator.free(content);

        var result: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
        errdefer {
            for (result.items) |s| allocator.free(s);
            result.deinit(allocator);
        }

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (line[0] == '#') continue;
            const owned = allocator.dupe(u8, line) catch continue;
            result.append(allocator, owned) catch {
                allocator.free(owned);
                continue;
            };
        }

        return result.toOwnedSlice(allocator);
    }

    /// Given the "rel_path" (the "XX/YYYY" portion relative to an object dir),
    /// return the resolved absolute path where the object physically lives in
    /// any alternate, or null if not found anywhere.
    ///
    /// Resolution order per alternate:
    ///   1. Loose layout:        alternate/XX/YYYY
    ///   2. Shard layout:        alternate/shard_NN/XX/YYYY (any NN that exists)
    ///
    /// This makes shared clones work regardless of whether the source repo uses
    /// the loose or shard storage backend.
    pub fn resolve(self: Alternates, allocator: std.mem.Allocator, io: std.Io, rel_path: []const u8) !?[]u8 {
        const alts = try self.read(allocator, io);
        defer {
            for (alts) |s| allocator.free(s);
            allocator.free(alts);
        }

        var shard_buf: [256]u8 = undefined;

        for (alts) |alt| {
            const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ alt, rel_path });
            defer allocator.free(candidate);

            std.Io.Dir.cwd().access(io, candidate, .{}) catch {
                // Loose path missing — try the sharded layout. The shard dirs
                // are named shard_NN. Enumerate them (generic, no need to know
                // the configured shard count) and probe each for rel_path.
                if (try self.resolveShard(allocator, io, alt, rel_path, &shard_buf)) |found| {
                    defer allocator.free(found); // free the probe result, hand out our own copy
                    return try allocator.dupe(u8, found);
                }
                continue;
            };
            return try allocator.dupe(u8, candidate);
        }
        return null;
    }

    /// Probe an alternate object dir for an object at a sharded path
    /// (shard_NN/XX/YYYY). Returns the first matching path or null.
    fn resolveShard(
        self: Alternates,
        allocator: std.mem.Allocator,
        io: std.Io,
        alt: []const u8,
        rel_path: []const u8,
        buf: *[256]u8,
    ) !?[]const u8 {
        _ = self;
        // List subdirectories of the alternate that match "shard_*".
        var dir = std.Io.Dir.cwd().openDir(io, alt, .{ .iterate = true }) catch return null;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const base = entry.name;
            if (base.len < 6 or !std.mem.eql(u8, base[0..6], "shard_")) continue;
            const shard_path = std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ alt, base, rel_path }) catch continue;
            std.Io.Dir.cwd().access(io, shard_path, .{}) catch continue;
            return try allocator.dupe(u8, shard_path);
        }
        return null;
    }

    /// Try to read an object through the alternates using a loose (git) layout
    /// at each alternate object directory. Returns error.ObjectNotFound if the
    /// object is unavailable anywhere.
    pub fn readObject(self: Alternates, allocator: std.mem.Allocator, io: std.Io, sha: [20]u8) !GitObject {
        const hex = Sha1.hex(sha);
        var rel_buf: [64]u8 = undefined;
        const rel_path = try std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ hex[0..2], hex[2..40] });

        const resolved = (try self.resolve(allocator, io, rel_path)) orelse return error.ObjectNotFound;
        defer allocator.free(resolved);
        return parseLooseFile(allocator, io, resolved);
    }
};

/// Parse a loose (zlib-compressed, "type size\0content") object file.
fn parseLooseFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !GitObject {
    // Dynamic read — supports arbitrarily large blobs (not capped at 100KB).
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return error.ObjectNotFound;
    defer allocator.free(raw);

    const decompressed = zlib_mod.zlib.decompress(allocator, raw) catch raw;
    defer if (decompressed.ptr != raw.ptr) allocator.free(decompressed);

    const null_pos = std.mem.indexOfScalar(u8, decompressed, 0) orelse return error.InvalidObject;
    const header = decompressed[0..null_pos];
    const content = decompressed[null_pos + 1 ..];

    var header_parts = std.mem.splitScalar(u8, header, ' ');
    const type_str = header_parts.next() orelse return error.InvalidObject;
    _ = header_parts.next() orelse return error.InvalidObject;

    const obj_type = try ObjectType.fromString(type_str);
    return switch (obj_type) {
        .blob => GitObject{ .blob = .{ .content = try allocator.dupe(u8, content) } },
        .tree => try object.deserialize(allocator, .tree, content),
        .commit => try object.deserialize(allocator, .commit, content),
        .tag => try object.deserialize(allocator, .tag, content),
    };
}
// ============================================================================
// Tests (TDD)
// ============================================================================

test "alternates write/read roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/gitz-test-alternates-rw";
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const alts = Alternates.init(tmp_dir);
    const paths = [_][]const u8{ "/repo/a/objects", "/repo/b/objects" };
    try alts.write(allocator, io, &paths);

    const read_back = try alts.read(allocator, io);
    defer {
        for (read_back) |s| allocator.free(s);
        allocator.free(read_back);
    }
    try std.testing.expectEqual(@as(usize, 2), read_back.len);
    try std.testing.expectEqualStrings("/repo/a/objects", read_back[0]);
    try std.testing.expectEqualStrings("/repo/b/objects", read_back[1]);
}

test "alternates read objects through a shared source store" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const source_dir = "/tmp/gitz-test-alternates-src";
    std.Io.Dir.cwd().createDirPath(io, source_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, source_dir) catch {};

    // Write a blob into the source repo's loose object store
    const source_store = loose_mod.LooseStore.init(source_dir);
    const payload = "shared blob content\n";
    const obj = GitObject{ .blob = .{ .content = payload } };
    const sha = try source_store.write(allocator, io, obj);

    // Clone repo has NO objects locally, only an alternates pointer
    const clone_dir = "/tmp/gitz-test-alternates-clone";
    std.Io.Dir.cwd().createDirPath(io, clone_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, clone_dir) catch {};

    const alts = Alternates.init(clone_dir);
    const source_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{source_dir});
    defer allocator.free(source_objects);
    try alts.write(allocator, io, &.{source_objects});

    // The clone's local store does NOT have the object
    const clone_store = loose_mod.LooseStore.init(clone_dir);
    try std.testing.expect(!clone_store.exists(io, sha));

    // But we can read it through alternates
    const read_obj = try alts.readObject(allocator, io, sha);
    defer allocator.free(read_obj.blob.content);
    try std.testing.expectEqualStrings(payload, read_obj.blob.content);

    // resolve() should report the physical location in the source
    const hex = Sha1.hex(sha);
    var rel_buf: [64]u8 = undefined;
    const rel_path = try std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ hex[0..2], hex[2..40] });
    const resolved = (try alts.resolve(allocator, io, rel_path)) orelse return error.TestUnexpectedResult;
    defer allocator.free(resolved);
    try std.testing.expect(std.mem.startsWith(u8, resolved, source_objects));
}

test "alternates missing object returns ObjectNotFound" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const clone_dir = "/tmp/gitz-test-alternates-missing";
    std.Io.Dir.cwd().createDirPath(io, clone_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, clone_dir) catch {};

    const alts = Alternates.init(clone_dir);
    // No alternates file at all
    try std.testing.expectError(error.ObjectNotFound, alts.readObject(allocator, io, [_]u8{0x11} ** 20));
}

test "alternates multiple sources ordered lookup" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const src_a = "/tmp/gitz-test-alternates-srca";
    const src_b = "/tmp/gitz-test-alternates-srcb";
    const clone_dir = "/tmp/gitz-test-alternates-clone2";
    std.Io.Dir.cwd().createDirPath(io, src_a) catch {};
    std.Io.Dir.cwd().createDirPath(io, src_b) catch {};
    std.Io.Dir.cwd().createDirPath(io, clone_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, src_a) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, src_b) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, clone_dir) catch {};

    // Object "shared here" lives only in src_a
    const store_a = loose_mod.LooseStore.init(src_a);
    const payload = "in alpha only\n";
    const obj = GitObject{ .blob = .{ .content = payload } };
    const sha = try store_a.write(allocator, io, obj);

    // clone points at both source object dirs
    const alts = Alternates.init(clone_dir);
    const obj_a = try std.fmt.allocPrint(allocator, "{s}/objects", .{src_a});
    defer allocator.free(obj_a);
    const obj_b = try std.fmt.allocPrint(allocator, "{s}/objects", .{src_b});
    defer allocator.free(obj_b);
    try alts.write(allocator, io, &.{ obj_a, obj_b });

    const read_obj = try alts.readObject(allocator, io, sha);
    defer allocator.free(read_obj.blob.content);
    try std.testing.expectEqualStrings(payload, read_obj.blob.content);
}

// ============================================================================
// SDD/TDD — large object support (objects larger than the old 100KB stack cap)
// ============================================================================

test "alternates read large blob (> 100KB) without truncation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const source_dir = "/tmp/gitz-test-alternates-large";
    std.Io.Dir.cwd().createDirPath(io, source_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, source_dir) catch {};

    // Build a ~400KB blob of LOW-entropy content so the zlib-compressed file
    // on disk stays small and the OLD 100KB buffer happened to read it fine.
    // To actually exceed the old fixed 100KB read buffer we need the
    // *compressed* size to exceed 100KB, which requires incompressible data.
    // Use a deterministic PRNG so the test stays reproducible.
    var rng_state: u64 = 0x9E3779B97F4A7C15;
    const large = try allocator.alloc(u8, 400 * 1024);
    defer allocator.free(large);
    for (large) |*b| {
        // xorshift64*
        rng_state ^= rng_state >> 12;
        rng_state ^= rng_state << 25;
        rng_state ^= rng_state >> 27;
        b.* = @truncate(rng_state *% 0x2545F4914F6CDD1D);
    }

    const store = loose_mod.LooseStore.init(source_dir);
    const obj = GitObject{ .blob = .{ .content = large } };
    const sha = try store.write(allocator, io, obj);

    const clone_dir = "/tmp/gitz-test-alternates-large-clone";
    std.Io.Dir.cwd().createDirPath(io, clone_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, clone_dir) catch {};

    const alts = Alternates.init(clone_dir);
    const source_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{source_dir});
    defer allocator.free(source_objects);
    try alts.write(allocator, io, &.{source_objects});

    const read_obj = try alts.readObject(allocator, io, sha);
    defer allocator.free(read_obj.blob.content);
    // Content must be byte-for-byte identical — no truncation.
    try std.testing.expectEqual(@as(usize, 400 * 1024), read_obj.blob.content.len);
    try std.testing.expectEqualSlices(u8, large, read_obj.blob.content);
}

// ============================================================================
// SDD/TDD — shard-aware alternates resolution
// ============================================================================

test "alternates resolve object from a sharded source store" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const source_dir = "/tmp/gitz-test-alternates-shardsrc";
    std.Io.Dir.cwd().createDirPath(io, source_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, source_dir) catch {};

    // Use the shard backend as the source (git_dir == source_dir).
    const shard = shard_mod.ShardStore.init(source_dir, 16);
    const payload = "shared blob from a sharded source\n";
    const obj = GitObject{ .blob = .{ .content = payload } };
    const sha = try shard.write(allocator, io, obj);

    // Clone points at the source *object* dir, which is sharded.
    const clone_dir = "/tmp/gitz-test-alternates-shardclone";
    std.Io.Dir.cwd().createDirPath(io, clone_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, clone_dir) catch {};

    const alts = Alternates.init(clone_dir);
    const source_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{source_dir});
    defer allocator.free(source_objects);
    try alts.write(allocator, io, &.{source_objects});

    // Loose-layout rel path (XX/YYYY) does NOT exist — shards live at
    // shard_NN/XX/YYYY. The shard-aware fallback must still find it.
    const read_obj = try alts.readObject(allocator, io, sha);
    defer allocator.free(read_obj.blob.content);
    try std.testing.expectEqualStrings(payload, read_obj.blob.content);
}
