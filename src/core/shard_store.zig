const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const object = @import("object.zig");
const zlib_mod = @import("zlib.zig");

const GitObject = object.GitObject;
const ObjectType = object.ObjectType;

/// Sharded object store — distributes git objects across N directories (shards).
///
/// Each object's SHA-1 determines which shard it lives on:
///   shard_index = first_byte(sha) % num_shards
///
/// This provides:
///   - Horizontal I/O scaling: each shard can be on a different physical volume
///   - No central index: the SHA itself encodes the location
///   - Balanced distribution: SHA-1 bytes are uniformly distributed
///   - Git compatibility: objects are still individual zlib-compressed files
///     with standard "type size\0content" format, just at a different path
///
/// The wire protocol is unaffected: when a packfile arrives from the network,
/// objects are unpacked and written to the appropriate shard. When a packfile
/// needs to be sent, objects are collected from their shards and packed.
pub const ShardStore = struct {
    git_dir: []const u8,
    num_shards: u8,

    pub fn init(git_dir: []const u8, num_shards: u8) ShardStore {
        return .{
            .git_dir = git_dir,
            .num_shards = if (num_shards == 0) 16 else num_shards,
        };
    }

    /// Determine which shard an object belongs to.
    /// Uses the first byte of the SHA-1 for uniform distribution.
    fn shardIndex(self: ShardStore, sha: [20]u8) u8 {
        return sha[0] % self.num_shards;
    }

    /// Build the directory path for a given shard: git_dir/objects/shard_NN/
    fn shardDirPath(self: ShardStore, allocator: std.mem.Allocator, shard_idx: u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/objects/shard_{x:0>2}", .{ self.git_dir, shard_idx });
    }

    /// Build the file path for an object within its shard.
    /// Layout: git_dir/objects/shard_NN/XX/YYYY...YYYY
    fn objectPath(self: ShardStore, sha: [20]u8, buf: *[128]u8) ![]u8 {
        const hex = Sha1.hex(sha);
        const shard_idx = self.shardIndex(sha);
        return std.fmt.bufPrint(buf, "{s}/objects/shard_{x:0>2}/{s}/{s}", .{
            self.git_dir,
            shard_idx,
            hex[0..2],
            hex[2..40],
        });
    }

    /// Build the full path for an object, allocating if needed.
    fn allocObjectPath(self: ShardStore, allocator: std.mem.Allocator, sha: [20]u8) ![]u8 {
        const hex = Sha1.hex(sha);
        const shard_idx = self.shardIndex(sha);
        return std.fmt.allocPrint(allocator, "{s}/objects/shard_{x:0>2}/{s}/{s}", .{
            self.git_dir,
            shard_idx,
            hex[0..2],
            hex[2..40],
        });
    }

    pub fn read(self: ShardStore, allocator: std.mem.Allocator, io: std.Io, sha: [20]u8) !GitObject {
        const full_path = try self.allocObjectPath(allocator, sha);
        defer allocator.free(full_path);

        var f = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch return error.ObjectNotFound;
        defer f.close(io);

        var buf: [100 * 1024]u8 = undefined;
        const n = try f.readStreaming(io, &.{&buf});
        const raw = buf[0..n];

        // Try to decompress (git objects are zlib-compressed)
        const decompressed = zlib_mod.zlib.decompress(allocator, raw) catch raw;
        defer if (decompressed.ptr != raw.ptr) allocator.free(decompressed);

        // Parse header: "type size\0content"
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

    pub fn write(self: ShardStore, allocator: std.mem.Allocator, io: std.Io, obj: GitObject) ![20]u8 {
        const sha = try obj.hash(allocator);
        const serialized = try obj.serialize(allocator);
        defer allocator.free(serialized);

        try self.writeRaw(allocator, io, obj.typeEnum(), serialized);
        return sha;
    }

    pub fn writeRaw(self: ShardStore, allocator: std.mem.Allocator, io: std.Io, obj_type: ObjectType, data: []const u8) !void {
        _ = obj_type;

        const sha = Sha1.hash(data);
        const hex = Sha1.hex(sha);
        const shard_idx = self.shardIndex(sha);

        // Create shard directory: git_dir/objects/shard_NN/
        const shard_dir = try std.fmt.allocPrint(allocator, "{s}/objects/shard_{x:0>2}", .{ self.git_dir, shard_idx });
        defer allocator.free(shard_dir);
        try std.Io.Dir.cwd().createDirPath(io, shard_dir);

        // Create sub-directory: git_dir/objects/shard_NN/XX/
        const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ shard_dir, hex[0..2] });
        defer allocator.free(sub_path);
        try std.Io.Dir.cwd().createDirPath(io, sub_path);

        // Write the object file: git_dir/objects/shard_NN/XX/YYYY...YYYY
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sub_path, hex[2..40] });
        defer allocator.free(file_path);

        var f = try std.Io.Dir.cwd().createFile(io, file_path, .{});
        defer f.close(io);

        // Compress with zlib (git-compatible)
        const compressed = zlib_mod.zlib.compress(allocator, data) catch {
            try std.Io.File.writeStreamingAll(f, io, data);
            return;
        };
        defer allocator.free(compressed);
        try std.Io.File.writeStreamingAll(f, io, compressed);
    }

    pub fn exists(self: ShardStore, io: std.Io, sha: [20]u8) bool {
        var path_buf: [128]u8 = undefined;
        const full_path = self.objectPath(sha, &path_buf) catch return false;
        std.Io.Dir.cwd().access(io, full_path, .{}) catch return false;
        return true;
    }

    pub fn delete(self: ShardStore, allocator: std.mem.Allocator, io: std.Io, sha: [20]u8) !void {
        const full_path = try self.allocObjectPath(allocator, sha);
        defer allocator.free(full_path);
        std.Io.Dir.cwd().deleteFile(io, full_path) catch {};
    }
};

