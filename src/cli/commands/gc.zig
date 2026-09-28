const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Fs = @import("../../util/fs.zig").Fs;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const storage_mod = @import("../../core/storage.zig");
const refs_mod = @import("../../core/refs.zig");
const index_mod = @import("../../core/index.zig");

/// Guards the symref chase in `readRefTarget`. A self-referential ref
/// (`ref: HEAD` inside HEAD) would otherwise recurse until the stack blows.
const max_symref_depth = 8;

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    _ = args;

    // Packfiles are not readable yet: nothing in the tree knows how to resolve
    // an object out of objects/pack/, and gc does not write a .idx either. Any
    // commit whose tree is still loose would look unreachable while in fact
    // being reachable from a packed parent, so with packs present we must not
    // prune at all. See the note in `core/objectstore.zig` `gc`.
    if (try hasPackedObjects(allocator, io, git_dir)) {
        try io.print("Counting objects: skipped\n", .{});
        try io.print("Repository contains packfiles that cannot be read yet; refusing to prune loose objects.\n", .{});
        return;
    }

    try io.print("Counting objects: ", .{});

    var reachable = std.AutoHashMap([20]u8, void).init(allocator);
    defer reachable.deinit();

    // `incomplete` is set whenever a reachable object could not be read. The
    // walk below then covers an unknown subset of the graph, so anything left
    // outside it may still be needed: pruning is abandoned entirely rather
    // than deleting objects we failed to prove unreachable.
    var incomplete = false;

    const refs_manager = refs_mod.Refs.init(git_dir);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);

    // Roots: every ref in the repository. The previous implementation walked
    // only `heads` and `tags`, so `refs/stash`, `refs/remotes/*` and anything
    // else had all of their objects pruned away.
    const all_refs = try refs_manager.listAll(allocator, io.io);
    defer freeRefList(allocator, all_refs);

    for (all_refs) |ref| {
        const target = readRefTarget(allocator, io, refs_manager, ref, 0) catch null;
        const sha = target orelse continue;
        markReachable(allocator, io.io, store, &reachable, sha, &incomplete) catch {};
    }

    // packed-refs: a real git repository (gitz now accepts a .git directory)
    // may keep every ref there instead of as loose files.
    markPackedRefs(allocator, io, git_dir, store, &reachable, &incomplete) catch {};

    // HEAD, ORIG_HEAD and MERGE_HEAD: a detached HEAD, an unfinished merge or
    // an undo-in-progress all keep commits alive that no ref mentions.
    const pseudo_refs = [_][]const u8{ "HEAD", "ORIG_HEAD", "MERGE_HEAD" };
    for (pseudo_refs) |name| {
        const target = readRefTarget(allocator, io, refs_manager, name, 0) catch null;
        const sha = target orelse continue;
        markReachable(allocator, io.io, store, &reachable, sha, &incomplete) catch {};
    }

    // The index: `gitz add` writes the blob immediately, so a staged but
    // uncommitted object is reachable only from the index. Pruning it produced
    // commits pointing at blobs that did not exist.
    markIndex(allocator, io, git_dir, store, &reachable, &incomplete) catch {};

    if (incomplete) {
        try io.print("0, done.\n", .{});
        try io.print("Refusing to prune: some reachable objects could not be read.\n", .{});
        return;
    }

    var loose_count: u32 = 0;
    var freed_count: u32 = 0;
    const objects_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir});
    defer allocator.free(objects_dir_path);

    for (0..256) |hi| {
        var dir_name_buf: [3]u8 = undefined;
        dir_name_buf[0] = "0123456789abcdef"[hi >> 4];
        dir_name_buf[1] = "0123456789abcdef"[hi & 0x0f];
        dir_name_buf[2] = 0;

        // `objects_dir_path` already ends in `/objects`; appending it again
        // built `.gitz/objects/objects/xx`, so no fanout dir ever opened and
        // every repository reported "Counting objects: 0".
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir_path, dir_name_buf[0..2] });
        defer allocator.free(dir_path);

        var dir = Fs.openIterable(io.io, dir_path) catch continue;
        defer dir.close(io.io);

        var iter = dir.iterate();
        while (iter.next(io.io) catch null) |entry| {
            if (entry.kind != .file) continue;

            loose_count += 1;

            // A loose object is named by the remaining 38 hex digits. Without
            // this check a stray file of any other length was memcpy'd into a
            // 40-byte stack buffer.
            if (entry.name.len != 38) continue;
            if (!isHexName(entry.name)) continue;

            var full_hex: [40]u8 = undefined;
            full_hex[0] = dir_name_buf[0];
            full_hex[1] = dir_name_buf[1];
            @memcpy(full_hex[2..40], entry.name);

            const sha = Sha1.fromHex(&full_hex) catch continue;

            if (!reachable.contains(sha)) {
                const obj_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
                defer allocator.free(obj_path);
                std.Io.Dir.cwd().deleteFile(io.io, obj_path) catch {};
                freed_count += 1;
            }
        }
    }

    try io.print("{d}, done.\n", .{loose_count});
    if (freed_count > 0) {
        try io.print("Pruning {d} unreachable objects\n", .{freed_count});
    } else {
        try io.print("No unreachable objects to prune.\n", .{});
    }
}

