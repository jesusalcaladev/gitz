const std = @import("std");
const testing = std.testing;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const object = @import("../../core/object.zig");
const loose_mod = @import("../../core/loose.zig");
const shard_mod = @import("../../core/shard_store.zig");
const alternates_mod = @import("../../core/alternates.zig");

// =============================================================================
// SDD/TDD — shared-object clone simulation.
//
// Git's "--shared"/"--local" clone is a scaling trick: instead of copying every
// object, the clone references the source repository's object store through
// `objects/info/alternates`. GitZ implements the same idea natively so a large
// canonical repo can back thousands of instant, near-zero-disk clones.
//
// These tests simulate the full flow:
//   1. build a real source repo (commit/tree/blobs, incl. a large >100KB blob)
//   2. simulate the shared clone: the clone has NO objects, only an alternates
//      pointer to the source object dir
//   3. assert objects are NOT duplicated locally (the scaling win)
//   4. assert objects resolve byte-for-byte identical through alternates
//   5. repeat with a SHARD backend source to prove backend-agnostic scaling
//
// This drives the SAME alternates mechanism the `gitz clone --shared` path uses
// (src/cli/commands/clone.zig → cloneShared → alternates), but without needing
// a network — a genuine simulation of the shared-object clone.
// =============================================================================

const GitObject = object.GitObject;

/// A named file descriptor so both the source-build helper and the tests share
/// one type (anonymous structs get distinct types in Zig).
const FileEntry = struct {
    name: []const u8,
    content: []const u8,
};

/// Deterministic incompressible buffer so zlib-compressed files exceed the
/// (removed) 100KB stack cap — this is what used to truncate large shared blobs.
fn fillRandom(allocator: std.mem.Allocator, n: usize, seed: u64) ![]u8 {
    const out = try allocator.alloc(u8, n);
    var rng = seed;
    for (out) |*b| {
        rng ^= rng >> 12;
        rng ^= rng << 25;
        rng ^= rng >> 27;
        b.* = @truncate(rng *% 0x2545F4914F6CDD1D);
    }
    return out;
}

/// Build a commit (with a tree containing `files`) into `store` using the core
/// object APIs. Mirrors what `gitz commit` writes on disk: blobs -> tree ->
/// commit, each stored as a loose zlib object. Returns the commit SHA.
fn buildCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *loose_mod.LooseStore,
    files: []const FileEntry,
) ![20]u8 {
    // 1) Write each blob.
    var entries: std.ArrayList(object.TreeEntry) = .empty;
    defer entries.deinit(allocator);
    var names: std.ArrayList([]u8) = .empty;
    defer names.deinit(allocator);
    for (files) |f| {
        const blob = GitObject{ .blob = .{ .content = f.content } };
        const blob_sha = try store.write(allocator, io, blob);
        const name = try allocator.dupe(u8, f.name);
        errdefer allocator.free(name);
        try names.append(allocator, name);
        try entries.append(allocator, .{ .mode = 0o100644, .name = name, .sha = blob_sha });
    }

    // 2) Write the tree (serializes the names; safe to free them afterwards).
    const tree_obj = GitObject{ .tree = .{ .entries = entries.items } };
    const tree_sha = try store.write(allocator, io, tree_obj);
    for (names.items) |n| allocator.free(n);

    // 3) Write the commit.
    const person = object.Person{ .name = "Alice", .email = "alice@example.com", .timestamp = 1710000000, .timezone = "+0000" };
    const commit_obj = GitObject{ .commit = .{
        .tree = tree_sha,
        .parents = &.{},
        .author = person,
        .committer = person,
        .message = "Initial shared clone test commit\n",
    } };
    return store.write(allocator, io, commit_obj);
}

/// Free the allocations owned by a tree *content* parsed from a loose object.
fn freeTree(allocator: std.mem.Allocator, tree: object.Tree) void {
    for (tree.entries) |e| allocator.free(e.name);
    allocator.free(tree.entries);
}

/// Free the allocations owned by a commit parsed from a loose object.
fn freeCommit(allocator: std.mem.Allocator, commit: object.Commit) void {
    allocator.free(commit.parents);
    allocator.free(commit.author.name);
    allocator.free(commit.author.email);
    allocator.free(commit.author.timezone);
    allocator.free(commit.committer.name);
    allocator.free(commit.committer.email);
    allocator.free(commit.committer.timezone);
    allocator.free(commit.message);
}