// ============================================================================
// Tests
// ============================================================================

test "shard store write/read blob roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/gitz-test-shard";
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const store = ShardStore.init(tmp_dir, 4);

    const blob_data = "Hello from shard store!\n";
    const obj = GitObject{ .blob = .{ .content = blob_data } };
    const sha = try store.write(allocator, io, obj);

    // Verify object exists
    try std.testing.expect(store.exists(io, sha));

    // Read it back
    const read_obj = try store.read(allocator, io, sha);
    try std.testing.expectEqualStrings(blob_data, read_obj.blob.content);
    allocator.free(read_obj.blob.content);

    // Delete it
    try store.delete(allocator, io, sha);
    try std.testing.expect(!store.exists(io, sha));
}

test "shard store distribution — objects go to different shards" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/gitz-test-shard-distrib";
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const store = ShardStore.init(tmp_dir, 16);

    // Write several objects with different content (different SHAs)
    const contents = [_][]const u8{
        "object one",
        "object two",
        "object three",
        "object four",
        "object five",
    };

    var shas: [5][20]u8 = undefined;
    for (contents, 0..) |content, i| {
        const obj = GitObject{ .blob = .{ .content = content } };
        shas[i] = try store.write(allocator, io, obj);
    }

    // Verify they exist
    for (shas) |sha| {
        try std.testing.expect(store.exists(io, sha));
    }

    // Verify at least 2 different shards were used
    var shard_set = std.AutoHashMap(u8, void).init(allocator);
    defer shard_set.deinit();
    for (shas) |sha| {
        const idx = sha[0] % 16;
        try shard_set.put(idx, {});
    }
    try std.testing.expect(shard_set.count() >= 2);

    // Cleanup
    for (shas) |sha| {
        try store.delete(allocator, io, sha);
    }
}

test "shard store handles multiple shards" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/gitz-test-shard-multi";
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    // Test with 8 shards
    const store = ShardStore.init(tmp_dir, 8);

    // Write 20 objects
    for (0..20) |i| {
        var buf: [64]u8 = undefined;
        const content = try std.fmt.bufPrint(&buf, "content for object {d}", .{i});
        const obj = GitObject{ .blob = .{ .content = content } };
        _ = try store.write(allocator, io, obj);
    }

    // Verify shard directories exist
    var shards_found: u8 = 0;
    for (0..8) |s| {
        var path_buf: [128]u8 = undefined;
        const shard_path = try std.fmt.bufPrint(&path_buf, "{s}/objects/shard_{x:0>2}", .{ tmp_dir, s });
        if (std.Io.Dir.cwd().access(io, shard_path, .{})) |_| {
            shards_found += 1;
        } else |_| {}
    }
    // At least some shards should exist
    try std.testing.expect(shards_found > 0);
}

test "shard store writeRaw produces correct SHA" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/gitz-test-shard-raw";
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const store = ShardStore.init(tmp_dir, 4);

    // Build object data: "blob 5\0hello"
    const obj_data = "blob 5\x00hello";
    try store.writeRaw(allocator, io, .blob, obj_data);

    // Verify the SHA matches what loose store would produce
    const expected_sha = Sha1.hash(obj_data);
    try std.testing.expect(store.exists(io, expected_sha));

    // Read back and verify
    const read_obj = try store.read(allocator, io, expected_sha);
    try std.testing.expectEqualStrings("hello", read_obj.blob.content);
    allocator.free(read_obj.blob.content);

    try store.delete(allocator, io, expected_sha);
}
