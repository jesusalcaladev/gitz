const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const object = @import("object.zig");
const zlib_mod = @import("zlib.zig");
const alternates_mod = @import("alternates.zig");

const GitObject = object.GitObject;
const ObjectType = object.ObjectType;

pub const LooseStore = struct {
    git_dir: []const u8,

    pub fn init(git_dir: []const u8) LooseStore {
        return .{ .git_dir = git_dir };
    }

    fn objectPath(sha: [20]u8, buf: *[52]u8) void {
        const hex = Sha1.hex(sha);
        // Format: "XX/YYYY...YYYY\0"
        // 2 hex chars + '/' + 38 hex chars + null = 42 bytes used + null at 42
        buf[0] = hex[0];
        buf[1] = hex[1];
        buf[2] = '/';
        // Copy remaining 38 hex chars (skip first 2)
        @memcpy(buf[3..41], hex[2..40]);
        buf[41] = 0;
    }

    pub fn read(self: LooseStore, allocator: std.mem.Allocator, io: std.Io, sha: [20]u8) !GitObject {
        const own = self.readOwn(allocator, io, sha) catch |e| switch (e) {
            error.ObjectNotFound => return self.readAlternate(allocator, io, sha),
            else => return e,
        };
        return own;
    }

    /// Read from the repository's own object store only.
    fn readOwn(self: LooseStore, allocator: std.mem.Allocator, io: std.Io, sha: [20]u8) !GitObject {
        var path_buf: [52]u8 = undefined;
        objectPath(sha, &path_buf);

        const path_len = std.mem.indexOfScalar(u8, &path_buf, 0) orelse 41;
        const full_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ self.git_dir, path_buf[0..path_len] });
        defer allocator.free(full_path);

        // Read the entire (zlib-compressed) object file. Using a dynamic read
        // (instead of a fixed stack buffer) means arbitrarily large objects —
        // blobs are NOT capped at a few hundred KB in git — are supported.
        const raw = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .unlimited) catch return error.ObjectNotFound;
        defer allocator.free(raw);

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

    /// Fall back to the object stores listed in `objects/info/alternates`.
    ///
    /// This is what makes `gitz clone --shared` usable: the clone's own object
    /// directory is empty and every object lives in the source repository, so
    /// without this, every command (status, log, diff, merge) sees a shared
    /// clone as a repository with no objects at all.
    ///
    /// Only reached after a miss, and gated on the alternates file existing, so
    /// the cost for an ordinary repository is a single failed lookup that was
    /// already happening.
    fn readAlternate(self: LooseStore, allocator: std.mem.Allocator, io: std.Io, sha: [20]u8) !GitObject {
        const path = try std.fmt.allocPrint(allocator, "{s}/objects/info/alternates", .{self.git_dir});
        defer allocator.free(path);
        std.Io.Dir.cwd().access(io, path, .{}) catch return error.ObjectNotFound;

        const alts = alternates_mod.Alternates.init(self.git_dir);
        return alts.readObject(allocator, io, sha);
    }

    pub fn write(self: LooseStore, allocator: std.mem.Allocator, io: std.Io, obj: GitObject) ![20]u8 {
        // Serialize once and hash the same buffer. The old path serialized the
        // object twice (once in hash() and once for storage), doubling the
        // allocation/copy cost for every write.
        const serialized = try obj.serialize(allocator);
        defer allocator.free(serialized);
        const sha = Sha1.hash(serialized);
        try self.writeSerialized(allocator, io, sha, serialized);
        return sha;
    }

    pub fn writeRaw(self: LooseStore, allocator: std.mem.Allocator, io: std.Io, obj_type: ObjectType, data: []const u8) !void {
        _ = obj_type;
        try self.writeSerialized(allocator, io, Sha1.hash(data), data);
    }

    fn writeSerialized(self: LooseStore, allocator: std.mem.Allocator, io: std.Io, sha: [20]u8, data: []const u8) !void {
        const objects_dir = try std.fmt.allocPrint(allocator, "{s}/objects", .{self.git_dir});
        defer allocator.free(objects_dir);
        try std.Io.Dir.cwd().createDirPath(io, objects_dir);

        const hex = Sha1.hex(sha);

        const sub_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ self.git_dir, hex[0..2] });
        defer allocator.free(sub_path);
        try std.Io.Dir.cwd().createDirPath(io, sub_path);

        const file_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}/{s}", .{ self.git_dir, hex[0..2], hex[2..40] });
        defer allocator.free(file_path);

        var f = try std.Io.Dir.cwd().createFile(io, file_path, .{});
        defer f.close(io);

        // Compress with zlib (git-compatible)
        const compressed = zlib_mod.zlib.compress(allocator, data) catch {
            // Fallback to uncompressed if compression fails
            try std.Io.File.writeStreamingAll(f, io, data);
            return;
        };
        defer allocator.free(compressed);
        try std.Io.File.writeStreamingAll(f, io, compressed);
    }

    pub fn exists(self: LooseStore, io: std.Io, sha: [20]u8) bool {
        var path_buf: [52]u8 = undefined;
        objectPath(sha, &path_buf);
        const path_len = std.mem.indexOfScalar(u8, &path_buf, 0) orelse 41;
        const full_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/objects/{s}", .{ self.git_dir, path_buf[0..path_len] }) catch return false;
        defer std.heap.page_allocator.free(full_path);
        std.Io.Dir.cwd().access(io, full_path, .{}) catch return false;
        return true;
    }

    pub fn delete(self: LooseStore, allocator: std.mem.Allocator, io: std.Io, sha: [20]u8) !void {
        var path_buf: [52]u8 = undefined;
        objectPath(sha, &path_buf);
        const path_len = std.mem.indexOfScalar(u8, &path_buf, 0) orelse 41;
        const full_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ self.git_dir, path_buf[0..path_len] });
        defer allocator.free(full_path);
        std.Io.Dir.cwd().deleteFile(io, full_path) catch {};
    }
};

// ============================================================================
// SDD/TDD — large object support (blobs > 100KB must not be truncated)
// ============================================================================

test "loose store reads a large blob (> 100KB) without truncation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/gitz-test-loose-large";
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    var store = LooseStore.init(tmp_dir);

    // 300KB of incompressible (PRNG) content keeps the zlib file > 100KB so
    // the old fixed-buffer reader would have truncated it.
    var rng: u64 = 0x853c49e6748fea9b;
    const large = try allocator.alloc(u8, 300 * 1024);
    defer allocator.free(large);
    for (large) |*b| {
        rng ^= rng >> 13;
        rng ^= rng << 7;
        rng ^= rng >> 17;
        b.* = @truncate(rng *% 0x2545F4914F6CDD1D);
    }

    const obj = GitObject{ .blob = .{ .content = large } };
    const sha = try store.write(allocator, io, obj);

    const read_obj = try store.read(allocator, io, sha);
    defer allocator.free(read_obj.blob.content);
    try std.testing.expectEqual(@as(usize, 300 * 1024), read_obj.blob.content.len);
    try std.testing.expectEqualSlices(u8, large, read_obj.blob.content);
}
