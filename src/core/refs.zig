const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;

pub const HeadInfo = union(enum) {
    branch: struct { name: std.ArrayList(u8), sha: [20]u8 },
    detached: struct { sha: [20]u8 },

    pub fn deinit(self: *HeadInfo, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .branch => |*b| b.name.deinit(allocator),
            .detached => {},
        }
    }

    pub fn branchName(self: HeadInfo) []const u8 {
        return switch (self) {
            .branch => |b| b.name.items,
            .detached => unreachable,
        };
    }

    pub fn sha(self: HeadInfo) [20]u8 {
        return switch (self) {
            .branch => |b| b.sha,
            .detached => |d| d.sha,
        };
    }
};

pub const Refs = struct {
    git_dir: []const u8,

    pub fn init(git_dir: []const u8) Refs {
        return .{ .git_dir = git_dir };
    }

    fn readFileContent(self: Refs, allocator: std.mem.Allocator, io: std.Io, sub_path: []const u8) ![]u8 {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.git_dir, sub_path });
        defer allocator.free(full_path);
        return std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .unlimited);
    }

    /// Read a ref from the loose file only (no packed-refs fallback).
    pub fn readLooseOnly(self: Refs, allocator: std.mem.Allocator, io: std.Io, refname: []const u8) anyerror![20]u8 {
        const content = self.readFileContent(allocator, io, refname) catch {
            return error.RefNotFound;
        };
        defer allocator.free(content);

        const trimmed = std.mem.trim(u8, content, &[_]u8{ '\n', '\r', ' ' });

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const target = trimmed[5..];
            return self.read(allocator, io, target);
        }

        if (trimmed.len != 40) return error.InvalidRef;
        return Sha1.fromHex(trimmed);
    }

    pub fn read(self: Refs, allocator: std.mem.Allocator, io: std.Io, refname: []const u8) ![20]u8 {
        if (self.readLooseOnly(allocator, io, refname)) |sha| {
            return sha;
        } else |_| {}

        // Fall back to packed-refs
        var pr = loadPackedRefs(self, allocator, io) orelse return error.RefNotFound;
        defer pr.deinit(allocator);
        if (pr.find(refname)) |e| return e.sha;
        return error.RefNotFound;
    }

    pub fn write(self: Refs, allocator: std.mem.Allocator, io: std.Io, refname: []const u8, sha: [20]u8) !void {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.git_dir, std.fs.path.dirname(refname) orelse "." });
        defer allocator.free(dir_path);

        try std.Io.Dir.cwd().createDirPath(io, dir_path);

        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.git_dir, refname });
        defer allocator.free(ref_path);

        var f = try std.Io.Dir.cwd().createFile(io, ref_path, .{});
        defer f.close(io);

        const hex = Sha1.hex(sha);
        try std.Io.File.writeStreamingAll(f, io, &hex);
        try std.Io.File.writeStreamingAll(f, io, "\n");
    }

    pub fn writeSymbolic(self: Refs, allocator: std.mem.Allocator, io: std.Io, name: []const u8, target: []const u8) !void {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.git_dir, name });
        defer allocator.free(ref_path);

        var f = try std.Io.Dir.cwd().createFile(io, ref_path, .{});
        defer f.close(io);

        try std.Io.File.writeStreamingAll(f, io, "ref: ");
        try std.Io.File.writeStreamingAll(f, io, target);
        try std.Io.File.writeStreamingAll(f, io, "\n");
    }

    pub fn delete(self: Refs, allocator: std.mem.Allocator, io: std.Io, refname: []const u8) !void {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.git_dir, refname });
        defer allocator.free(ref_path);
        std.Io.Dir.cwd().deleteFile(io, ref_path) catch {};

        // Also remove from packed-refs when present (rewrite file)
        var pr = loadPackedRefs(self, allocator, io) orelse return;
        defer pr.deinit(allocator);
        if (pr.remove(allocator, refname)) {
            try writePackedRefsFile(&self, allocator, io, &pr);
        }
    }

    pub fn head(self: Refs, allocator: std.mem.Allocator, io: std.Io) !HeadInfo {
        const sha = self.read(allocator, io, "HEAD") catch {
            return HeadInfo{ .detached = .{ .sha = (@as([20]u8, @splat(0))) } };
        };

        const head_content = self.readFileContent(allocator, io, "HEAD") catch {
            return HeadInfo{ .detached = .{ .sha = sha } };
        };
        defer allocator.free(head_content);

        const trimmed = std.mem.trim(u8, head_content, &[_]u8{ '\n', '\r', ' ' });

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const target = trimmed[5..];
            const raw_name = if (std.mem.startsWith(u8, target, "refs/heads/"))
                target[11..]
            else
                target;
            var name_list: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
            try name_list.appendSlice(allocator, raw_name);
            return HeadInfo{ .branch = .{ .name = name_list, .sha = sha } };
        }

        return HeadInfo{ .detached = .{ .sha = sha } };
    }

    /// List all ref files under a subdirectory of refs/ (e.g. "heads" or "tags").
    /// Uses raw Linux getdents64 syscall to avoid Zig 0.16 Dir.iterate() fd lifecycle issues.
    /// Returns fully-qualified ref names like "refs/heads/main".
    pub fn list(self: Refs, allocator: std.mem.Allocator, io: std.Io, subcategory: []const u8) ![][]const u8 {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/refs/{s}", .{ self.git_dir, subcategory });
        defer allocator.free(dir_path);

        const prefix = try std.fmt.allocPrint(allocator, "refs/{s}", .{subcategory});
        defer allocator.free(prefix);

        const loose = listDirRaw(allocator, dir_path, prefix) catch &.{};
        defer {
            for (loose) |l| allocator.free(l);
            if (loose.len > 0) allocator.free(loose);
        }

        // Merge packed-refs entries under this subcategory; loose wins on conflict.
        var merged: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
        errdefer {
            for (merged.items) |m| allocator.free(m);
            merged.deinit(allocator);
        }

        for (loose) |l| {
            try merged.append(allocator, try allocator.dupe(u8, l));
        }

        if (loadPackedRefs(self, allocator, io)) |pr_val| {
            var pr = pr_val;
            defer pr.deinit(allocator);
            const sub_prefix = try std.fmt.allocPrint(allocator, "refs/{s}/", .{subcategory});
            defer allocator.free(sub_prefix);
            for (pr.entries.items) |e| {
                if (!std.mem.startsWith(u8, e.refname, sub_prefix)) continue;
                var dup = false;
                for (merged.items) |m| {
                    if (std.mem.eql(u8, m, e.refname)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) {
                    try merged.append(allocator, try allocator.dupe(u8, e.refname));
                }
            }
        }

        const SortCtx = struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        };
        std.mem.sort([]const u8, merged.items, {}, SortCtx.lessThan);

        return try merged.toOwnedSlice(allocator);
    }

    /// Raw directory listing using Linux getdents64 syscall
    fn listDirRaw(allocator: std.mem.Allocator, dir_path: []const u8, prefix: []const u8) ![][]const u8 {
        var result: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };

        // Open directory using posix.openat
        const dir_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{dir_path}, 0);
        defer allocator.free(dir_z);

        const fd = std.posix.openat(std.posix.AT.FDCWD, dir_z, std.posix.O{ .ACCMODE = .RDONLY }, 0) catch {
            return &.{};
        };
        defer { _ = std.os.linux.close(@intCast(fd)); }

        var buf: [4096]u8 align(@alignOf(usize)) = undefined;
        while (true) {
            const rc = std.os.linux.getdents64(@intCast(fd), &buf, buf.len);
            const n: usize = if (rc > 0) @intCast(rc) else break;
            if (n == 0) break;

            var pos: usize = 0;
            while (pos < n) {
                const entry: *align(1) const std.os.linux.dirent64 = @ptrCast(&buf[pos]);
                const name: []const u8 = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);

                // Skip . and ..
                if (name.len > 0 and name[0] != '.') {
                    const full_ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
                    try result.append(allocator, full_ref);
                }
                pos += entry.reclen;
            }
        }

        return result.toOwnedSlice(allocator);
    }
};

