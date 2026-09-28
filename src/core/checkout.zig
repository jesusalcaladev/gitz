const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const storage_mod = @import("storage.zig");
const index_mod = @import("index.zig");
const object = @import("object.zig");
const safety = @import("../util/clone_safety.zig");

/// Flat map of repository path -> blob SHA (plus mode).
pub const FileEntry = struct {
    sha: [20]u8,
    mode: u32 = 0o100644,
};
pub const FileMap = std.StringHashMap(FileEntry);

/// Git blob SHA-1 for the given file content.
pub fn blobSha(allocator: std.mem.Allocator, content: []const u8) ![20]u8 {
    var header_buf: [48]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "blob {d}\x00", .{content.len});
    const full = try std.mem.concat(allocator, u8, &.{ header, content });
    defer allocator.free(full);
    return Sha1.hash(full);
}

/// Recursively collect every blob of a tree into `map` (paths relative to the
/// worktree root). Keys are owned by `allocator`.
pub fn flattenTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage_mod.StorageBackend,
    tree_sha: [20]u8,
    prefix: []const u8,
    map: *FileMap,
) !void {
    const tree_obj = store.read(allocator, io, tree_sha) catch return;
    defer tree_obj.deinit(allocator);
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        if (entry.mode == 0o040000) {
            flattenTree(allocator, io, store, entry.sha, full_path, map) catch {};
            allocator.free(full_path);
        } else {
            const gop = try map.getOrPut(full_path);
            if (gop.found_existing) allocator.free(full_path);
            gop.value_ptr.* = .{ .sha = entry.sha, .mode = entry.mode };
        }
    }
}

/// Read a blob's content. Returns null if the object is missing/not a blob.
pub fn readBlob(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage_mod.StorageBackend,
    sha: [20]u8,
) ?[]const u8 {
    const obj = store.read(allocator, io, sha) catch return null;
    return switch (obj) {
        // Ownership of the (heap-duplicated) content moves to the caller,
        // who must free it.
        .blob => |b| b.content,
        else => {
            // Not a blob: nothing to hand back, so release the object.
            obj.deinit(allocator);
            return null;
        },
    };
}

fn appendTreeEntries(
    idx: *index_mod.Index,
    store: storage_mod.StorageBackend,
    allocator: std.mem.Allocator,
    io: std.Io,
    tree_sha: [20]u8,
    prefix: []const u8,
) !void {
    const tree_obj = store.read(allocator, io, tree_sha) catch return;
    defer tree_obj.deinit(allocator);
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        if (entry.mode == 0o040000) {
            appendTreeEntries(idx, store, allocator, io, entry.sha, full_path) catch {};
            allocator.free(full_path);
        } else {
            try idx.entries.append(allocator, .{
                .sha = entry.sha,
                .mode = entry.mode,
                .name = full_path,
            });
        }
    }
}

/// Rebuild the index so it matches the given commit's tree exactly.
pub fn writeIndexForCommit(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: std.Io,
    store: storage_mod.StorageBackend,
    commit_sha: [20]u8,
) !void {
    const commit_obj = store.read(allocator, io, commit_sha) catch return;
    defer commit_obj.deinit(allocator);
    const commit = switch (commit_obj) {
        .commit => |c| c,
        else => return,
    };

    var idx = index_mod.Index.init(allocator);
    defer idx.deinit(allocator);

    try appendTreeEntries(&idx, store, allocator, io, commit.tree, "");
    try idx.writeToFile(git_dir, allocator, io);
}

/// Recursively write every file of a tree into the working directory
/// (creating parent directories as needed).
pub fn restoreTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage_mod.StorageBackend,
    tree_sha: [20]u8,
    prefix: []const u8,
) void {
    const tree_obj = store.read(allocator, io, tree_sha) catch return;
    defer tree_obj.deinit(allocator);
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        const full_path = if (prefix.len > 0)
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name }) catch continue
        else
            allocator.dupe(u8, entry.name) catch continue;
        defer allocator.free(full_path);

        if (entry.mode == 0o040000) {
            // The assembled path is validated before it is used as a directory
            // as well, so a crafted tree cannot create directories outside the
            // worktree.
            safety.validateWorktreePath(full_path) catch continue;
            std.Io.Dir.cwd().createDirPath(io, full_path) catch {};
            restoreTree(allocator, io, store, entry.sha, full_path);
        } else {
            // `entry.name` comes straight from a fetched tree object. The clone
            // entry points validated it, but checkout (reached from `switch`,
            // `merge` and `merge --abort`) did not, so an entry named
            // `../../../../home/user/.bashrc` wrote outside the worktree.
            safety.validateWorktreePath(full_path) catch continue;

            const content = readBlob(allocator, io, store, entry.sha) orelse continue;
            defer allocator.free(content);
            if (std.fs.path.dirname(full_path)) |dir| {
                std.Io.Dir.cwd().createDirPath(io, dir) catch {};
            }
            var wf = std.Io.Dir.cwd().createFile(io, full_path, .{}) catch continue;
            defer wf.close(io);
            std.Io.File.writeStreamingAll(wf, io, content) catch {};
        }
    }
}

/// Paths tracked in `old_index`, still present on disk, that `target` lacks
/// (i.e. files to delete when moving to `target`).
pub fn stalePaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    old_index: *const index_mod.Index,
    target: *const FileMap,
) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }

    for (old_index.entries.items) |entry| {
        const clean = if (std.mem.startsWith(u8, entry.name, "./")) entry.name[2..] else entry.name;
        if (target.contains(clean)) continue;
        std.Io.Dir.cwd().access(io, clean, .{}) catch continue;
        try list.append(allocator, try allocator.dupe(u8, clean));
    }
    return list.toOwnedSlice(allocator);
}

