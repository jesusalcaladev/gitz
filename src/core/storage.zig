const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const object_mod = @import("object.zig");
const loose_mod = @import("loose.zig");
const shard_mod = @import("shard_store.zig");

const GitObject = object_mod.GitObject;
const ObjectType = object_mod.ObjectType;
const LooseStore = loose_mod.LooseStore;
const ShardStore = shard_mod.ShardStore;

/// Pluggable storage backend for git objects.
///
/// The storage layer is abstracted so the internal object store can be swapped
/// without affecting the wire protocol. Git clients always send/receive
/// packfiles over the network, but the server-side storage is free to use
/// whatever layout it wants — loose objects, sharded directories, a KV store,
/// or a distributed hash table.
///
/// This is the key architectural decision that allows GitZ to scale beyond
/// git's single-filesystem model: objects are stored individually and can be
/// distributed across shards, volumes, or nodes, while remaining 100%
/// compatible with the git wire protocol.
pub const StorageBackend = union(enum) {
    loose: LooseStore,
    shard: ShardStore,

    // -----------------------------------------------------------------------
    // Common API — all backends implement these
    // -----------------------------------------------------------------------

    pub fn read(self: StorageBackend, allocator: std.mem.Allocator, io: std.Io, sha: [20]u8) !GitObject {
        return switch (self) {
            .loose => |s| s.read(allocator, io, sha),
            .shard => |s| s.read(allocator, io, sha),
        };
    }

    pub fn write(self: StorageBackend, allocator: std.mem.Allocator, io: std.Io, obj: GitObject) ![20]u8 {
        return switch (self) {
            .loose => |s| s.write(allocator, io, obj),
            .shard => |s| s.write(allocator, io, obj),
        };
    }

    /// Write raw object data (already serialized as "type size\0content").
    /// The SHA is computed from the data, not passed in.
    pub fn writeRaw(self: StorageBackend, allocator: std.mem.Allocator, io: std.Io, obj_type: ObjectType, data: []const u8) !void {
        return switch (self) {
            .loose => |s| s.writeRaw(allocator, io, obj_type, data),
            .shard => |s| s.writeRaw(allocator, io, obj_type, data),
        };
    }

    pub fn exists(self: StorageBackend, io: std.Io, sha: [20]u8) bool {
        return switch (self) {
            .loose => |s| s.exists(io, sha),
            .shard => |s| s.exists(io, sha),
        };
    }

    pub fn delete(self: StorageBackend, allocator: std.mem.Allocator, io: std.Io, sha: [20]u8) !void {
        return switch (self) {
            .loose => |s| s.delete(allocator, io, sha),
            .shard => |s| s.delete(allocator, io, sha),
        };
    }

    // -----------------------------------------------------------------------
    // Constructors
    // -----------------------------------------------------------------------

    /// Default backend: loose objects on local filesystem (git-compatible).
    pub fn looseBackend(git_dir: []const u8) StorageBackend {
        return .{ .loose = LooseStore.init(git_dir) };
    }

    /// Sharded backend: distributes objects across N directories.
    /// Each shard can live on a different physical volume for horizontal I/O scaling.
    pub fn shardBackend(git_dir: []const u8, num_shards: u8) StorageBackend {
        return .{ .shard = ShardStore.init(git_dir, num_shards) };
    }

    /// Select backend from config string.
    /// Returns the default (loose) if the string is unrecognized.
    pub fn fromConfig(git_dir: []const u8, backend_str: ?[]const u8) StorageBackend {
        if (backend_str) |s| {
            if (std.mem.eql(u8, s, "shard")) {
                return shardBackend(git_dir, 16);
            }
        }
        return looseBackend(git_dir);
    }

    /// Read backend from repo config file.
    /// Falls back to loose if config is missing or unreadable.
    pub fn fromRepoConfig(allocator: std.mem.Allocator, io: std.Io, git_dir: []const u8) StorageBackend {
        const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_dir}) catch {
            return looseBackend(git_dir);
        };
        defer allocator.free(config_path);

        const content = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .unlimited) catch {
            return looseBackend(git_dir);
        };
        defer allocator.free(content);

        // Parse flat config format: "section.key = value"
        var backend_str: ?[]const u8 = null;
        var shards_str: ?[]const u8 = null;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Skip INI-style section headers
            if (trimmed[0] == '[') continue;

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const k = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const v = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");
                if (std.mem.eql(u8, k, "storage.backend")) {
                    backend_str = v;
                } else if (std.mem.eql(u8, k, "storage.shards")) {
                    shards_str = v;
                }
            }
        }

        if (backend_str) |bs| {
            if (std.mem.eql(u8, bs, "shard")) {
                const num_shards: u8 = if (shards_str) |ns|
                    std.fmt.parseInt(u8, ns, 10) catch 16
                else
                    16;
                return shardBackend(git_dir, num_shards);
            }
        }

        return looseBackend(git_dir);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "storage backend dispatch — loose read/write roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Create a temp dir for testing
    const tmp_dir = "/tmp/gitz-test-storage-loose";
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const git_dir = tmp_dir;

    const backend = StorageBackend.looseBackend(git_dir);

    // Write a blob
    const blob_data = "Hello from storage backend test!\n";
    const obj = GitObject{ .blob = .{ .content = blob_data } };
    const sha = try backend.write(allocator, io, obj);

    // Verify it exists
    try std.testing.expect(backend.exists(io, sha));

    // Read it back
    const read_obj = try backend.read(allocator, io, sha);
    try std.testing.expectEqualStrings(blob_data, read_obj.blob.content);
    allocator.free(read_obj.blob.content);

    // Delete it
    try backend.delete(allocator, io, sha);
    try std.testing.expect(!backend.exists(io, sha));
}

test "storage backend dispatch — shard read/write roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/gitz-test-storage-shard";
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const git_dir = tmp_dir;

    const backend = StorageBackend.shardBackend(git_dir, 4);

    const blob_data = "Hello from shard backend test!\n";
    const obj = GitObject{ .blob = .{ .content = blob_data } };
    const sha = try backend.write(allocator, io, obj);

    try std.testing.expect(backend.exists(io, sha));

    const read_obj = try backend.read(allocator, io, sha);
    try std.testing.expectEqualStrings(blob_data, read_obj.blob.content);
    allocator.free(read_obj.blob.content);

    try backend.delete(allocator, io, sha);
    try std.testing.expect(!backend.exists(io, sha));
}

test "storage backend fromConfig — defaults to loose" {
    const backend = StorageBackend.fromConfig("/tmp", null);
    try std.testing.expect(backend == .loose);
}

test "storage backend fromConfig — recognizes shard" {
    const backend = StorageBackend.fromConfig("/tmp", "shard");
    try std.testing.expect(backend == .shard);
}