// ============================================================================
// Packed-refs — git-compatible packed reference storage
// Format:
//   # pack-refs with: peeled fully-peeled sorted 
//   <40-hex> <refname>
//   ^<40-hex>          (peeled annotated tag target, optional)
// ============================================================================

pub const PackedRefEntry = struct {
    refname: []const u8,
    sha: [20]u8,
    peeled: ?[20]u8 = null,
};

pub const PackedRefs = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(PackedRefEntry) = .{ .items = &.{}, .capacity = 0 },

    pub fn init(allocator: std.mem.Allocator) PackedRefs {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PackedRefs, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| allocator.free(e.refname);
        self.entries.deinit(allocator);
    }

    /// Insert or replace an entry, keeping the list sorted by refname.
    pub fn put(self: *PackedRefs, allocator: std.mem.Allocator, entry: PackedRefEntry) !void {
        // Replace existing entry with the same name
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.refname, entry.refname)) {
                const owned = try allocator.dupe(u8, entry.refname);
                errdefer allocator.free(owned);
                self.entries.items[i] = .{ .refname = owned, .sha = entry.sha, .peeled = entry.peeled };
                return;
            }
        }
        const owned = try allocator.dupe(u8, entry.refname);
        errdefer allocator.free(owned);
        try self.entries.append(allocator, .{ .refname = owned, .sha = entry.sha, .peeled = entry.peeled });
    }

    pub fn find(self: *const PackedRefs, refname: []const u8) ?PackedRefEntry {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.refname, refname)) return e;
        }
        return null;
    }

    pub fn remove(self: *PackedRefs, allocator: std.mem.Allocator, refname: []const u8) bool {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.refname, refname)) {
                allocator.free(e.refname);
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    fn sort(self: *PackedRefs) void {
        const Ctx = struct {
            fn lessThan(_: void, a: PackedRefEntry, b: PackedRefEntry) bool {
                return std.mem.order(u8, a.refname, b.refname) == .lt;
            }
        };
        std.mem.sort(PackedRefEntry, self.entries.items, {}, Ctx.lessThan);
    }

    /// Serialize to git-compatible packed-refs text (caller frees).
    /// Entries are emitted sorted by refname (git convention).
    pub fn serialize(self: *const PackedRefs, allocator: std.mem.Allocator) ![]u8 {
        const sorted = try allocator.dupe(PackedRefEntry, self.entries.items);
        defer allocator.free(sorted);
        const SortCtx = struct {
            fn lessThan(_: void, a: PackedRefEntry, b: PackedRefEntry) bool {
                return std.mem.order(u8, a.refname, b.refname) == .lt;
            }
        };
        std.mem.sort(PackedRefEntry, sorted, {}, SortCtx.lessThan);

        var out: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "# pack-refs with: peeled fully-peeled sorted \n");
        for (sorted) |e| {
            const hex = Sha1.hex(e.sha);
            try out.appendSlice(allocator, &hex);
            try out.appendSlice(allocator, " ");
            try out.appendSlice(allocator, e.refname);
            try out.appendSlice(allocator, "\n");
            if (e.peeled) |p| {
                const phex = Sha1.hex(p);
                try out.appendSlice(allocator, "^");
                try out.appendSlice(allocator, &phex);
                try out.appendSlice(allocator, "\n");
            }
        }
        return out.toOwnedSlice(allocator);
    }
};

