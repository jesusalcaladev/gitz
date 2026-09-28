const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const loose = @import("../../core/loose.zig");
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const checkout_mod = @import("../../core/checkout.zig");
const index_mod = @import("../../core/index.zig");
const config_cmd = @import("config.zig");
const errors = @import("../errors.zig");
const Repo = @import("../../core/repo.zig").Repo;

pub fn execute(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    // For a repository with no worktrees the three directories coincide, so
    // the existing path building below is unchanged. A linked worktree gets
    // the right directory per role from `repo`.
    var abort_mode = false;
    var interactive = false;
    var continue_mode = false;
    var upstream: ?[]const u8 = null;
    var onto: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--abort")) {
            abort_mode = true;
        } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c")) {
            continue_mode = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, arg, "--onto") and i + 1 < args.len) {
            i += 1;
            onto = args[i];
        } else if (std.mem.eql(u8, arg, "--autostash") or std.mem.eql(u8, arg, "-q") or
            std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--no-autostash"))
        {
            // Accepted; there is no autostash to perform.
        } else if (std.mem.startsWith(u8, arg, "-")) {
            errors.errorf(io, "unknown option '{s}'", .{arg});
        } else {
            if (upstream == null) upstream = arg;
        }
    }

    if (abort_mode) {
        try abortRebase(allocator, repo.worktree_dir, io);
        return;
    }
    if (continue_mode) {
        // Previously always reported "No rebase in progress", so a conflicted
        // rebase could never be finished.
        try continueRebase(allocator, repo, io);
        return;
    }

    const branch = upstream orelse {
        try io.eprint("usage: gitz rebase [-i] [--abort] [--onto <base>] <upstream>\n", .{});
        std.process.exit(1);
    };

    const refs_manager = refs_mod.Refs.init(repo);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);

    var head_info = refs_manager.head(allocator, io.io) catch {
        try io.eprint("fatal: not a gitz repository\n", .{});
        return;
    };
    defer head_info.deinit(allocator);

    const current_sha: [20]u8 = switch (head_info) {
        .branch => |b| b.sha,
        .detached => |d| d.sha,
        // There is nothing to replay on a branch with no commits.
        .unborn => {
            try io.eprint("fatal: no commits to rebase\n", .{});
            std.process.exit(128);
        },
    };

    const upstream_sha = resolveRef(allocator, io.io, refs_manager, store, branch) catch {
        try io.eprint("error: branch '{s}' not found\n", .{branch});
        std.process.exit(1);
    };

    // An unresolvable --onto used to fall back to the upstream, so the command
    // rebased onto something other than what was asked for and said nothing.
    const onto_sha = if (onto) |o|
        resolveRef(allocator, io.io, refs_manager, store, o) catch |err| switch (err) {
            error.RefNotFound, error.InvalidRef => errors.errorf(io, "invalid upstream '{s}'", .{o}),
            else => return err,
        }
    else
        upstream_sha;

    if (std.mem.eql(u8, &current_sha, &onto_sha)) {
        try io.print("Already up to date.\n", .{});
        return;
    }

    // Collect commits to replay
    var shas_to_replay = std.ArrayList([20]u8){ .items = &.{}, .capacity = 0 };
    defer shas_to_replay.deinit(allocator);
    var commits_to_replay = std.ArrayList(object.Commit){ .items = &.{}, .capacity = 0 };
    defer commits_to_replay.deinit(allocator);

    // The commits to replay are those reachable from HEAD but not from the new
    // base, which is what the merge base marks. Walking until the walk *hits*
    // the new base only works when HEAD already contains it, so a rebase of a
    // branch onto a sibling replayed the entire history: main's own base commit
    // was duplicated and the upstream's commits were left as ancestors instead
    // of becoming the new foundation.
    const fork_point = mergeBase(allocator, io, store, onto_sha, current_sha) orelse onto_sha;

    if (isAncestorOf(allocator, io, store, current_sha, onto_sha)) {
        try io.print("Current branch {s} is up to date.\n", .{(head_info.branchOf() orelse "HEAD")});
        return;
    }

    var cur = current_sha;
    while (true) {
        if (std.mem.eql(u8, &cur, &fork_point)) break;
        const obj = store.read(allocator, io.io, cur) catch break;
        const commit = switch (obj) {
            .commit => |c| c,
            else => break,
        };
        const parents_copy = try allocator.alloc([20]u8, commit.parents.len);
        @memcpy(parents_copy, commit.parents);
        try shas_to_replay.append(allocator, cur);
        try commits_to_replay.append(allocator, .{
            .tree = commit.tree,
            .parents = parents_copy,
            .author = commit.author,
            .committer = commit.committer,
            .message = commit.message,
        });
        if (commit.parents.len == 0) break;
        cur = commit.parents[0];
    }

    if (commits_to_replay.items.len == 0) {
        try io.print("Nothing to do.\n", .{});
        return;
    }

    if (interactive) {
        try interactiveRebase(allocator, repo, io, store, &refs_manager, &shas_to_replay, &commits_to_replay, onto_sha, &head_info);
        return;
    }

    try replayCommits(allocator, repo, io, store, &refs_manager, &commits_to_replay, onto_sha, &head_info);
    try io.print("Successfully rebased and updated refs/heads/{s}.\n", .{switch (head_info) {
        .branch => |b| b.name.items,
        .unborn => |u| u.name.items,
        .detached => "(detached)",
    }});
}