pub const DirtyReport = struct {
    paths: [][]const u8,

    pub fn deinit(self: *DirtyReport, allocator: std.mem.Allocator) void {
        for (self.paths) |p| allocator.free(p);
        allocator.free(self.paths);
    }
};

/// Check whether replacing the working tree/index with `target_commit`'s tree
/// would destroy uncommitted work. Returns the offending paths (empty == safe).
pub fn checkSafeToReplace(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: std.Io,
    store: storage_mod.StorageBackend,
    target_commit: [20]u8,
) !DirtyReport {
    var dirty: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (dirty.items) |p| allocator.free(p);
        dirty.deinit(allocator);
    }

    const commit_obj = store.read(allocator, io, target_commit) catch return .{ .paths = &.{} };
    defer commit_obj.deinit(allocator);
    const commit = switch (commit_obj) {
        .commit => |c| c,
        else => return .{ .paths = &.{} },
    };

    // Files that will exist after the switch.
    var target: FileMap = .init(allocator);
    defer freeMap(allocator, &target);
    try flattenTree(allocator, io, store, commit.tree, "", &target);

    var idx = try index_mod.Index.readFromFile(allocator, git_dir, io);
    defer idx.deinit(allocator);

    // 1) Files of the target tree that already exist on disk must be either
    //    identical to the target or identical to the index (clean).
    var it = target.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch continue;
        defer allocator.free(content);

        const work = try blobSha(allocator, content);
        if (std.mem.eql(u8, &work, &entry.value_ptr.sha)) continue;

        const idx_sha = findIndexSha(&idx, path);
        if (idx_sha == null or !std.mem.eql(u8, &work, &idx_sha.?)) {
            try dirty.append(allocator, try allocator.dupe(u8, path));
        }
    }

    // 2) Tracked files the target tree does not contain will be deleted:
    //    refuse when they carry uncommitted changes.
    for (idx.entries.items) |entry| {
        const clean = if (std.mem.startsWith(u8, entry.name, "./")) entry.name[2..] else entry.name;
        if (target.contains(clean)) continue;
        const content = std.Io.Dir.cwd().readFileAlloc(io, clean, allocator, .unlimited) catch continue;
        defer allocator.free(content);
        const work = try blobSha(allocator, content);
        if (!std.mem.eql(u8, &work, &entry.sha)) {
            try dirty.append(allocator, try allocator.dupe(u8, clean));
        }
    }

    return .{ .paths = try dirty.toOwnedSlice(allocator) };
}

fn findIndexSha(idx: *const index_mod.Index, name: []const u8) ?[20]u8 {
    for (idx.entries.items) |entry| {
        const clean = if (std.mem.startsWith(u8, entry.name, "./")) entry.name[2..] else entry.name;
        if (std.mem.eql(u8, clean, name)) return entry.sha;
    }
    return null;
}

/// Full checkout of `commit_sha`: replaces index and working tree. Callers
/// should run `checkSafeToReplace` first when uncommitted work must be kept.
pub fn checkoutCommit(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: std.Io,
    store: storage_mod.StorageBackend,
    commit_sha: [20]u8,
) !void {
    const commit_obj = store.read(allocator, io, commit_sha) catch return;
    defer commit_obj.deinit(allocator);
    const commit = switch (commit_obj) {
        .commit => |c| c,
        else => return,
    };

    // Files tracked now that the target tree lacks -> delete after restore.
    var target: FileMap = .init(allocator);
    defer freeMap(allocator, &target);
    try flattenTree(allocator, io, store, commit.tree, "", &target);

    var old_index = try index_mod.Index.readFromFile(allocator, git_dir, io);
    defer old_index.deinit(allocator);
    const stale = try stalePaths(allocator, io, &old_index, &target);
    defer {
        for (stale) |p| allocator.free(p);
        allocator.free(stale);
    }

    // 1) index matches the target tree
    try writeIndexForCommit(allocator, git_dir, io, store, commit_sha);
    // 2) files come from the target tree
    restoreTree(allocator, io, store, commit.tree, "");
    // 3) files the target tree no longer has are removed
    for (stale) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
}

pub fn freeMap(allocator: std.mem.Allocator, map: *FileMap) void {
    var it = map.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    map.deinit();
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "blobSha matches git blob hashing" {
    const sha = try blobSha(testing.allocator, "hello");
    const hex = Sha1.hex(sha);
    const expected = Sha1.hash("blob 5\x00hello");
    try testing.expectEqualStrings(&Sha1.hex(expected), &hex);
}

test "flattenTree walks nested trees" {
    const io = testing.io;
    const allocator = testing.allocator;

    const root = "zig-cache/gitz_checkout_test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    const store = storage_mod.StorageBackend.looseBackend(root);

    // inner tree: sub/file.txt
    const blob_sha = try store.write(allocator, io, .{ .blob = .{ .content = "deep" } });
    var inner_entries = [_]object.TreeEntry{.{ .mode = 0o100644, .name = "file.txt", .sha = blob_sha }};
    const inner = try store.write(allocator, io, .{ .tree = .{ .entries = &inner_entries } });
    var outer_entries = [_]object.TreeEntry{.{ .mode = 0o040000, .name = "sub", .sha = inner }};
    const outer = try store.write(allocator, io, .{ .tree = .{ .entries = &outer_entries } });

    var map: FileMap = .init(allocator);
    defer freeMap(allocator, &map);
    try flattenTree(allocator, io, store, outer, "", &map);

    try testing.expect(map.get("sub/file.txt") != null);
    try testing.expect(std.mem.eql(u8, &map.get("sub/file.txt").?.sha, &blob_sha));
}