// =============================================================================
// 1) Loose-source shared clone simulation
// =============================================================================
test "shared clone simulation — loose source: dedup objects, correct checkout" {
    const allocator = testing.allocator;
    const io = testing.io;

    const root = "/tmp/gitz_shared_clone_loose";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    std.Io.Dir.cwd().createDirPath(io, root) catch {};

    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{root});
    defer allocator.free(src_dir);
    const clone_dir = try std.fmt.allocPrint(allocator, "{s}/clone", .{root});
    defer allocator.free(clone_dir);

    // (a) Build the source repository's object store with a real commit,
    //     including a large (>100KB, incompressible) blob.
    var store = loose_mod.LooseStore.init(src_dir);
    const large = try fillRandom(allocator, 300 * 1024, 0xC0FFEE);
    defer allocator.free(large);

    const files = [_]FileEntry{
        .{ .name = "hello.txt", .content = "shared hello world\n" },
        .{ .name = "notes.md", .content = "# Notes\nShared clone test.\n" },
        .{ .name = "big.bin", .content = large },
    };
    const head_sha = try buildCommit(allocator, io, &store, &files);

    // (b) Simulate the shared clone: the clone repo has NO objects locally,
    //     only an alternates pointer to the source object dir.
    std.Io.Dir.cwd().createDirPath(io, clone_dir) catch {};
    const alts = alternates_mod.Alternates.init(clone_dir);
    const src_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{src_dir});
    defer allocator.free(src_objects);
    try alts.write(allocator, io, &.{src_objects});

    // The clone's local store has ZERO objects (dedup / scaling win).
    const clone_store = loose_mod.LooseStore.init(clone_dir);
    try testing.expect(!clone_store.exists(io, head_sha));

    // (c) Walk commit -> tree -> blobs through the alternates and verify each
    //     shared object is byte-for-byte identical to what the source stored.
    const commit = try alts.readObject(allocator, io, head_sha);
    const tree_sha: [20]u8 = switch (commit) {
        .commit => |c| c.tree,
        else => return error.TestUnexpectedResult,
    };
    defer freeCommit(allocator, commit.commit);

    const tree_obj = try alts.readObject(allocator, io, tree_sha);
    const entries: []object.TreeEntry = switch (tree_obj) {
        .tree => |t| t.entries,
        else => return error.TestUnexpectedResult,
    };
    defer freeTree(allocator, tree_obj.tree);
    try testing.expectEqual(@as(usize, 3), entries.len);

    for (entries) |entry| {
        const blob_obj = try alts.readObject(allocator, io, entry.sha);
        defer switch (blob_obj) {
            .blob => |b| allocator.free(b.content),
            else => {},
        };
        const content = switch (blob_obj) {
            .blob => |b| b.content,
            else => return error.TestUnexpectedResult,
        };
        for (files) |f| {
            if (std.mem.eql(u8, f.name, entry.name)) {
                try testing.expectEqual(f.content.len, content.len);
                try testing.expectEqualSlices(u8, f.content, content);
            }
        }
    }
    // Re-read the alternates file: the clone is *just* a pointer to the source.
    const read_alts = try alts.read(allocator, io);
    defer {
        for (read_alts) |s| allocator.free(s);
        allocator.free(read_alts);
    }
    try testing.expectEqual(@as(usize, 1), read_alts.len);
    try testing.expectEqualStrings(src_objects, read_alts[0]);
}
// =============================================================================
// 2) Shard-source shared clone simulation (source uses the shard backend)
// =============================================================================
test "shared clone simulation — shard source resolves through alternates" {
    const allocator = testing.allocator;
    const io = testing.io;

    const root = "/tmp/gitz_shared_clone_shard";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    std.Io.Dir.cwd().createDirPath(io, root) catch {};

    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{root});
    defer allocator.free(src_dir);
    const clone_dir = try std.fmt.allocPrint(allocator, "{s}/clone", .{root});
    defer allocator.free(clone_dir);

    // Source uses the SHARD backend (different object layout on disk).
    var store = shard_mod.ShardStore.init(src_dir, 8);
    const large = try fillRandom(allocator, 250 * 1024, 0xFEED);
    defer allocator.free(large);

    const blob_obj = GitObject{ .blob = .{ .content = large } };
    const blob_sha = try store.write(allocator, io, blob_obj);

    // Clone points at the sharded source object dir.
    std.Io.Dir.cwd().createDirPath(io, clone_dir) catch {};
    const alts = alternates_mod.Alternates.init(clone_dir);
    const src_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{src_dir});
    defer allocator.free(src_objects);
    try alts.write(allocator, io, &.{src_objects});

    // The loose layout won't match (store is sharded at shard_NN/...), but the
    // shard-aware alternates resolve must find the full large blob intact.
    const read_obj = try alts.readObject(allocator, io, blob_sha);
    defer allocator.free(read_obj.blob.content);
    try testing.expectEqual(large.len, read_obj.blob.content.len);
    try testing.expectEqualSlices(u8, large, read_obj.blob.content);
}