/// Parse packed-refs content into an owned PackedRefs.
pub fn parsePackedRefs(allocator: std.mem.Allocator, content: []const u8) !PackedRefs {
    var pr = PackedRefs.init(allocator);
    errdefer pr.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        if (trimmed[0] == '^') {
            // Peeled target of the previous entry
            if (trimmed.len >= 41) {
                if (Sha1.fromHex(trimmed[1..41])) |peeled| {
                    if (pr.entries.items.len > 0) {
                        pr.entries.items[pr.entries.items.len - 1].peeled = peeled;
                    }
                } else |_| {}
            }
            continue;
        }
        if (trimmed.len < 42 or trimmed[40] != ' ') continue;
        const sha = Sha1.fromHex(trimmed[0..40]) catch continue;
        const refname = trimmed[41..];
        if (refname.len == 0) continue;
        try pr.put(allocator, .{ .refname = refname, .sha = sha, .peeled = null });
    }
    return pr;
}

fn packedRefsPath(self: Refs, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/packed-refs", .{self.git_dir});
}

/// Load the repo's packed-refs file; returns null when absent or unreadable.
pub fn loadPackedRefs(self: Refs, allocator: std.mem.Allocator, io: std.Io) ?PackedRefs {
    const path = packedRefsPath(self, allocator) catch return null;
    defer allocator.free(path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return null;
    defer allocator.free(content);
    return parsePackedRefs(allocator, content) catch null;
}

/// Write a PackedRefs back to the repo's packed-refs file.
pub fn writePackedRefsFile(self: *const Refs, allocator: std.mem.Allocator, io: std.Io, pr: *const PackedRefs) !void {
    const path = try packedRefsPath(self.* , allocator);
    defer allocator.free(path);
    const data = try pr.serialize(allocator);
    defer allocator.free(data);

    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try std.Io.File.writeStreamingAll(f, io, data);
}

/// Compact all loose refs under refs/heads and refs/tags into packed-refs,
/// deleting the loose files afterwards. Returns the number of refs packed.
/// `exclude` lists refnames that must stay loose (e.g. the current branch).
pub fn packRefs(self: *const Refs, allocator: std.mem.Allocator, io: std.Io, exclude: ?[]const []const u8) !usize {
    var pr = loadPackedRefs(self.*, allocator, io) orelse PackedRefs.init(allocator);
    defer pr.deinit(allocator);

    var packed_count: usize = 0;
    for ([_][]const u8{ "heads", "tags" }) |sub| {
        const names = try self.list(allocator, io, sub);
        defer {
            for (names) |n| allocator.free(n);
            allocator.free(names);
        }
        for (names) |name| {
            if (exclude) |ex| {
                var skip = false;
                for (ex) |x| {
                    if (std.mem.eql(u8, x, name)) {
                        skip = true;
                        break;
                    }
                }
                if (skip) continue;
            }
            const sha = self.readLooseOnly(allocator, io, name) catch continue;
            try pr.put(allocator, .{ .refname = name, .sha = sha, .peeled = null });
            packed_count += 1;
        }
    }

    if (packed_count == 0 and pr.entries.items.len == 0) return 0;

    try writePackedRefsFile(self, allocator, io, &pr);

    // Delete the loose files that were folded into packed-refs
    for (pr.entries.items) |e| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.git_dir, e.refname });
        defer allocator.free(p);
        std.Io.Dir.cwd().deleteFile(io, p) catch {};
    }

    return packed_count;
}

