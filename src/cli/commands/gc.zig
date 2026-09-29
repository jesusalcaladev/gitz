const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Fs = @import("../../util/fs.zig").Fs;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const storage_mod = @import("../../core/storage.zig");
const refs_mod = @import("../../core/refs.zig");
const index_mod = @import("../../core/index.zig");
const Repo = @import("../../core/repo.zig").Repo;

/// Guards the symref chase in `readRefTarget`. A self-referential ref
/// (`ref: HEAD` inside HEAD) would otherwise recurse until the stack blows.
const max_symref_depth = 8;

pub fn execute(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    // For a repository with no worktrees the three directories coincide, so
    // the existing path building below is unchanged. A linked worktree gets
    // the right directory per role from `repo`.
    _ = args;

    // This used to refuse to do anything at all when `objects/pack/` held a
    // packfile, because nothing could read one: every object reached from a
    // packed parent looked unreachable, so pruning would have deleted live
    // history. `core/pack_store.zig` now reads packs, and the traversal below
    // goes through `StorageBackend`, so reachability spans loose and packed
    // objects alike.
    //
    // Only loose objects are ever removed -- the sweep below walks the `xx`
    // fanout directories and nothing else -- so a pack is never rewritten or
    // deleted here.
    // `packed` is a Zig keyword, hence the name.
    const repo_has_packs = try hasPackedObjects(allocator, io, repo.common_dir);

    try io.print("Counting objects: ", .{});

    var reachable = std.AutoHashMap([20]u8, void).init(allocator);
    defer reachable.deinit();

    // `incomplete` is set whenever a reachable object could not be read. The
    // walk below then covers an unknown subset of the graph, so anything left
    // outside it may still be needed: pruning is abandoned entirely rather
    // than deleting objects we failed to prove unreachable.
    var incomplete = false;

    const refs_manager = refs_mod.Refs.init(repo);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);

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
    markPackedRefs(allocator, io, repo.common_dir, store, &reachable, &incomplete) catch {};

    // HEAD, ORIG_HEAD and MERGE_HEAD: a detached HEAD, an unfinished merge or
    // an undo-in-progress all keep commits alive that no ref mentions.
    //
    // These and the index are *per worktree*, so the pseudo-refs and the index
    // of every linked worktree are roots too. Reading only the current
    // worktree's meant `gitz gc` run from the main worktree deleted the objects
    // an agent's worktree still needed -- a detached worktree's commit and its
    // staged-but-uncommitted blobs are named by no ref at all.
    markWorktreeRoots(allocator, io, refs_manager, store, &reachable, &incomplete) catch {};

    if (incomplete) {
        try io.print("0, done.\n", .{});
        try io.print("Refusing to prune: some reachable objects could not be read.\n", .{});
        return;
    }

    var loose_count: u32 = 0;
    var freed_count: u32 = 0;
    const objects_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects", .{repo.common_dir});
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
    if (repo_has_packs and loose_count == 0) {
        try io.print("No loose objects to prune; history lives in a packfile.\n", .{});
    } else if (freed_count > 0) {
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

    const content = refs_manager.readRaw(allocator, io.io, refname) catch return null;
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

/// Files that pin objects in a worktree, besides its index.
///
/// `HEAD` and the pseudo-refs around it are named by no ref, and rebase keeps
/// the commit it started from in `rebase-merge/orig-head`. Missing any of them
/// lets `gc` delete a worktree's in-progress state.
const worktree_pseudo_refs = [_][]const u8{
    "HEAD",           "ORIG_HEAD",     "MERGE_HEAD",   "MERGE_AUTOSTASH",
    "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_HEAD",  "AUTO_MERGE",
    "FETCH_HEAD",
};

/// Add the roots of every linked worktree: its pseudo-refs, its index and its
/// rebase state. Without this, `gitz gc` from the main worktree deletes the
/// objects an agent's worktree still depends on.
fn markWorktreeRoots(
    allocator: std.mem.Allocator,
    io: Io,
    refs_manager: refs_mod.Refs,
    store: storage_mod.StorageBackend,
    reachable: *std.AutoHashMap([20]u8, void),
    incomplete: *bool,
) !void {
    // The main worktree's own pseudo-refs and index.
    for (worktree_pseudo_refs) |name| {
        const sha = readRefAt(allocator, io, refs_manager, refs_manager.repo.worktree_dir, name) catch continue;
        markReachable(allocator, io.io, store, reachable, sha, incomplete) catch {};
    }
    markIndex(allocator, io, refs_manager.repo.worktree_dir, store, reachable, incomplete) catch {};

    const wt_dir = refs_manager.worktreesDir(allocator) catch return;
    defer allocator.free(wt_dir);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    listWorktreeDirs(allocator, io.io, wt_dir, &names) catch return;

    for (names.items) |name| {
        const admin = refs_manager.worktreeAdminDir(allocator, name) catch continue;
        defer allocator.free(admin);

        // A worktree whose checkout is gone keeps its objects alive until
        // `gitz worktree prune` removes the admin directory. Honouring that
        // here is what makes prune meaningful; once pruned, the objects become
        // collectable on a later run.
        for (worktree_pseudo_refs) |ref| {
            const sha = readRefAt(allocator, io, refs_manager, admin, ref) catch continue;
            markReachable(allocator, io.io, store, reachable, sha, incomplete) catch {};
        }
        markIndex(allocator, io, admin, store, reachable, incomplete) catch {};

        // Rebase state: `orig-head` is the commit the rebase started from and
        // `onto` the base it is being replayed onto.
        for ([_][]const u8{ "rebase-merge/orig-head", "rebase-merge/onto", "rebase-apply/orig-head", "rebase-apply/onto" }) |rel| {
            const sha = readRefAt(allocator, io, refs_manager, admin, rel) catch continue;
            markReachable(allocator, io.io, store, reachable, sha, incomplete) catch {};
        }
    }
}

/// Read a SHA out of a file inside a worktree admin dir. Missing files are not
/// an error: a worktree that is not mid-merge simply has no MERGE_HEAD.
fn readRefAt(
    allocator: std.mem.Allocator,
    io: Io,
    refs_manager: refs_mod.Refs,
    dir: []const u8,
    name: []const u8,
) ![20]u8 {
    _ = refs_manager;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(path);

    const content = io.readFileAlloc(path) catch return error.RefNotFound;
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "ref: ")) return error.RefNotFound;
    if (trimmed.len < 40) return error.InvalidRef;
    return Sha1.fromHex(trimmed[0..40]);
}

/// List the worktree admin directories under `dir`.
fn listWorktreeDirs(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);

    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        try out.append(allocator, try allocator.dupe(u8, entry.name));
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