/// Replay each commit onto the new base, re-applying its diff.
///
/// The old implementation copied each commit's *tree* verbatim, so a rebase
/// silently dropped everything the upstream had changed: replaying a commit
/// whose parent had been rewritten produced a tree identical to the old one,
/// and the upstream's work vanished from the branch. The working tree was never
/// updated either, so HEAD and the worktree disagreed.
///
/// The replay is a three-way merge of (old parent, old commit, new base) for
/// every path, which is what a rebase is.
fn replayCommits(
    allocator: std.mem.Allocator,
    repo: Repo,
    io: Io,
    store: storage_mod.StorageBackend,
    refs_manager: *const refs_mod.Refs,
    commits: *std.ArrayList(object.Commit),
    new_base: [20]u8,
    head_info: *const refs_mod.HeadInfo,
) !void {
    const Rebased = struct { sha: [20]u8, conflicted: bool };

    var current_parent = new_base;
    var applied = std.ArrayList(Rebased).empty;
    defer applied.deinit(allocator);

    var i: usize = commits.items.len;
    while (i > 0) {
        i -= 1;
        const commit = commits.items[i];

        // The tree this replay produces: start from the new base and apply the
        // changes the original commit made to its own parent.
        const original_parent_tree: ?[20]u8 = if (commit.parents.len > 0)
            treeOfCommit(allocator, io, store, commit.parents[0])
        else
            null;

        var result = try replayOne(
            allocator,
            io,
            store,
            original_parent_tree,
            commit.tree,
            current_parent,
        );
        defer {
            for (result.conflicts) |c| {
                allocator.free(c.path);
                allocator.free(c.content);
            }
            allocator.free(result.conflicts);
            result.index.deinit(allocator);
        }

        var parents_buf: [1][20]u8 = .{current_parent};
        const now_ts = std.Io.Timestamp.now(io.io, .real);
        const now: i64 = @intCast(@divTrunc(now_ts.nanoseconds, std.time.ns_per_s));

        const committer_name = config_cmd.getUserName(allocator, repo.common_dir, io);
        defer if (!std.mem.eql(u8, committer_name, "GitZ User")) allocator.free(committer_name);
        const committer_email = config_cmd.getUserEmail(allocator, repo.common_dir, io);
        defer if (!std.mem.eql(u8, committer_email, "user@gitz.dev")) allocator.free(committer_email);

        // The author and date of the original commit are preserved; the
        // committer is whoever ran the rebase, as in git.
        const new_commit = object.Commit{
            .tree = result.tree,
            .parents = parents_buf[0..1],
            .author = commit.author,
            .committer = .{ .name = committer_name, .email = committer_email, .timestamp = now, .timezone = "+0000" },
            .message = commit.message,
        };

        const sha = try store.write(allocator, io.io, object.GitObject{ .commit = new_commit });
        current_parent = sha;

        try applied.append(allocator, .{ .sha = sha, .conflicted = result.conflicts.len > 0 });

        if (result.conflicts.len > 0) {
            // Stop where git stops, with the state on disk so `--continue` and
            // `--abort` work. Previously the conflict was never noticed and the
            // rebased branch was written as if it were clean.
            try writeRebaseState(allocator, repo.worktree_dir, io, new_base, current_parent, i);
            // The index keeps the conflict stages, so `status` reports the path
            // as unmerged and `--continue` refuses until the user resolves it.
            // The branch ref is left alone until the rebase finishes.
            try result.index.writeToFile(repo.worktree_dir, allocator, io.io);
            for (result.conflicts) |c| {
                try io.eprint("CONFLICT (content): Merge conflict in {s}\n", .{c.path});
                if (std.fs.path.dirname(c.path)) |dir| {
                    std.Io.Dir.cwd().createDirPath(io.io, dir) catch {};
                }
                var wf = std.Io.Dir.cwd().createFile(io.io, c.path, .{}) catch continue;
                defer wf.close(io.io);
                std.Io.File.writeStreamingAll(wf, io.io, c.content) catch {};
            }
            errors.exitWith(io, errors.ExitFailure, "Could not apply commit; stopped at {s}. Resolve and run 'gitz rebase --continue'.", .{commit.message});
        }
    }

    // The worktree is brought to the new tip; without this HEAD and the working
    // tree disagreed after every rebase.
    checkout_mod.checkoutCommit(allocator, repo, io.io, store, current_parent) catch
        errors.fatal(io, "could not check out the rebased tree", .{});

    switch (head_info.*) {
        .branch => |b| {
            const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{b.name.items});
            defer allocator.free(ref_name);
            try refs_manager.write(allocator, io.io, ref_name, current_parent);
        },
        .unborn => |u| {
            const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{u.name.items});
            defer allocator.free(ref_name);
            try refs_manager.write(allocator, io.io, ref_name, current_parent);
        },
        .detached => {
            const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{repo.worktree_dir});
            defer allocator.free(head_path);
            var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
            defer hf.close(io.io);
            const hex = Sha1.hex(current_parent);
            var wbuf: [42]u8 = undefined;
            const wline = try std.fmt.bufPrint(&wbuf, "{s}\n", .{&hex});
            try std.Io.File.writeStreamingAll(hf, io.io, wline);
        },
    }
}

