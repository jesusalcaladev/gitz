const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const loose_mod = @import("loose.zig");
const packfile_mod = @import("packfile.zig");
const object_mod = @import("object.zig");

const GitObject = object_mod.GitObject;
const ObjectType = object_mod.ObjectType;
const LooseStore = loose_mod.LooseStore;

/// Unified object store that reads from loose objects and can pack them
/// into DAG-aware packfiles for cache-friendly sequential access.
pub const ObjectStore = struct {
    git_dir: []const u8,
    loose: LooseStore,

    pub fn init(git_dir: []const u8) ObjectStore {
        return .{
            .git_dir = git_dir,
            .loose = LooseStore.init(git_dir),
        };
    }

    pub fn deinit(_: *ObjectStore, _: std.mem.Allocator) void {}

    pub fn read(self: *ObjectStore, allocator: std.mem.Allocator, io: std.Io, sha: [20]u8) !GitObject {
        return self.loose.read(allocator, io, sha);
    }

    pub fn write(self: *ObjectStore, allocator: std.mem.Allocator, io: std.Io, obj: GitObject) ![20]u8 {
        return try self.loose.write(allocator, io, obj);
    }

    pub fn exists(self: *ObjectStore, io: std.Io, sha: [20]u8) bool {
        return self.loose.exists(io, sha);
    }

    /// Pack loose objects into a DAG-aware packfile.
    pub fn gc(self: *ObjectStore, allocator: std.mem.Allocator, io: std.Io) !u32 {
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
            const obj = self.loose.read(allocator, io, sha) catch continue;
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
            const full_obj = self.loose.read(allocator, io, obj.sha) catch continue;
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
            self.loose.delete(allocator, io, obj.sha) catch {};
        }

        return @intCast(sorted.len);
    }
};