fn isHexName(name: []const u8) bool {
    for (name) |c| {
        const is_digit = c >= '0' and c <= '9';
        const is_lower = c >= 'a' and c <= 'f';
        if (!is_digit and !is_lower) return false;
    }
    return true;
}

fn freeRefList(allocator: std.mem.Allocator, refs: []const []const u8) void {
    for (refs) |r| allocator.free(r);
    allocator.free(refs);
}

/// Whether `objects/pack` holds any packfile.
fn hasPackedObjects(allocator: std.mem.Allocator, io: Io, git_dir: []const u8) !bool {
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);

    var dir = Fs.openIterable(io.io, pack_dir) catch return false;
    defer dir.close(io.io);

    var iter = dir.iterate();
    while (iter.next(io.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".pack")) return true;
    }
    return false;
}

/// Resolve a ref to the object it points at, following symbolic refs.
///
/// A ref file holds either 40 hex digits, `ref: <target>`, or — for the
/// `refs/stash` file gitz writes — `<sha> <message>`. All three are accepted
/// so that no ref is silently skipped.
fn readRefTarget(
    allocator: std.mem.Allocator,
    io: Io,
    refs_manager: refs_mod.Refs,
    refname: []const u8,
    depth: usize,
) !?[20]u8 {
    if (depth > max_symref_depth) return null;

    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ refs_manager.git_dir, refname });
    defer allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(io.io, path, allocator, .unlimited) catch return null;
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, &[_]u8{ '\n', '\r', ' ', '\t' });
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const target = std.mem.trim(u8, trimmed[5..], &[_]u8{ '\n', '\r', ' ', '\t' });
        return readRefTarget(allocator, io, refs_manager, target, depth + 1) catch null;
    }

    // `<sha> <rest>` (stash) or a bare `<sha>` (plain ref).
    var token = trimmed;
    if (std.mem.indexOfAny(u8, trimmed, " \t")) |sp| token = trimmed[0..sp];
    if (token.len != 40) return null;

    const sha = Sha1.fromHex(token) catch return null;
    return sha;
}

/// Add every SHA in `packed-refs` to the roots.
fn markPackedRefs(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: []const u8,
    store: storage_mod.StorageBackend,
    reachable: *std.AutoHashMap([20]u8, void),
    incomplete: *bool,
) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(io.io, path, allocator, .unlimited) catch return;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &[_]u8{ ' ', '\t', '\r' });
        if (line.len == 0) continue;
        // `#` header, and `^<sha>` peeled annotated tag lines.
        if (line[0] == '#' or line[0] == '^') continue;

        var token = line;
        if (std.mem.indexOfScalar(u8, line, ' ')) |sp| token = line[0..sp];
        if (token.len != 40) continue;

        const sha = Sha1.fromHex(token) catch continue;
        markReachable(allocator, io.io, store, reachable, sha, incomplete) catch {};
    }
}

/// Add every object recorded in the index to the roots.
fn markIndex(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: []const u8,
    store: storage_mod.StorageBackend,
    reachable: *std.AutoHashMap([20]u8, void),
    incomplete: *bool,
) !void {
    var idx = index_mod.Index.readFromFile(allocator, git_dir, io.io) catch return;
    defer idx.deinit(allocator);

    for (idx.entries.items) |entry| {
        markReachable(allocator, io.io, store, reachable, entry.sha, incomplete) catch {};
    }
}

/// Walk the object graph from `sha`.
///
/// A failed read no longer aborts the whole walk: it sets `incomplete` so the
/// caller knows the reachable set is a lower bound, and returns. Aborting used
/// to make every object below the unreadable one look unreachable.
fn markReachable(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage_mod.StorageBackend,
    reachable: *std.AutoHashMap([20]u8, void),
    sha: [20]u8,
    incomplete: *bool,
) !void {
    if (reachable.contains(sha)) return;
    reachable.put(sha, {}) catch {
        incomplete.* = true;
        return;
    };

    const obj = store.read(allocator, io, sha) catch {
        incomplete.* = true;
        return;
    };
    defer obj.deinit(allocator);

    switch (obj) {
        .commit => |commit| {
            for (commit.parents) |parent| {
                try markReachable(allocator, io, store, reachable, parent, incomplete);
            }
            try markReachable(allocator, io, store, reachable, commit.tree, incomplete);
        },
        .tree => |tree| {
            for (tree.entries) |entry| {
                try markReachable(allocator, io, store, reachable, entry.sha, incomplete);
            }
        },
        .blob => {},
        .tag => |tag| {
            try markReachable(allocator, io, store, reachable, tag.object, incomplete);
        },
    }
}