/// One conflicted path produced while replaying a commit.
pub const RebaseConflict = struct {
    path: []const u8,
    /// Conflict-marker text to write to the working tree.
    content: []const u8,
};

const ReplayResult = struct {
    tree: [20]u8,
    conflicts: []RebaseConflict,
    /// The index the replay produced, including the conflict stages.
    index: index_mod.Index,
};

const tree_merge_mod = @import("../../core/tree_merge.zig");

/// Apply the difference between `old_parent` and `old_commit` on top of
/// `new_base`, path by path.
fn replayOne(
    allocator: std.mem.Allocator,
    io: Io,
    store: storage_mod.StorageBackend,
    old_parent: ?[20]u8,
    old_commit: [20]u8,
    new_base: [20]u8,
) !ReplayResult {
    var base_files = checkout_mod.FileMap.init(allocator);
    defer checkout_mod.freeMap(allocator, &base_files);
    var from_files = checkout_mod.FileMap.init(allocator);
    defer checkout_mod.freeMap(allocator, &from_files);
    var onto_files = checkout_mod.FileMap.init(allocator);
    defer checkout_mod.freeMap(allocator, &onto_files);

    if (old_parent) |p| {
        checkout_mod.flattenTree(allocator, io.io, store, p, "", &base_files) catch {};
    }
    // `old_commit` is already a tree SHA; only `new_base` is a commit.
    checkout_mod.flattenTree(allocator, io.io, store, old_commit, "", &from_files) catch {};
    // `new_base` is a commit, so its tree has to be resolved first: passing the
    // commit SHA made the flatten fail silently and every replay started from
    // an empty base, which silently dropped the upstream's files.
    if (treeOfCommit(allocator, io, store, new_base)) |t| {
        checkout_mod.flattenTree(allocator, io.io, store, t, "", &onto_files) catch {};
    }

    // Ownership of the index transfers to the caller, which writes it out and
    // frees it. Deinitialising it here would leave the returned entry names
    // dangling, so the conflict stages never reached the file.
    var idx = index_mod.Index.init(allocator);

    // The new base is the starting point.
    var it = onto_files.iterator();
    while (it.next()) |entry| {
        try idx.add(allocator, entry.key_ptr.*, entry.value_ptr.sha, .{ .mode = entry.value_ptr.mode });
    }

    // Every path the original commit touched.
    var touched = std.StringHashMap(void).init(allocator);
    defer touched.deinit();
    {
        var a = from_files.iterator();
        while (a.next()) |e| {
            if (base_files.get(e.key_ptr.*) == null) try touched.put(e.key_ptr.*, {});
        }
        var b = base_files.iterator();
        while (b.next()) |e| {
            if (from_files.get(e.key_ptr.*) == null) try touched.put(e.key_ptr.*, {});
            // A changed blob also counts.
            const after = from_files.get(e.key_ptr.*) orelse continue;
            if (!std.mem.eql(u8, &after.sha, &e.value_ptr.sha)) try touched.put(e.key_ptr.*, {});
        }
    }

    var conflicts = std.ArrayList(RebaseConflict).empty;
    defer {
        for (conflicts.items) |c| {
            allocator.free(c.path);
            allocator.free(c.content);
        }
        conflicts.deinit(allocator);
    }

    // Stage the three sides of a conflicted path, so `status` reports it as
    // unmerged and `--continue` refuses until it is resolved. Without this the
    // index looked clean and `rebase --continue` accepted the markers as a
    // resolution without the user ever touching them.
    const stageConflict = struct {
        fn run(
            gpa: std.mem.Allocator,
            ix: *index_mod.Index,
            path: []const u8,
            mode: u32,
            base: ?[20]u8,
            ours: [20]u8,
            theirs: [20]u8,
        ) !void {
            if (base) |b| try ix.add(gpa, path, b, .{ .mode = mode, .stage = .base });
            try ix.add(gpa, path, ours, .{ .mode = mode, .stage = .ours });
            try ix.add(gpa, path, theirs, .{ .mode = mode, .stage = .theirs });
        }
    }.run;

    // Marker text for a path, so the user can see both sides.
    const conflictMarkers = struct {
        fn make(
            gpa: std.mem.Allocator,
            st: storage_mod.StorageBackend,
            raw_io: std.Io,
            base: ?[20]u8,
            ours: [20]u8,
            theirs: [20]u8,
        ) ![]const u8 {
            const merged = tree_merge_mod.mergeText(gpa, raw_io, st, base, ours, theirs, "rebase") catch return "";
            defer if (merged.content) |c| gpa.free(c);
            return gpa.dupe(u8, merged.content orelse "") catch "";
        }
    }.make;

    var t = touched.keyIterator();
    while (t.next()) |key| {
        const path = key.*;
        const before = base_files.get(path);
        const after = from_files.get(path);
        const onto = onto_files.get(path);

        if (after == null) {
            // Deleted by the commit: delete it on the new base too.
            if (onto != null and (before == null or std.mem.eql(u8, &before.?.sha, &onto.?.sha))) {
                _ = idx.remove(allocator, path);
            } else if (onto != null and after != null) {
                // The new base has its own content for this path; deleting it
                // would drop the upstream's work, so it is a conflict.
                try stageConflict(
                    allocator,
                    &idx,
                    path,
                    onto.?.mode,
                    if (before) |b| b.sha else null,
                    onto.?.sha,
                    after.?.sha,
                );
                try conflicts.append(allocator, .{
                    .path = try allocator.dupe(u8, path),
                    .content = try conflictMarkers(allocator, store, io.io, if (before) |b| b.sha else null, onto.?.sha, after.?.sha),
                });
            }
            continue;
        }

        const new_sha = after.?.sha;

        if (onto == null) {
            // Added by the commit and absent from the new base.
            try idx.add(allocator, path, new_sha, .{ .mode = after.?.mode });
            continue;
        }
        if (std.mem.eql(u8, &onto.?.sha, &new_sha)) continue; // nothing to do

        const upstream_changed = before != null and
            !std.mem.eql(u8, &before.?.sha, &onto.?.sha);
        if (before == null) {
            // Added on both sides with different content: conflict.
            try stageConflict(allocator, &idx, path, onto.?.mode, null, onto.?.sha, new_sha);
            try conflicts.append(allocator, .{
                .path = try allocator.dupe(u8, path),
                .content = try conflictMarkers(allocator, store, io.io, null, onto.?.sha, new_sha),
            });
            continue;
        }
        if (upstream_changed) {
            // Both sides changed the file since the base: three-way the content.
            const merged = tree_merge_mod.mergeText(allocator, io.io, store, before.?.sha, onto.?.sha, new_sha, "rebase") catch null;
            if (merged) |m| {
                defer if (m.content) |c| allocator.free(c);
                if (m.conflict) {
                    try stageConflict(allocator, &idx, path, onto.?.mode, before.?.sha, onto.?.sha, new_sha);
                    try conflicts.append(allocator, .{
                        .path = try allocator.dupe(u8, path),
                        .content = try allocator.dupe(u8, m.content orelse ""),
                    });
                } else if (m.content) |c| {
                    const sha = try store.write(allocator, io.io, .{ .blob = .{ .content = c } });
                    try idx.add(allocator, path, sha, .{ .mode = after.?.mode });
                } else {
                    try idx.add(allocator, path, new_sha, .{ .mode = after.?.mode });
                }
            } else {
                try idx.add(allocator, path, new_sha, .{ .mode = after.?.mode });
            }
            continue;
        }

        // Only the commit changed this path: take its version.
        try idx.add(allocator, path, new_sha, .{ .mode = after.?.mode });
    }

    // A tree cannot hold the three stages of a conflict, so on a conflict the
    // tree is not written: the caller stops and the index is what the user
    // resolves against.
    const tree_sha: [20]u8 = if (conflicts.items.len == 0)
        try idx.writeTree(store, allocator, io.io)
    else
        currentTreeOf(allocator, io, store, new_base) orelse [_]u8{0} ** 20;

    return .{
        .tree = tree_sha,
        .conflicts = try conflicts.toOwnedSlice(allocator),
        .index = idx,
    };
}

