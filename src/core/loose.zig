const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const object = @import("object.zig");
const zlib_mod = @import("zlib.zig");

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
        var path_buf: [52]u8 = undefined;
        objectPath(sha, &path_buf);

        const path_len = std.mem.indexOfScalar(u8, &path_buf, 0) orelse 41;
        const full_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ self.git_dir, path_buf[0..path_len] });
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

    pub fn write(self: LooseStore, allocator: std.mem.Allocator, io: std.Io, obj: GitObject) ![20]u8 {
        const sha = try obj.hash(allocator);
        const serialized = try obj.serialize(allocator);
        defer allocator.free(serialized);

        try self.writeRaw(allocator, io, obj.typeEnum(), serialized);
        return sha;
    }

    pub fn writeRaw(self: LooseStore, allocator: std.mem.Allocator, io: std.Io, obj_type: ObjectType, data: []const u8) !void {
        _ = obj_type;

        const objects_dir = try std.fmt.allocPrint(allocator, "{s}/objects", .{self.git_dir});
        defer allocator.free(objects_dir);
        try std.Io.Dir.cwd().createDirPath(io, objects_dir);

        const sha = Sha1.hash(data);
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
