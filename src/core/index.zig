const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;

pub const StatInfo = struct {
    mode: u32 = 0o100644,
    size: u32 = 0,
    mtime: i64 = 0,
    ctime: i64 = 0,
    dev: u32 = 0,
    ino: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
};

pub const IndexEntry = struct {
    sha: [20]u8 = [_]u8{0} ** 20,
    mode: u32 = 0o100644,
    size: u32 = 0,
    flags: u16 = 0,
    mtime: i64 = 0,
    ctime: i64 = 0,
    dev: u32 = 0,
    ino: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    name: []const u8 = "",
};

/// Unmanaged ArrayList for use inside HashMaps
const EntryList = std.ArrayListUnmanaged(IndexEntry);

pub const Index = struct {
    entries: std.ArrayList(IndexEntry),

    pub fn init(_: std.mem.Allocator) Index {
        return .{ .entries = .empty };
    }

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            allocator.free(entry.name);
        }
        self.entries.deinit(allocator);
    }

    pub fn get(self: *const Index, name: []const u8) ?[20]u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.sha;
        }
        return null;
    }

    pub fn count(self: Index) usize {
        return self.entries.items.len;
    }

    pub fn add(self: *Index, allocator: std.mem.Allocator, path: []const u8, sha: [20]u8, stat: StatInfo) !void {
        // Normalize path: strip leading ./ and trailing /
        var clean = path;
        while (std.mem.startsWith(u8, clean, "./")) clean = clean[2..];
        while (clean.len > 0 and clean[clean.len - 1] == '/') clean = clean[0 .. clean.len - 1];
        if (clean.len == 0) return;

        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, clean)) {
                allocator.free(entry.name);
                self.entries.items[i].sha = sha;
                self.entries.items[i].size = stat.size;
                self.entries.items[i].mtime = stat.mtime;
                self.entries.items[i].ctime = stat.ctime;
                self.entries.items[i].name = try allocator.dupe(u8, clean);
                return;
            }
        }
        const owned_name = try allocator.dupe(u8, clean);
        try self.entries.append(allocator, .{ .sha = sha, .size = stat.size, .mtime = stat.mtime, .ctime = stat.ctime, .mode = stat.mode, .name = owned_name });
    }

    /// Build hierarchical git tree from flat index entries.
    pub fn writeTree(self: *Index, store: anytype, allocator: std.mem.Allocator, io: std.Io) ![20]u8 {
        const object = @import("object.zig");

        var files: std.ArrayList(object.TreeEntry) = .empty;
        defer files.deinit(allocator);

        var dir_map = std.StringHashMap(EntryList).init(allocator);
        defer {
            var iter = dir_map.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(allocator);
                allocator.free(entry.key_ptr.*);
            }
            dir_map.deinit();
        }

        for (self.entries.items) |entry| {
            var clean = if (std.mem.startsWith(u8, entry.name, "./"))
                entry.name[2..]
            else
                entry.name;

            if (std.mem.indexOf(u8, clean, "/")) |slash_pos| {
                const dir_name = clean[0..slash_pos];
                const gop = try dir_map.getOrPut(try allocator.dupe(u8, dir_name));
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                }
                try gop.value_ptr.append(allocator, .{
                    .sha = entry.sha,
                    .mode = entry.mode,
                    .size = entry.size,
                    .name = try allocator.dupe(u8, clean[slash_pos + 1 ..]),
                    .mtime = entry.mtime,
                    .ctime = entry.ctime,
                    .dev = entry.dev,
                    .ino = entry.ino,
                    .uid = entry.uid,
                    .gid = entry.gid,
                    .flags = entry.flags,
                });
            } else {
                try files.append(allocator, .{
                    .mode = entry.mode,
                    .name = clean,
                    .sha = entry.sha,
                });
            }
        }

        // Build sub-trees for each directory
        var dir_iter = dir_map.iterator();
        while (dir_iter.next()) |dir_entry| {
            const sub_tree_sha = try buildSubTree(store, allocator, io, dir_entry.value_ptr.items);
            try files.append(allocator, .{
                .mode = 0o040000,
                .name = dir_entry.key_ptr.*,
                .sha = sub_tree_sha,
            });
        }

        // Sort by name
        std.sort.insertion(object.TreeEntry, files.items, {}, struct {
            fn lessThan(_: void, a: object.TreeEntry, b: object.TreeEntry) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);

        const tree = object.Tree{ .entries = try files.toOwnedSlice(allocator) };
        return try store.write(allocator, io, object.GitObject{ .tree = tree });
    }

    pub fn writeToFile(self: Index, git_dir: []const u8, allocator: std.mem.Allocator, io: std.Io) !void {
        const index_path = try std.fmt.allocPrint(allocator, "{s}/index", .{git_dir});
        defer allocator.free(index_path);

        var f = try std.Io.Dir.cwd().createFile(io, index_path, .{});
        defer f.close(io);

        try std.Io.File.writeStreamingAll(f, io, "DIRC");
        try std.Io.File.writeStreamingAll(f, io, &[_]u8{ 0, 0, 0, 2 });
        const count_bytes = std.mem.nativeToBig(u32, @intCast(self.entries.items.len));
        try std.Io.File.writeStreamingAll(f, io, std.mem.asBytes(&count_bytes));

        for (self.entries.items) |entry| {
            var buf: [64]u8 = undefined;
            var pos: usize = 0;

            std.mem.writeInt(i64, buf[pos..][0..8], entry.ctime, .big); pos += 8;
            std.mem.writeInt(i64, buf[pos..][0..8], entry.mtime, .big); pos += 8;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(entry.dev), .big); pos += 4;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(entry.ino), .big); pos += 4;
            std.mem.writeInt(u32, buf[pos..][0..4], entry.mode, .big); pos += 4;
            std.mem.writeInt(u32, buf[pos..][0..4], entry.uid, .big); pos += 4;
            std.mem.writeInt(u32, buf[pos..][0..4], entry.gid, .big); pos += 4;
            std.mem.writeInt(u32, buf[pos..][0..4], entry.size, .big); pos += 4;
            @memcpy(buf[pos..][0..20], &entry.sha); pos += 20;
            std.mem.writeInt(u16, buf[pos..][0..2], entry.flags, .big); pos += 2;

            try std.Io.File.writeStreamingAll(f, io, buf[0..pos]);
            try std.Io.File.writeStreamingAll(f, io, entry.name);
            try std.Io.File.writeStreamingAll(f, io, "\x00");

            const total = pos + entry.name.len + 1;
            const pad = (8 - (total % 8)) % 8;
            if (pad > 0) {
                var pad_buf: [8]u8 = [_]u8{0} ** 8;
                try std.Io.File.writeStreamingAll(f, io, pad_buf[0..pad]);
            }
        }

        var zero_sha: [20]u8 = [_]u8{0} ** 20;
        try std.Io.File.writeStreamingAll(f, io, &zero_sha);
    }

    pub fn readFromFile(allocator: std.mem.Allocator, git_dir: []const u8, io: std.Io) !Index {
        const index_path = try std.fmt.allocPrint(allocator, "{s}/index", .{git_dir});
        defer allocator.free(index_path);

        var idx = Index.init(allocator);

        var f = std.Io.Dir.cwd().openFile(io, index_path, .{}) catch return idx;
        defer f.close(io);

        var header: [12]u8 = undefined;
        _ = try f.readStreaming(io, &.{&header});

        if (!std.mem.eql(u8, header[0..4], "DIRC")) return idx;

        const version = std.mem.readInt(u32, header[4..8], .big);
        const entry_count = std.mem.readInt(u32, header[8..12], .big);

        if (version != 2 and version != 3) return idx;

        for (0..entry_count) |_| {
            var entry_data: [62]u8 = undefined;
            _ = try f.readStreaming(io, &.{&entry_data});

            var pos: usize = 0;
            const ctime = std.mem.readInt(i64, entry_data[pos..][0..8], .big); pos += 8;
            const mtime = std.mem.readInt(i64, entry_data[pos..][0..8], .big); pos += 8;
            const dev = std.mem.readInt(u32, entry_data[pos..][0..4], .big); pos += 4;
            const ino = std.mem.readInt(u32, entry_data[pos..][0..4], .big); pos += 4;
            const mode = std.mem.readInt(u32, entry_data[pos..][0..4], .big); pos += 4;
            const uid = std.mem.readInt(u32, entry_data[pos..][0..4], .big); pos += 4;
            const gid = std.mem.readInt(u32, entry_data[pos..][0..4], .big); pos += 4;
            const size = std.mem.readInt(u32, entry_data[pos..][0..4], .big); pos += 4;

            var sha: [20]u8 = undefined;
            @memcpy(&sha, entry_data[pos..][0..20]); pos += 20;

            pos += 2;

            var name_buf: [256]u8 = undefined;
            var name_len: usize = 0;
            while (name_len < 256) {
                var byte: [1]u8 = undefined;
                _ = try f.readStreaming(io, &.{&byte});
                if (byte[0] == 0) break;
                name_buf[name_len] = byte[0];
                name_len += 1;
            }

            const entry_len = 62 + name_len + 1;
            const pad = (8 - (entry_len % 8)) % 8;
            if (pad > 0) {
                var pad_buf: [8]u8 = undefined;
                _ = try f.readStreaming(io, &.{pad_buf[0..pad]});
            }

            try idx.add(allocator, name_buf[0..name_len], sha, .{
                .mode = mode,
                .size = size,
                .mtime = mtime,
                .ctime = ctime,
                .dev = dev,
                .ino = ino,
                .uid = uid,
                .gid = gid,
            });
        }

        return idx;
    }
};