/// The best common ancestor of two commits.
fn mergeBase(
    allocator: std.mem.Allocator,
    io: Io,
    store: storage_mod.StorageBackend,
    a: [20]u8,
    b: [20]u8,
) ?[20]u8 {
    var a_map = reachableSet(allocator, io, store, a) orelse return null;
    defer a_map.deinit();

    // Breadth-first from `b`: the first commit also reachable from `a` is a
    // merge base, and for the linear histories a rebase deals with it is the
    // best one.
    var queue = std.ArrayList([20]u8).empty;
    defer queue.deinit(allocator);
    var seen = std.AutoHashMap([20]u8, void).init(allocator);
    defer seen.deinit();

    queue.append(allocator, b) catch return null;
    seen.put(b, {}) catch return null;

    var steps: usize = 0;
    while (queue.items.len > 0 and steps < 1_000_000) : (steps += 1) {
        const sha = queue.orderedRemove(0);
        if (a_map.contains(sha)) return sha;

        const obj = store.read(allocator, io.io, sha) catch continue;
        defer obj.deinit(allocator);
        const commit = switch (obj) {
            .commit => |c| c,
            else => continue,
        };
        for (commit.parents) |p| {
            if (seen.contains(p)) continue;
            seen.put(p, {}) catch continue;
            queue.append(allocator, p) catch {};
        }
    }
    return null;
}

