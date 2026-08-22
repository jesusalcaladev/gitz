const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const storage = @import("storage.zig");
const packfile_mod = @import("packfile.zig");
const object_mod = @import("object.zig");
const config_mod = @import("config.zig");

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
    pub fn gc(self: *ObjectStore, allocator: std.mem.Allocator, io: std.Io) !u32 {
        // GC only makes sense for loose backend — sharded objects
        // are managed by the shard store itself.
        if (self.backend != .loose) return 0;

        var all_shas: std.ArrayList([20]u8) = .empty;

        const objects_dir = try std.fmt.allocPrint(allocator, "{s}/objects", .{self.git_dir});
        defer allocator.free(objects_dir);

        var base_dir = std.Io.Dir.cwd().openDir(io, objects_dir, .{}) catch return 0;
        defer base_dir.close(io);

        var dir_iter = base_dir.iterate();
        while (dir_iter.next(io) catch null) |entry| {
            if (entry.name.len != 2) continue;
            const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir, entry.name });
            defer allocator.free(sub_path);
            var sub_dir = std.Io.Dir.cwd().openDir(io, sub_path, .{}) catch continue;
            defer sub_dir.close(io);
            var file_iter = sub_dir.iterate();
            while (file_iter.next(io) catch null) |file_entry| {
                if (file_entry.name.len != 38) continue;
                var full_hex: [40]u8 = undefined;
                @memcpy(full_hex[0..2], entry.name);
                @memcpy(full_hex[2..40], file_entry.name);
                const sha = Sha1.fromHex(&full_hex) catch continue;
                try all_shas.append(allocator, sha);
            }
        }
        defer all_shas.deinit(allocator);

        if (all_shas.items.len == 0) return 0;

        // Build dependency graph
        var objects_with_deps: std.ArrayList(packfile_mod.ObjectWithDeps) = .empty;
        defer {
            for (objects_with_deps.items) |*obj| allocator.free(obj.dep_shas);
            objects_with_deps.deinit(allocator);
        }

        for (all_shas.items) |sha| {
            const obj = self.backend.read(allocator, io, sha) catch continue;
            var deps: std.ArrayList([20]u8) = .empty;
            switch (obj) {
                .commit => |c| {
                    try deps.append(allocator, c.tree);
                    for (c.parents) |parent| try deps.append(allocator, parent);
                },
                .tree => |t| {
                    for (t.entries) |entry| try deps.append(allocator, entry.sha);
                },
                else => {},
            }
            const dep_slice = try deps.toOwnedSlice(allocator);
            const ot: ObjectType = switch (obj) {
                .blob => .blob,
                .tree => .tree,
                .commit => .commit,
                .tag => .tag,
            };
            try objects_with_deps.append(allocator, .{
                .sha = sha,
                .obj_type = packfile_mod.fromObjType(ot),
                .data = "",
                .dep_shas = dep_slice,
            });
        }

        // Topological sort
        const sorted = try packfile_mod.topologicalSort(allocator, objects_with_deps.items);
        defer allocator.free(sorted);

        // Write packfile
        var pw = packfile_mod.PackWriter.init(allocator);
        defer pw.deinit();
        try pw.writeHeader(2, @intCast(sorted.len));

        for (sorted) |obj| {
            const full_obj = self.backend.read(allocator, io, obj.sha) catch continue;
            const serialized = try full_obj.serialize(allocator);
            defer allocator.free(serialized);
            const null_pos = std.mem.indexOfScalar(u8, serialized, 0) orelse 0;
            try pw.writeObject(obj.obj_type, obj.sha, serialized[null_pos + 1 ..]);
        }
        try pw.finalize();

        // Write pack to disk
        const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{self.git_dir});
        defer allocator.free(pack_dir);
        std.Io.Dir.cwd().createDirPath(io, pack_dir) catch {};
        const hex_bytes = Sha1.hex(sorted[0].sha);
        const pack_name = try std.fmt.allocPrint(allocator, "{s}/pack-{s}.pack", .{ pack_dir, hex_bytes[0..8] });
        defer allocator.free(pack_name);
        var pack_file = std.Io.Dir.cwd().createFile(io, pack_name, .{}) catch return 0;
        defer pack_file.close(io);
        try std.Io.File.writeStreamingAll(pack_file, io, pw.getPackData());

        // Remove loose objects
        for (sorted) |obj| {
            self.backend.delete(allocator, io, obj.sha) catch {};
        }

        return @intCast(sorted.len);
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