// ============================================================================
// Packed-refs — TDD tests (written before implementation)
// ============================================================================

const testing_io = std.testing.io;

fn makeTempGitDir(comptime tag: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/gitz_refs_test_{s}_{d}", .{ tag, std.Io.Timestamp.now(testing_io, .real).nanoseconds });
    try std.Io.Dir.cwd().createDirPath(testing_io, path);
    return path;
}

fn freeTempDir(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(testing_io, path) catch {};
    std.testing.allocator.free(path);
}

test "parsePackedRefs: standard git format with header and peeled lines" {
    const a = std.testing.allocator;
    var pr = try parsePackedRefs(a,
        \\# pack-refs with: peeled fully-peeled sorted 
        \\aaaa00000000000000000000000000000000aaa1 refs/heads/main
        \\bbbb00000000000000000000000000000000bbb2 refs/tags/v1.0
        \\^cccc00000000000000000000000000000000ccc3
        \\dddd00000000000000000000000000000000ddd4 refs/remotes/origin/main
        \\
    );
    defer pr.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), pr.entries.items.len);
    try std.testing.expectEqualStrings("refs/heads/main", pr.entries.items[0].refname);
    try std.testing.expectEqualStrings("aaaa00000000000000000000000000000000aaa1", &Sha1.hex(pr.entries.items[0].sha));
    // The ^ line belongs to the preceding tag entry
    try std.testing.expectEqualStrings("refs/tags/v1.0", pr.entries.items[1].refname);
    const peeled = pr.entries.items[1].peeled.?;
    try std.testing.expectEqualStrings("cccc00000000000000000000000000000000ccc3", &Sha1.hex(peeled));
    try std.testing.expect(pr.entries.items[2].peeled == null);
}

test "parsePackedRefs: empty file" {
    const a = std.testing.allocator;
    var pr = try parsePackedRefs(a, "");
    defer pr.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), pr.entries.items.len);
}

test "writePackedRefs roundtrip preserves all entries sorted" {
    const a = std.testing.allocator;
    var pr = PackedRefs.init(a);
    defer pr.deinit(a);
    const s1 = try Sha1.fromHex("1111000000000000000000000000000000001111");
    const s2 = try Sha1.fromHex("2222000000000000000000000000000000002222");
    try pr.put(a, .{ .refname = "refs/heads/zebra", .sha = s2, .peeled = null });
    try pr.put(a, .{ .refname = "refs/heads/apple", .sha = s1, .peeled = null });
    const out = try pr.serialize(a);
    defer a.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "# pack-refs"));
    var reparsed = try parsePackedRefs(a, out);
    defer reparsed.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), reparsed.entries.items.len);
    // Sorted order: apple first (git convention for binary-search-friendly reads)
    try std.testing.expectEqualStrings("refs/heads/apple", reparsed.entries.items[0].refname);
}