fn reachableSet(allocator: std.mem.Allocator, io: Io, store: storage_mod.StorageBackend, sha: [20]u8) ?std.AutoHashMap([20]u8, void) {
    var set = std.AutoHashMap([20]u8, void).init(allocator);
    var queue = std.ArrayList([20]u8).empty;
    defer queue.deinit(allocator);

    queue.append(allocator, sha) catch return null;
    set.put(sha, {}) catch return null;

    var steps: usize = 0;
    while (queue.items.len > 0 and steps < 1_000_000) : (steps += 1) {
        const cur = queue.orderedRemove(0);
        const obj = store.read(allocator, io.io, cur) catch continue;
        defer obj.deinit(allocator);
        const commit = switch (obj) {
            .commit => |c| c,
            else => continue,
        };
        if (set.contains(commit.tree)) continue;
        set.put(commit.tree, {}) catch {};
        for (commit.parents) |p| {
            if (set.contains(p)) continue;
            set.put(p, {}) catch continue;
            queue.append(allocator, p) catch {};
        }
    }
    return set;
}

/// Whether `candidate` is reachable from `from`.
fn isAncestorOf(allocator: std.mem.Allocator, io: Io, store: storage_mod.StorageBackend, from: [20]u8, candidate: [20]u8) bool {
    var seen = std.AutoHashMap([20]u8, void).init(allocator);
    defer seen.deinit();

    var queue = std.ArrayList([20]u8).empty;
    defer queue.deinit(allocator);

    queue.append(allocator, from) catch return false;
    seen.put(from, {}) catch return false;

    var steps: usize = 0;
    while (queue.items.len > 0 and steps < 1_000_000) : (steps += 1) {
        const sha = queue.orderedRemove(0);
        if (std.mem.eql(u8, &sha, &candidate)) return true;
        if (seen.contains(sha)) continue;
        seen.put(sha, {}) catch continue;

        const obj = store.read(allocator, io.io, sha) catch continue;
        defer obj.deinit(allocator);
        const commit = switch (obj) {
            .commit => |c| c,
            else => continue,
        };
        for (commit.parents) |p| queue.append(allocator, p) catch {};
    }
    return false;
}