/// Build a sub-tree recursively from entries with sub-paths
fn buildSubTree(store: anytype, allocator: std.mem.Allocator, io: std.Io, entries: []const IndexEntry) ![20]u8 {
    const object = @import("object.zig");

    var tree_entries: std.ArrayList(object.TreeEntry) = .empty;
    defer tree_entries.deinit(allocator);

    var sub_dir_map = std.StringHashMap(EntryList).init(allocator);
    defer {
        var iter = sub_dir_map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        sub_dir_map.deinit();
    }

    for (entries) |entry| {
        if (std.mem.indexOf(u8, entry.name, "/")) |slash_pos| {
            const dir_name = entry.name[0..slash_pos];
            const gop = try sub_dir_map.getOrPut(try allocator.dupe(u8, dir_name));
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.append(allocator, .{
                .sha = entry.sha,
                .mode = entry.mode,
                .size = entry.size,
                .name = try allocator.dupe(u8, entry.name[slash_pos + 1 ..]),
                .mtime = entry.mtime,
                .ctime = entry.ctime,
                .dev = entry.dev,
                .ino = entry.ino,
                .uid = entry.uid,
                .gid = entry.gid,
                .flags = entry.flags,
            });
        } else {
            try tree_entries.append(allocator, .{
                .mode = entry.mode,
                .name = entry.name,
                .sha = entry.sha,
            });
        }
    }

    // Recursively build sub-sub-trees
    var sub_iter = sub_dir_map.iterator();
    while (sub_iter.next()) |sub_entry| {
        const sub_tree_sha = try buildSubTree(store, allocator, io, sub_entry.value_ptr.items);
        try tree_entries.append(allocator, .{
            .mode = 0o040000,
            .name = sub_entry.key_ptr.*,
            .sha = sub_tree_sha,
        });
    }

    // Sort by name
    std.sort.insertion(object.TreeEntry, tree_entries.items, {}, struct {
        fn lessThan(_: void, a: object.TreeEntry, b: object.TreeEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    const tree = object.Tree{ .entries = try tree_entries.toOwnedSlice(allocator) };
    return try store.write(allocator, io, object.GitObject{ .tree = tree });
}
