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
    /// Conflict stage; only meaningful when staging a merge result.
    stage: Stage = .normal,
};

/// A merge conflict stage. Git keeps three entries per conflicted path: the
/// common ancestor (1), our side (2) and theirs (3). A single stage-0 entry
/// means the other side is silently dropped when the merge is committed.
pub const Stage = enum(u16) {
    normal = 0,
    base = 1,
    ours = 2,
    theirs = 3,

    pub fn fromBits(bits: u16) Stage {
        return switch (bits) {
            1 => .base,
            2 => .ours,
            3 => .theirs,
            else => .normal,
        };
    }
};

pub const IndexEntry = struct {
    sha: [20]u8 = [_]u8{0} ** 20,
    mode: u32 = 0o100644,
    size: u32 = 0,
    flags: u16 = 0,
    /// The merge-conflict stage; 0 for an ordinary entry.
    stage: Stage = .normal,
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
        // Normalize the path: strip a leading `./` and any trailing or
        // duplicated separators. `gitz add dir/` used to reach the index as
        // `dir//file.txt`, and writeTree then produced a tree entry literally
        // named `/file.txt`, an illegal git object.
        var clean = path;
        while (std.mem.startsWith(u8, clean, "./")) clean = clean[2..];
        while (clean.len > 0 and clean[clean.len - 1] == '/') clean = clean[0 .. clean.len - 1];
        if (clean.len == 0) return;
        if (std.mem.indexOf(u8, clean, "//")) |_| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            var it = std.mem.tokenizeScalar(u8, clean, '/');
            var first = true;
            while (it.next()) |component| {
                if (!first) try buf.append(allocator, '/');
                first = false;
                try buf.appendSlice(allocator, component);
            }
            clean = buf.items;
        }

        // Staging a resolved conflict (stage 0) clears the base/ours/theirs
        // entries for that path. Without this, `git add <file>` after resolving
        // left the three stages in place, so the path stayed unmerged forever
        // and no commit was ever possible.
        if (stat.stage == .normal) {
            var i: usize = 0;
            while (i < self.entries.items.len) {
                const e = self.entries.items[i];
                if (e.stage != .normal and std.mem.eql(u8, e.name, clean)) {
                    allocator.free(e.name);
                    _ = self.entries.orderedRemove(i);
                    continue;
                }
                i += 1;
            }
        }

        // A conflicted path holds one entry per stage, so the match is on name
        // *and* stage.
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, clean) and entry.stage == stat.stage) {
                // Duplicate first: freeing the old name before the allocation
                // below left a dangling pointer if the allocation failed.
                const new_name = try allocator.dupe(u8, clean);
                allocator.free(entry.name);
                self.entries.items[i].sha = sha;
                self.entries.items[i].size = stat.size;
                self.entries.items[i].mtime = stat.mtime;
                self.entries.items[i].ctime = stat.ctime;
                self.entries.items[i].mode = stat.mode;
                self.entries.items[i].name = new_name;
                return;
            }
        }
        const owned_name = try allocator.dupe(u8, clean);
        try self.entries.append(allocator, .{ .sha = sha, .size = stat.size, .mtime = stat.mtime, .ctime = stat.ctime, .mode = stat.mode, .stage = stat.stage, .name = owned_name });
    }

    /// Whether any entry is an unresolved conflict (stage 1, 2 or 3).
    ///
    /// `gitz commit` must refuse while this is true, otherwise the merge is
    /// completed with one side of every conflict silently discarded.
    pub fn hasConflicts(self: Index) bool {
        for (self.entries.items) |entry| {
            if (entry.stage != .normal) return true;
        }
        return false;
    }

    /// Paths that have unresolved conflicts, each listed once.
    pub fn conflictedPaths(self: Index, allocator: std.mem.Allocator) [][]const u8 {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();

        var paths: std.ArrayList([]const u8) = .empty;
        for (self.entries.items) |entry| {
            if (entry.stage == .normal) continue;
            if (seen.contains(entry.name)) continue;
            seen.put(entry.name, {}) catch return paths.toOwnedSlice(allocator) catch &.{};
            paths.append(allocator, entry.name) catch break;
        }
        return paths.toOwnedSlice(allocator) catch &.{};
    }

    /// Remove the entry for `name`. Returns true when an entry was removed.
    pub fn remove(self: *Index, allocator: std.mem.Allocator, name: []const u8) bool {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                allocator.free(entry.name);
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Build hierarchical git tree from flat index entries.
    pub fn writeTree(self: *Index, store: anytype, allocator: std.mem.Allocator, io: std.Io) ![20]u8 {
        const object = @import("object.zig");

        // A tree entry holds one SHA per path, so writing a tree while a
        // conflict is unresolved would record one arbitrary side of it as if it
        // were the agreed result. Git refuses the commit instead.
        if (self.hasConflicts()) return error.UnmergedPaths;

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

        // The index trailer is the SHA-1 of every preceding byte, not a run of
        // zeros. With zeros, real git rejected the file ("cache entry has null
        // sha1" / "corrupt index file"), so a repository written by gitz could
        // not be opened by git even though the entries themselves were valid.
        var hasher = std.crypto.hash.Sha1.init(.{});
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);

        const emit = struct {
            fn put(list: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
                try list.appendSlice(gpa, bytes);
            }
        };

        try emit.put(&body, allocator, "DIRC");
        try emit.put(&body, allocator, &[_]u8{ 0, 0, 0, 2 });
        const count_bytes = std.mem.nativeToBig(u32, @intCast(self.entries.items.len));
        try emit.put(&body, allocator, std.mem.asBytes(&count_bytes));

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

            // The flags word packs the name length (low 12 bits) and the
            // conflict stage (bits 12-13). Both were written as 0, so git read
            // every entry as having an empty name and never saw a conflict.
            const name_len = entry.name.len;
            const flag_len: u16 = if (name_len >= 0xFFF) 0xFFF else @intCast(name_len);
            const stage_bits: u16 = @intFromEnum(entry.stage) << 12;
            const assume_valid: u16 = if (entry.flags & 0x8000 != 0) 0x8000 else 0;
            const flags: u16 = assume_valid | stage_bits | flag_len;
            std.mem.writeInt(u16, buf[pos..][0..2], flags, .big); pos += 2;

            try emit.put(&body, allocator, buf[0..pos]);
            try emit.put(&body, allocator, entry.name);
            try emit.put(&body, allocator, "\x00");

            // Entries are padded with NULs to a multiple of eight bytes.
            // Verified against git 2.55: a 5-byte name produces a 68-byte
            // record and the next entry starts at +72.
            const total = pos + name_len + 1;
            const pad = (8 - (total % 8)) % 8;
            if (pad > 0) {
                var pad_buf: [8]u8 = [_]u8{0} ** 8;
                try emit.put(&body, allocator, pad_buf[0..pad]);
            }
        }

        hasher.update(body.items);
        var trailer: [20]u8 = undefined;
        hasher.final(&trailer);

        try std.Io.File.writeStreamingAll(f, io, body.items);
        try std.Io.File.writeStreamingAll(f, io, &trailer);
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

            // Prefer the name length from the flags word, so an index written
            // by real git round-trips. 0xFFF is the "long name" marker, and
            // only then is the name read up to its NUL.
            const flags = std.mem.readInt(u16, entry_data[pos - 2 ..][0..2], .big);
            const flag_name_len = flags & 0x0FFF;

            var name_buf: [4096]u8 = undefined;
            var name_len: usize = 0;

            if (flag_name_len == 0xFFF) {
                while (name_len < name_buf.len) {
                    var byte: [1]u8 = undefined;
                    _ = try f.readStreaming(io, &.{&byte});
                    if (byte[0] == 0) break;
                    name_buf[name_len] = byte[0];
                    name_len += 1;
                }
            } else if (flag_name_len != 0) {
                name_len = @intCast(flag_name_len);
                if (name_len > name_buf.len) name_len = name_buf.len;
                _ = try f.readStreaming(io, &.{name_buf[0..name_len]});

                var term: [1]u8 = undefined;
                _ = try f.readStreaming(io, &.{&term});
            } else {
                // No length recorded (an index written by an older gitz): scan
                // for the NUL terminator instead.
                while (name_len < name_buf.len) {
                    var byte: [1]u8 = undefined;
                    _ = try f.readStreaming(io, &.{&byte});
                    if (byte[0] == 0) break;
                    name_buf[name_len] = byte[0];
                    name_len += 1;
                }
            }

            // Entries are padded to a multiple of eight bytes.
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
                .stage = Stage.fromBits(flags >> 12),
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