test "read: packed ref found when loose missing; loose wins when both exist" {
    const a = std.testing.allocator;
    const dir = try makeTempGitDir("rw");
    defer freeTempDir(dir);
    var refs = Refs.init(dir);

    const packed_sha = try Sha1.fromHex("9999000000000000000000000000000000009999");
    var pr = PackedRefs.init(a);
    defer pr.deinit(a);
    try pr.put(a, .{ .refname = "refs/heads/packed-only", .sha = packed_sha, .peeled = null });
    try pr.put(a, .{ .refname = "refs/heads/both", .sha = packed_sha, .peeled = null });
    try writePackedRefsFile(&refs, a, testing_io, &pr);

    const loose_sha = try Sha1.fromHex("8888000000000000000000000000000000008888");
    try refs.write(a, testing_io, "refs/heads/both", loose_sha);

    // packed-only resolves through packed-refs
    const got_packed = try refs.read(a, testing_io, "refs/heads/packed-only");
    try std.testing.expectEqual(packed_sha, got_packed);
    // loose shadows packed
    const got_both = try refs.read(a, testing_io, "refs/heads/both");
    try std.testing.expectEqual(loose_sha, got_both);
}

test "list: merges packed + loose, deduped, sorted" {
    const a = std.testing.allocator;
    const dir = try makeTempGitDir("list");
    defer freeTempDir(dir);
    var refs = Refs.init(dir);

    const s = try Sha1.fromHex("7777000000000000000000000000000000007777");
    var pr = PackedRefs.init(a);
    defer pr.deinit(a);
    try pr.put(a, .{ .refname = "refs/heads/b-second", .sha = s, .peeled = null });
    try pr.put(a, .{ .refname = "refs/heads/d-packed", .sha = s, .peeled = null });
    try pr.put(a, .{ .refname = "refs/tags/v1", .sha = s, .peeled = null });
    try writePackedRefsFile(&refs, a, testing_io, &pr);

    try refs.write(a, testing_io, "refs/heads/a-first", s);
    try refs.write(a, testing_io, "refs/heads/d-packed", s); // overrides packed

    const heads = try refs.list(a, testing_io, "heads");
    defer {
        for (heads) |h| a.free(h);
        a.free(heads);
    }
    try std.testing.expectEqual(@as(usize, 3), heads.len);
    try std.testing.expectEqualStrings("refs/heads/a-first", heads[0]);
    try std.testing.expectEqualStrings("refs/heads/b-second", heads[1]);
    try std.testing.expectEqualStrings("refs/heads/d-packed", heads[2]);

    const tags = try refs.list(a, testing_io, "tags");
    defer {
        for (tags) |t| a.free(t);
        a.free(tags);
    }
    try std.testing.expectEqual(@as(usize, 1), tags.len);
    try std.testing.expectEqualStrings("refs/tags/v1", tags[0]);
}

test "delete: removes packed ref by rewriting packed-refs" {
    const a = std.testing.allocator;
    const dir = try makeTempGitDir("del");
    defer freeTempDir(dir);
    var refs = Refs.init(dir);

    const s = try Sha1.fromHex("6666000000000000000000000000000000006666");
    var pr = PackedRefs.init(a);
    defer pr.deinit(a);
    try pr.put(a, .{ .refname = "refs/heads/keep-me", .sha = s, .peeled = null });
    try pr.put(a, .{ .refname = "refs/heads/delete-me", .sha = s, .peeled = null });
    try writePackedRefsFile(&refs, a, testing_io, &pr);

    try refs.delete(a, testing_io, "refs/heads/delete-me");

    try std.testing.expectError(error.RefNotFound, refs.read(a, testing_io, "refs/heads/delete-me"));
    const kept = try refs.read(a, testing_io, "refs/heads/keep-me");
    try std.testing.expectEqual(s, kept);
}

test "packRefs: compacts loose refs into git-readable packed-refs" {
    const a = std.testing.allocator;
    const dir = try makeTempGitDir("pack");
    defer freeTempDir(dir);
    var refs = Refs.init(dir);

    const s1 = try Sha1.fromHex("5555000000000000000000000000000000005555");
    const s2 = try Sha1.fromHex("4444000000000000000000000000000000004444");
    try refs.write(a, testing_io, "refs/heads/main", s1);
    try refs.write(a, testing_io, "refs/heads/feature", s2);

    const count = try packRefs(&refs, a, testing_io, null);
    try std.testing.expectEqual(@as(usize, 2), count);

    // Loose files are gone after packing
    try std.testing.expectError(error.RefNotFound, refs.readLooseOnly(a, testing_io, "refs/heads/main"));

    // But reads still resolve through packed-refs
    const main = try refs.read(a, testing_io, "refs/heads/main");
    try std.testing.expectEqual(s1, main);
    const feat = try refs.read(a, testing_io, "refs/heads/feature");
    try std.testing.expectEqual(s2, feat);
}