/// The tree a commit already points at.
fn currentTreeOf(allocator: std.mem.Allocator, io: Io, store: storage_mod.StorageBackend, commit: [20]u8) ?[20]u8 {
    return treeOfCommit(allocator, io, store, commit);
}

fn treeOfCommit(allocator: std.mem.Allocator, io: Io, store: storage_mod.StorageBackend, sha: [20]u8) ?[20]u8 {
    const obj = store.read(allocator, io.io, sha) catch return null;
    defer obj.deinit(allocator);
    const commit = switch (obj) {
        .commit => |c| c,
        else => return null,
    };
    return commit.tree;
}

/// Persist the state `--continue` and `--abort` need.
fn writeRebaseState(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: Io,
    onto: [20]u8,
    head: [20]u8,
    remaining_from: usize,
) !void {
    const dir = try std.fmt.allocPrint(allocator, "{s}/rebase-merge", .{git_dir});
    defer allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(io.io, dir) catch {};

    const files = [_]struct { name: []const u8, value: [20]u8 }{
        .{ .name = "onto", .value = onto },
        .{ .name = "orig-head", .value = head },
    };
    for (files) |f| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, f.name });
        defer allocator.free(path);
        const hex = Sha1.hex(f.value);
        try io.writeFile(path, hex[0..]);
    }

    const done_path = try std.fmt.allocPrint(allocator, "{s}/done", .{dir});
    defer allocator.free(done_path);
    const done = try std.fmt.allocPrint(allocator, "{d}\n", .{remaining_from});
    defer allocator.free(done);
    try io.writeFile(done_path, done);
}

/// Interactive rebase TUI with arrow key navigation
fn interactiveRebase(
    allocator: std.mem.Allocator,
    repo: Repo,
    io: Io,
    store: storage_mod.StorageBackend,
    refs_manager: *const refs_mod.Refs,
    shas: *std.ArrayList([20]u8),
    commits: *std.ArrayList(object.Commit),
    onto: [20]u8,
    head_info: *const refs_mod.HeadInfo,
) !void {
    const Action = enum { pick, squash, reword, edit, drop };

    const n = commits.items.len;
    var actions = try allocator.alloc(Action, n);
    defer allocator.free(actions);
    for (actions) |*a| a.* = .pick;

    // Clear screen
    try io.print("\x1b[2J\x1b[H", .{});
    try io.print("\x1b[1;36m=== Interactive Rebase ===\x1b[0m onto \x1b[1;33m{s}\x1b[0m\n\n", .{Sha1.hex(onto)[0..7]});
    try io.print("\x1b[2m[p]ick  [s]quash  [r]eword  [e]dit  [d]rop | [j/k] nav | [Enter] confirm | [q] abort\x1b[0m\n\n", .{});

    var cursor: usize = 0;

    // Main loop
    while (true) {
        // Move cursor to list area and redraw
        try io.print("\x1b[5;1H", .{});

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const display_idx = n - 1 - i; // newest first
            const commit = commits.items[display_idx];
            const sha = shas.items[display_idx];
            const hex = Sha1.hex(sha);
            var msg_lines = std.mem.splitScalar(u8, commit.message, '\n');
            const first_line = msg_lines.next() orelse "";

            const action_str = switch (actions[display_idx]) {
                .pick => "pick   ",
                .squash => "squash ",
                .reword => "reword ",
                .edit => "edit   ",
                .drop => "drop   ",
            };

            // Cursor indicator + colored action
            if (display_idx == cursor) {
                try io.print("\x1b[1;7m> {s}\x1b[0m {s} {s}\x1b[0m\n", .{ action_str, hex[0..7], first_line });
            } else {
                try io.print("  {s} {s} {s}\n", .{ action_str, hex[0..7], first_line });
            }
        }

        // Read one byte from stdin
        var stdin = std.Io.File.stdin();
        var input_buf: [1]u8 = undefined;
        const n_read = stdin.readStreaming(io.io, &.{&input_buf}) catch 0;
        if (n_read == 0) break;

        const c = input_buf[0];
        if (c == 'q' or c == 0x1b) {
            try io.print("\x1b[2J\x1b[H", .{});
            try io.print("Rebase aborted.\n", .{});
            return;
        }
        if (c == '\n' or c == '\r') break;
        if (c == 'j' or c == 'B') { // down
            if (cursor > 0) cursor -= 1;
        } else if (c == 'k' or c == 'A') { // up
            if (cursor < n - 1) cursor += 1;
        } else {
            actions[cursor] = switch (c) {
                'p' => .pick,
                's' => .squash,
                'r' => .reword,
                'e' => .edit,
                'd' => .drop,
                else => actions[cursor],
            };
        }
    }

    try io.print("\x1b[2J\x1b[H", .{});

    // Execute rebase based on actions (oldest first = index n-1 down to 0)
    var current_parent = onto;
    var rebased: u32 = 0;
    var dropped: u32 = 0;

    var ri: usize = n;
    while (ri > 0) {
        ri -= 1;
        const action = actions[ri];
        const commit = commits.items[ri];

        if (action == .drop) {
            dropped += 1;
            continue;
        }

        var parents_buf: [1][20]u8 = .{current_parent};
        const parents = parents_buf[0..1];
        const now_ts = std.Io.Timestamp.now(io.io, .real);
        const now: i64 = @intCast(@divTrunc(now_ts.nanoseconds, std.time.ns_per_s));

        const new_commit = object.Commit{
            .tree = commit.tree,
            .parents = parents,
            .author = commit.author,
            .committer = .{ .name = "GitZ User", .email = "user@gitz.dev", .timestamp = now, .timezone = "+0000" },
            .message = commit.message,
        };
        current_parent = try store.write(allocator, io.io, object.GitObject{ .commit = new_commit });
        rebased += 1;
    }

    switch (head_info.*) {
        .branch => |b| {
            const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{b.name.items});
            defer allocator.free(ref_name);
            try refs_manager.write(allocator, io.io, ref_name, current_parent);
        },
        .unborn => |u| {
            const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{u.name.items});
            defer allocator.free(ref_name);
            try refs_manager.write(allocator, io.io, ref_name, current_parent);
        },
        .detached => {
            const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{repo.worktree_dir});
            defer allocator.free(head_path);
            var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
            defer hf.close(io.io);
            const hex = Sha1.hex(current_parent);
            var wbuf: [42]u8 = undefined;
            const wline = try std.fmt.bufPrint(&wbuf, "{s}\n", .{&hex});
            try std.Io.File.writeStreamingAll(hf, io.io, wline);
        },
    }

    try io.print("Successfully rebased ({d} rebased, {d} dropped).\n", .{ rebased, dropped });
}

