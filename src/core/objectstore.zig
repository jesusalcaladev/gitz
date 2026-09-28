const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const storage = @import("storage.zig");
const packfile_mod = @import("packfile.zig");
const object_mod = @import("object.zig");
const config_mod = @import("config.zig");
const Fs = @import("../util/fs.zig").Fs;

const GitObject = object_mod.GitObject;
const ObjectType = object_mod.ObjectType;
const StorageBackend = storage.StorageBackend;

/// Unified object store with pluggable storage backend.
///
/// This is the single entry point for all object I/O. The actual storage
/// mechanism (loose files, sharded directories, KV store, DHT) is decided
/// by the StorageBackend, which is selected from config at init time.
///
/// The wire protocol (packfiles) is handled at the transport layer —
/// objects arrive as packed data, get unpacked here, and are stored
/// individually through the backend. When objects need to go out, they
/// are read from the backend and packed on the fly.
///
/// This separation is what allows GitZ to scale: the storage backend can
/// be distributed across shards, volumes, or nodes without the rest of
/// the system knowing or caring.
pub const ObjectStore = struct {
    git_dir: []const u8,
    backend: StorageBackend,

    /// Initialize with default (loose) backend.
    pub fn init(git_dir: []const u8) ObjectStore {
        return .{
            .git_dir = git_dir,
            .backend = StorageBackend.looseBackend(git_dir),
        };
    }

    /// Initialize with a specific backend.
    pub fn initWithBackend(git_dir: []const u8, backend: StorageBackend) ObjectStore {
        return .{
            .git_dir = git_dir,
            .backend = backend,
        };
    }

    /// Initialize from repo config — reads [storage] backend = "loose"|"shard".
    pub fn initFromConfig(allocator: std.mem.Allocator, io: std.Io, git_dir: []const u8) ObjectStore {
        // Read config file
        const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_dir}) catch {
            return ObjectStore.init(git_dir);
        };
        defer allocator.free(config_path);

        const config_file = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .unlimited) catch {
            return ObjectStore.init(git_dir);
        };
        defer allocator.free(config_file);

        var config = config_mod.Config.init(allocator);
        defer config.deinit();
        config.parse(config_file) catch {
            return ObjectStore.init(git_dir);
        };

        const backend_str = config.get("storage", "backend");
        const num_shards_str = config.get("storage", "shards");

        if (backend_str) |bs| {
            if (std.mem.eql(u8, bs, "shard")) {
                const num_shards: u8 = if (num_shards_str) |ns|
                    std.fmt.parseInt(u8, ns, 10) catch 16
                else
                    16;
                return ObjectStore.initWithBackend(git_dir, StorageBackend.shardBackend(git_dir, num_shards));
            }
        }

        return ObjectStore.init(git_dir);
    }

    pub fn deinit(_: *ObjectStore, _: std.mem.Allocator) void {}

    pub fn read(self: *ObjectStore, allocator: std.mem.Allocator, io: std.Io, sha: [20]u8) !GitObject {
        return self.backend.read(allocator, io, sha);
    }

    pub fn write(self: *ObjectStore, allocator: std.mem.Allocator, io: std.Io, obj: GitObject) ![20]u8 {
        return self.backend.write(allocator, io, obj);
    }

    pub fn writeRaw(self: *ObjectStore, allocator: std.mem.Allocator, io: std.Io, obj_type: ObjectType, data: []const u8) !void {
        return self.backend.writeRaw(allocator, io, obj_type, data);
    }

    pub fn exists(self: *ObjectStore, io: std.Io, sha: [20]u8) bool {
        return self.backend.exists(io, sha);
    }

    /// Returns the backend type as a string for diagnostics.
    pub fn backendName(self: ObjectStore) []const u8 {
        return switch (self.backend) {
            .loose => "loose",
            .shard => "shard",
        };
    }

    /// Pack loose objects into a DAG-aware packfile.
    ///
    /// DISABLED — this used to destroy every repository it touched. It wrote a
    /// `.pack` under `objects/pack/` with no `.idx`, then deleted the loose
    /// objects it had copied. Nothing in the tree can read a packfile back, so
    /// after `gitz gc` the object store looked empty: `log`, `status` and
    /// `checkout` found no objects, and even real `git` reported
    /// `fatal: bad object HEAD`.
    ///
    /// It is kept as a no-op, with its old name, so callers keep compiling.
    /// Re-enable only together with a pack reader plus a `.idx` writer, and
    /// only once the loose objects are verified to be recoverable from the
    /// pack before they are removed. `cli/commands/gc.zig` also refuses to
    /// prune when packfiles are present.
    pub fn gc(self: *ObjectStore, allocator: std.mem.Allocator, io: std.Io) !u32 {
        _ = self;
        _ = allocator;
        _ = io;
        return 0;
    }

    fn gcDisabled(self: *ObjectStore, allocator: std.mem.Allocator, io: std.Io) !u32 {
        _ = self;
        _ = allocator;
        _ = io;
        return 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "object store with loose backend — read/write roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/gitz-test-objstore-loose";
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    var store = ObjectStore.init(tmp_dir);
    try std.testing.expectEqualStrings("loose", store.backendName());

    const blob_data = "Hello from ObjectStore!\n";
    const obj = GitObject{ .blob = .{ .content = blob_data } };
    const sha = try store.write(allocator, io, obj);

    try std.testing.expect(store.exists(io, sha));

    const read_obj = try store.read(allocator, io, sha);
    try std.testing.expectEqualStrings(blob_data, read_obj.blob.content);
    allocator.free(read_obj.blob.content);
}

test "object store with shard backend — read/write roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/gitz-test-objstore-shard";
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    var store = ObjectStore.initWithBackend(
        tmp_dir,
        StorageBackend.shardBackend(tmp_dir, 4),
    );
    try std.testing.expectEqualStrings("shard", store.backendName());

    const blob_data = "Hello from sharded ObjectStore!\n";
    const obj = GitObject{ .blob = .{ .content = blob_data } };
    const sha = try store.write(allocator, io, obj);

    try std.testing.expect(store.exists(io, sha));

    const read_obj = try store.read(allocator, io, sha);
    try std.testing.expectEqualStrings(blob_data, read_obj.blob.content);
    allocator.free(read_obj.blob.content);
}

test "object store writeRaw produces correct SHA" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/gitz-test-objstore-raw";
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    var store = ObjectStore.init(tmp_dir);

    const obj_data = "blob 5\x00hello";
    try store.writeRaw(allocator, io, .blob, obj_data);

    const expected_sha = Sha1.hash(obj_data);
    try std.testing.expect(store.exists(io, expected_sha));

    const read_obj = try store.read(allocator, io, expected_sha);
    try std.testing.expectEqualStrings("hello", read_obj.blob.content);
    allocator.free(read_obj.blob.content);
}