/// Finish a rebase that stopped on a conflict.
///
/// Everything the resolution staged is committed on top of the rewritten tip, and
/// the branch is advanced to it.
fn continueRebase(allocator: std.mem.Allocator, repo: Repo, io: Io) !void {
    const rebase_merge = try std.fmt.allocPrint(allocator, "{s}/rebase-merge", .{repo.worktree_dir});
    defer allocator.free(rebase_merge);

    if (std.Io.Dir.cwd().access(io.io, rebase_merge, .{})) |_| {} else |_| {
        errors.fatal(io, "No rebase in progress?", .{});
    }

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);
    const refs_manager = refs_mod.Refs.init(repo);

    var idx = index_mod.Index.readFromFile(allocator, repo.worktree_dir, io.io) catch
        errors.fatal(io, "could not read the index", .{});
    defer idx.deinit(allocator);

    if (idx.hasConflicts()) {
        const paths = idx.conflictedPaths(allocator);
        defer {
            for (paths) |p| allocator.free(p);
            allocator.free(paths);
        }
        try io.eprint("error: you must edit all merge conflicts and then\nmark them as resolved using gitz add\n", .{});
        for (paths) |p| try io.eprint("\t{s}\n", .{p});
        std.process.exit(1);
    }

    const tree_sha = try idx.writeTree(store, allocator, io.io);

    const head_path = try std.fmt.allocPrint(allocator, "{s}/rebase-merge/orig-head", .{repo.worktree_dir});
    defer allocator.free(head_path);
    const head_content = io.readFileAlloc(head_path) catch "";
    defer if (head_content.len > 0) allocator.free(head_content);
    const trimmed = std.mem.trim(u8, head_content, " \t\r\n");
    const current = Sha1.fromHex(trimmed) catch
        errors.fatal(io, "the rebase state is unreadable; run 'gitz rebase --abort'", .{});

    const obj = store.read(allocator, io.io, current) catch
        errors.fatal(io, "the rebased commit is missing", .{});
    var commit_obj = obj;
    defer commit_obj.deinit(allocator);
    const previous = switch (commit_obj) {
        .commit => |c| c,
        else => errors.fatal(io, "the rebased commit is not a commit", .{}),
    };

    const now_ts = std.Io.Timestamp.now(io.io, .real);
    const now: i64 = @intCast(@divTrunc(now_ts.nanoseconds, std.time.ns_per_s));
    const committer_name = config_cmd.getUserName(allocator, repo.common_dir, io);
    const committer_email = config_cmd.getUserEmail(allocator, repo.common_dir, io);

    const resolved = object.Commit{
        .tree = tree_sha,
        .parents = previous.parents,
        .author = previous.author,
        .committer = .{ .name = committer_name, .email = committer_email, .timestamp = now, .timezone = "+0000" },
        .message = previous.message,
    };
    const resolved_sha = try store.write(allocator, io.io, object.GitObject{ .commit = resolved });

    var head_info = refs_manager.head(allocator, io.io) catch null;
    defer if (head_info) |*h| h.deinit(allocator);
    if (head_info) |*h| {
        switch (h.*) {
            .branch => |b| {
                const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{b.name.items});
                defer allocator.free(ref_name);
                try refs_manager.write(allocator, io.io, ref_name, resolved_sha);
            },
            .unborn => |u| {
                const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{u.name.items});
                defer allocator.free(ref_name);
                try refs_manager.write(allocator, io.io, ref_name, resolved_sha);
            },
            .detached => {
                const hp = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{repo.worktree_dir});
                defer allocator.free(hp);
                const hex = Sha1.hex(resolved_sha);
                try io.writeFile(hp, hex[0..]);
            },
        }
    }

    checkout_mod.checkoutCommit(allocator, repo, io.io, store, resolved_sha) catch {};

    std.Io.Dir.cwd().deleteTree(io.io, rebase_merge) catch {};
    const hex = Sha1.hex(resolved_sha);
    try io.print("Successfully rebased and updated {s}.\n", .{hex[0..7]});
}

fn abortRebase(allocator: std.mem.Allocator, worktree_dir: []const u8, io: Io) !void {
    const rebase_merge = try std.fmt.allocPrint(allocator, "{s}/rebase-merge", .{worktree_dir});
    defer allocator.free(rebase_merge);
    const rebase_apply = try std.fmt.allocPrint(allocator, "{s}/rebase-apply", .{worktree_dir});
    defer allocator.free(rebase_apply);

    const has_merge = if (std.Io.Dir.cwd().access(io.io, rebase_merge, .{})) |_| true else |_| false;
    const has_apply = if (std.Io.Dir.cwd().access(io.io, rebase_apply, .{})) |_| true else |_| false;

    if (!has_merge and !has_apply) {
        errors.fatal(io, "No rebase in progress?", .{});
    }

    std.Io.Dir.cwd().deleteTree(io.io, rebase_merge) catch {};
    std.Io.Dir.cwd().deleteTree(io.io, rebase_apply) catch {};
    try io.print("Successfully aborted.\n", .{});
}

fn resolveRef(
    allocator: std.mem.Allocator,
    io: std.Io,
    refs_manager: refs_mod.Refs,
    store: storage_mod.StorageBackend,
    ref: []const u8,
) ![20]u8 {
    const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{ref});
    defer allocator.free(branch_ref);
    if (refs_manager.read(allocator, io, branch_ref)) |sha| return sha else |_| {}

    const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{ref});
    defer allocator.free(tag_ref);
    if (refs_manager.read(allocator, io, tag_ref)) |sha| return sha else |_| {}

    // Try remote tracking branch: refs/remotes/<name>
    const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}", .{ref});
    defer allocator.free(remote_ref);
    if (refs_manager.read(allocator, io, remote_ref)) |sha| return sha else |_| {}

    if (refs_manager.read(allocator, io, ref)) |sha| return sha else |_| {}
    if (Sha1.fromHex(ref)) |sha| return sha else |_| {}

    if (std.mem.startsWith(u8, ref, "HEAD~")) {
        const count = std.fmt.parseInt(usize, ref[5..], 10) catch 1;
        var cur = try refs_manager.read(allocator, io, "HEAD");
        for (0..count) |_| {
            const obj = store.read(allocator, io, cur) catch break;
            const c = switch (obj) {
                .commit => |cc| cc,
                else => break,
            };
            if (c.parents.len == 0) break;
            cur = c.parents[0];
        }
        return cur;
    }

    return error.InvalidRef;
}
