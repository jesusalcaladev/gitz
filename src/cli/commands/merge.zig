const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const index_mod = @import("../../core/index.zig");
const tree_merge = @import("../../core/tree_merge.zig");
const checkout = @import("../../core/checkout.zig");
const config_cmd = @import("config.zig");
const errors = @import("../errors.zig");
const Repo = @import("../../core/repo.zig").Repo;

/// State written by a conflicted merge so a later `gitz commit` can finish it,
/// mirroring git's MERGE_HEAD / MERGE_MSG.
const MERGE_HEAD = "MERGE_HEAD";
const MERGE_MSG = "MERGE_MSG";

/// How `-X ours` / `-X theirs` resolves a conflict.
const ConflictStrategy = enum { ours, theirs };

pub fn execute(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    // For a repository with no worktrees the three directories coincide, so
    // the existing path building below is unchanged. A linked worktree gets
    // the right directory per role from `repo`.
    const git_dir = repo.worktree_dir;
    var no_ff = false;
    var ff_only = false;
    var abort = false;
    var no_commit = false;
    var squash = false;
    var allow_unrelated = false;
    var strategy: ?ConflictStrategy = null;
    var merge_msg: ?[]const u8 = null;
    var branch_name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--no-ff")) {
            no_ff = true;
        } else if (std.mem.eql(u8, arg, "--ff-only")) {
            ff_only = true;
        } else if (std.mem.eql(u8, arg, "--abort")) {
            abort = true;
        } else if (std.mem.eql(u8, arg, "--no-commit")) {
            // Stop before committing, leaving the merge staged. Previously
            // ignored, so `merge --no-commit` committed anyway.
            no_commit = true;
        } else if (std.mem.eql(u8, arg, "--squash")) {
            // Stage the result without recording the merge. Previously ignored,
            // so `merge --squash` produced a normal merge commit.
            squash = true;
        } else if (std.mem.eql(u8, arg, "--allow-unrelated-histories")) {
            allow_unrelated = true;
        } else if ((std.mem.eql(u8, arg, "-X") or std.mem.eql(u8, arg, "--strategy-option")) and i + 1 < args.len) {
            // `-X ours` / `-X theirs` resolves a conflict by taking one side.
            // Previously ignored, so `merge -X ours` still conflicted.
            i += 1;
            const opt = args[i];
            if (std.mem.eql(u8, opt, "ours")) {
                strategy = .ours;
            } else if (std.mem.eql(u8, opt, "theirs")) {
                strategy = .theirs;
            } else {
                errors.errorf(io, "unknown strategy option '{s}'", .{opt});
            }
        } else if ((std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) and i + 1 < args.len) {
            i += 1;
            merge_msg = args[i];
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.startsWith(u8, arg, "--strategy=")) {
            // A custom strategy is not implemented; refusing beats silently
            // merging with the default one.
            errors.errorf(io, "merge strategies are not supported", .{});
        } else if (std.mem.startsWith(u8, arg, "-")) {
            errors.errorf(io, "unknown option '{s}'", .{arg});
        } else {
            branch_name = arg;
        }
    }

    if (abort) {
        try abortMerge(allocator, repo, io);
        return;
    }

    const name = branch_name orelse {
        try io.eprint("usage: gitz merge [--no-ff] [--ff-only] [--abort] [-m msg] <branch>\n", .{});
        std.process.exit(errors.ExitFailure);
    };

    const refs_manager = refs_mod.Refs.init(repo);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);

    var head_info = refs_manager.head(allocator, io.io) catch {
        errors.fatal(io, "not a gitz repository", .{});
    };
    defer head_info.deinit(allocator);

    const current_sha: [20]u8 = switch (head_info) {
        .branch => |b| b.sha,
        .detached => |d| d.sha,
        // Merging into a branch with no commits is a fast-forward: the target
        // simply becomes HEAD. Treating the all-zero SHA as a real commit made
        // this fail with "could not merge".
        .unborn => {
            const target_ub = resolveTarget(allocator, io, refs_manager, store, name) catch {
                errors.errorf(io, "branch '{s}' not found", .{name});
            };
            try updateCurrentRef(allocator, git_dir, io, refs_manager, &head_info, target_ub);
            checkout.checkoutCommit(allocator, repo, io.io, store, target_ub) catch
                errors.fatal(io, "could not check out the merged tree", .{});
            try io.print("Fast-forward\n", .{});
            return;
        },
    };

    const target_sha = resolveTarget(allocator, io, refs_manager, store, name) catch {
        errors.errorf(io, "branch '{s}' not found", .{name});
    };

    if (std.mem.eql(u8, &current_sha, &target_sha)) {
        try io.print("Already up to date.\n", .{});
        return;
    }

    // Target is already reachable from HEAD -> nothing to do.
    if (isAncestor(allocator, io.io, store, current_sha, target_sha)) {
        try io.print("Already up to date.\n", .{});
        return;
    }

    // HEAD is an ancestor of target -> fast-forward.
    const is_ff = isAncestor(allocator, io.io, store, target_sha, current_sha);

    if (is_ff and !no_ff) {
        if (try wouldLoseWork(allocator, repo, io, store, target_sha)) {
            errors.errorf(io, "Your local changes would be overwritten by merge. Commit or stash them first.", .{});
        }
        try updateCurrentRef(allocator, git_dir, io, refs_manager, &head_info, target_sha);
        checkout.checkoutCommit(allocator, repo, io.io, store, target_sha) catch
            errors.fatal(io, "could not check out the merged tree", .{});

        const hex = Sha1.hex(target_sha);
        try io.print("Fast-forward\n", .{});
        try io.print(" {s}..{s} -> {s}\n", .{ Sha1.hex(current_sha)[0..7], hex[0..7], name });
        return;
    }

    if (ff_only) {
        errors.errorf(io, "Not possible to fast-forward, aborting.", .{});
    }

    // ── Real three-way merge ────────────────────────────────────────────
    var merged = tree_merge.mergeCommits(allocator, io.io, store, current_sha, target_sha, name) catch
        errors.fatal(io, "could not merge '{s}'", .{name});
    defer merged.deinit(allocator);

    // `-X ours` / `-X theirs` resolve every conflict by taking one side, so the
    // merge completes. The option used to be ignored and the merge still
    // conflicted, which is the opposite of what was asked for.
    if (strategy) |chosen| {
        for (merged.entries) |*e| {
            if (!e.conflict) continue;
            e.conflict = false;
            e.marker_content = null;
            const side = switch (chosen) {
                .ours => e.sha,
                .theirs => e.their_sha orelse e.sha,
            };
            e.sha = side;
        }
    }

    // The merge rewrites the working tree, so local changes it would clobber
    // have to be refused first. Only the fast-forward branch ran this check, so a
    // real merge silently discarded uncommitted work.
    //
    // The comparison is against the *merge result*, not against the branch being
    // merged: git also allows a merge when the dirty file is identical on both
    // sides and therefore untouched by the merge.
    {
        const at_risk = try mergeAtRiskPaths(allocator, git_dir, io, store, &merged, current_sha);
        defer {
            for (at_risk) |p| allocator.free(p);
            allocator.free(at_risk);
        }

        if (at_risk.len > 0) {
            try io.eprint("error: Your local changes to the following files would be overwritten by merge:\n", .{});
            for (at_risk) |p| try io.eprint("\t{s}\n", .{p});
            try io.eprint("Please commit your changes or stash them before you merge.\n", .{});
            try io.eprint("Aborting\n", .{});
            std.process.exit(1);
        }
    }

    var conflicts: usize = 0;
    for (merged.entries) |e| {
        if (e.conflict) conflicts += 1;
    }

    if (conflicts > 0) {
        try reportConflicts(allocator, repo, io, store, &merged, target_sha, name, merge_msg);
        // A conflicted merge must not move HEAD: git leaves the merge in
        // progress so the user can resolve and commit.
        errors.exitWith(io, errors.ExitFailure, "Automatic merge failed; fix conflicts and then commit the result.", .{});
    }

    // No conflicts: build the merged tree, commit it, then move HEAD and
    // refresh both the working tree and the index so the repository stays
    // self-consistent.
    const tree_sha = try writeMergedTree(allocator, io, store, &merged);
    try writeWorktree(allocator, repo, io, store, &merged);

    var idx = index_mod.Index.init(allocator);
    defer idx.deinit(allocator);
    try indexFromMerged(allocator, &idx, &merged);
    try idx.writeToFile(repo.worktree_dir, allocator, io.io);

    // `--squash` and `--no-commit` both stop before the merge commit: the result
    // is staged and MERGE_HEAD/MERGE_MSG are left for `gitz commit` to consume.
    // Both used to be ignored, so `merge --squash` produced an ordinary merge
    // commit with a second parent.
    if (squash or no_commit) {
        // `--squash` deliberately leaves no MERGE_HEAD: `gitz commit` reads that
        // file to add a second parent, and a squash must produce a single-parent
        // commit. Its message goes to SQUASH_MSG instead.
        try writeMergeState(allocator, repo, io, target_sha, name, merge_msg, squash);
        try io.print("Automatic merge went well; stopped before committing as requested\n", .{});
        return;
    }

    const merge_sha = try writeMergeCommit(allocator, repo, io, store, tree_sha, current_sha, target_sha, merge_msg, name);
    try updateCurrentRef(allocator, git_dir, io, refs_manager, &head_info, merge_sha);

    const hex = Sha1.hex(merge_sha);
    try io.print("Merge made by the 'ort' strategy.\n", .{});
    try io.print(" {s}\n", .{hex[0..7]});
}

/// Record the pending-merge state so `gitz commit` finishes the work.
fn writeMergeState(
    allocator: std.mem.Allocator,
    repo: Repo,
    io: Io,
    target_sha: [20]u8,
    name: []const u8,
    merge_msg: ?[]const u8,
    squash: bool,
) !void {
    const msg = merge_msg orelse try std.fmt.allocPrint(allocator, "Merge branch '{s}'", .{name});
    defer if (merge_msg == null) allocator.free(msg);

    if (squash) {
        const squash_path = try std.fmt.allocPrint(allocator, "{s}/SQUASH_MSG", .{repo.worktree_dir});
        defer allocator.free(squash_path);
        try io.writeFile(squash_path, msg);
        return;
    }

    const head_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo.worktree_dir, MERGE_HEAD });
    defer allocator.free(head_path);

    const hex = Sha1.hex(target_sha);
    var wbuf: [42]u8 = undefined;
    const line = try std.fmt.bufPrint(&wbuf, "{s}\n", .{&hex});
    var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
    defer hf.close(io.io);
    try std.Io.File.writeStreamingAll(hf, io.io, line);

    const msg_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo.worktree_dir, MERGE_MSG });
    defer allocator.free(msg_path);
    try io.writeFile(msg_path, msg);
}

/// Build the merged tree object from the merge result.
fn writeMergedTree(
    allocator: std.mem.Allocator,
    io: Io,
    store: storage_mod.StorageBackend,
    merged: *const tree_merge.TreeMergeResult,
) ![20]u8 {
    var idx = index_mod.Index.init(allocator);
    defer idx.deinit(allocator);
    try indexFromMerged(allocator, &idx, merged);
    return idx.writeTree(store, allocator, io.io);
}

fn indexFromMerged(
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    merged: *const tree_merge.TreeMergeResult,
) !void {
    for (merged.entries) |e| {
        try idx.add(allocator, e.path, e.sha, .{ .mode = e.mode });
    }
}

/// The blob recorded for one side of a conflicted path.
///
/// `TreeMergeResult` exposes the merged/ours SHA; the base and theirs blobs
/// come from the same struct when the three-way walk recorded them.
fn stageBlob(merged: *const tree_merge.TreeMergeResult, path: []const u8, stage: index_mod.Stage) ?[20]u8 {
    for (merged.entries) |e| {
        if (!std.mem.eql(u8, e.path, path)) continue;
        return switch (stage) {
            // `e.sha` is our side of the conflict.
            .ours => e.sha,
            .base => e.base_sha orelse e.sha,
            .theirs => e.their_sha orelse e.sha,
            .normal => e.sha,
        };
    }
    return null;
}

fn writeMergeCommit(
    allocator: std.mem.Allocator,
    repo: Repo,
    io: Io,
    store: storage_mod.StorageBackend,
    tree_sha: [20]u8,
    current_sha: [20]u8,
    target_sha: [20]u8,
    merge_msg: ?[]const u8,
    name: []const u8,
) ![20]u8 {
    var parents = try allocator.alloc([20]u8, 2);
    defer allocator.free(parents);
    parents[0] = current_sha; // first parent is the current branch
    parents[1] = target_sha; // second parent is the branch being merged in

    const msg = merge_msg orelse msg: {
        var msg_buf: [256]u8 = undefined;
        break :msg try std.fmt.bufPrint(&msg_buf, "Merge branch '{s}'", .{name});
    };

    const now = currentTimestamp(io);

    const author_name = config_cmd.getUserName(allocator, repo.common_dir, io);
    defer if (!std.mem.eql(u8, author_name, "GitZ User")) allocator.free(author_name);
    const author_email = config_cmd.getUserEmail(allocator, repo.common_dir, io);
    defer if (!std.mem.eql(u8, author_email, "user@gitz.dev")) allocator.free(author_email);

    const commit = object.Commit{
        .tree = tree_sha,
        .parents = parents,
        .author = .{ .name = author_name, .email = author_email, .timestamp = now, .timezone = "+0000" },
        .committer = .{ .name = author_name, .email = author_email, .timestamp = now, .timezone = "+0000" },
        .message = msg,
    };
    return store.write(allocator, io.io, object.GitObject{ .commit = commit });
}

fn currentTimestamp(io: Io) i64 {
    const ts = std.Io.Timestamp.now(io.io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

/// Write the merge result to the working tree. Files that the merge removed
/// are deleted so the checkout matches the merge commit.
fn writeWorktree(
    allocator: std.mem.Allocator,
    repo: Repo,
    io: Io,
    store: storage_mod.StorageBackend,
    merged: *const tree_merge.TreeMergeResult,
) !void {
    // Remember which paths the pre-merge index tracked so removals can be
    // detected.
    var old_index = index_mod.Index.readFromFile(allocator, repo.worktree_dir, io.io) catch null;
    defer if (old_index) |*oi| oi.deinit(allocator);

    // Only paths the merge actually changed are written. Writing every entry of
    // the merged tree reset unrelated dirty files to their committed content, so
    // an edit to a file the merge never touched was silently discarded.
    var head_files = checkout.FileMap.init(allocator);
    defer checkout.freeMap(allocator, &head_files);
    {
        const refs_manager = refs_mod.Refs.init(repo);
        if (refs_manager.read(allocator, io.io, "HEAD")) |hs| {
            if (store.read(allocator, io.io, hs)) |obj| {
                var o = obj;
                defer o.deinit(allocator);
                if (o == .commit) {
                    const t = o.commit.tree;
                    checkout.flattenTree(allocator, io.io, store, t, "", &head_files) catch {};
                }
            } else |_| {}
        } else |_| {}
    }

    for (merged.entries) |e| {
        const head_entry = head_files.get(e.path);
        const differs = head_entry == null or !std.mem.eql(u8, &head_entry.?.sha, &e.sha);
        if (!differs and !e.conflict) continue;

        if (std.fs.path.dirname(e.path)) |dir| {
            std.Io.Dir.cwd().createDirPath(io.io, dir) catch {};
        }

        // A conflicted path gets the markers in the working tree.
        if (e.marker_content) |markers| {
            var wf = std.Io.Dir.cwd().createFile(io.io, e.path, .{}) catch continue;
            defer wf.close(io.io);
            std.Io.File.writeStreamingAll(wf, io.io, markers) catch {};
            continue;
        }

        const content = checkout.readBlob(allocator, io.io, store, e.sha) orelse continue;
        defer allocator.free(content);
        var wf = std.Io.Dir.cwd().createFile(io.io, e.path, .{}) catch continue;
        defer wf.close(io.io);
        std.Io.File.writeStreamingAll(wf, io.io, content) catch {};
    }

    if (old_index) |oi| {
        for (oi.entries.items) |entry| {
            const clean = if (std.mem.startsWith(u8, entry.name, "./")) entry.name[2..] else entry.name;
            var still_there = false;
            for (merged.entries) |e| {
                if (std.mem.eql(u8, e.path, clean)) {
                    still_there = true;
                    break;
                }
            }
            if (still_there) continue;
            std.Io.Dir.cwd().deleteFile(io.io, clean) catch {};
        }
    }
}

/// True when the working tree has uncommitted changes to files that the merge
/// would replace.
fn wouldLoseWork(
    allocator: std.mem.Allocator,
    repo: Repo,
    io: Io,
    store: storage_mod.StorageBackend,
    target_sha: [20]u8,
) !bool {
    const report = checkout.checkSafeToReplace(allocator, repo, io.io, store, target_sha) catch
        return false;
    var r = report;
    defer r.deinit(allocator);
    return r.paths.len > 0;
}

/// Resolve the thing being merged: a local branch, a remote-tracking branch, a
/// tag, a full ref name or a raw SHA.
///
/// Only `refs/heads/<name>` was tried, so `gitz merge origin/main` -- what
/// `gitz pull` itself passes -- always failed with "branch not found", and
/// `gitz pull --merge` could never integrate anything.
fn resolveTarget(
    allocator: std.mem.Allocator,
    io: Io,
    refs_manager: refs_mod.Refs,
    store: storage_mod.StorageBackend,
    name: []const u8,
) ![20]u8 {
    const candidates = [_][]const u8{ "refs/heads/", "refs/remotes/", "refs/tags/" };
    for (candidates) |prefix| {
        const ref = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, name });
        defer allocator.free(ref);
        if (refs_manager.read(allocator, io.io, ref)) |sha| return sha else |_| {}
    }

    if (refs_manager.read(allocator, io.io, name)) |sha| return sha else |_| {}

    if (Sha1.fromHex(name)) |sha| {
        if (store.exists(io.io, sha)) return sha;
        return error.RefNotFound;
    } else |_| {}

    return error.RefNotFound;
}

/// The paths a merge would clobber because they carry uncommitted changes.
///
/// A path is at risk when the merge result differs from HEAD's version *and* the
/// working tree differs from the index. Paths the merge leaves untouched are not
/// reported, which is why a dirty file that is identical on both sides merges
/// fine, as it does in git.
fn mergeAtRiskPaths(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: Io,
    store: storage_mod.StorageBackend,
    merged: *const tree_merge.TreeMergeResult,
    current_sha: [20]u8,
) ![][]const u8 {
    var risk: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (risk.items) |p| allocator.free(p);
        risk.deinit(allocator);
    }

    var head_files = checkout.FileMap.init(allocator);
    defer checkout.freeMap(allocator, &head_files);
    {
        const obj = store.read(allocator, io.io, current_sha) catch return &.{};
        defer obj.deinit(allocator);
        const commit = switch (obj) {
            .commit => |c| c,
            else => return &.{},
        };
        checkout.flattenTree(allocator, io.io, store, commit.tree, "", &head_files) catch return &.{};
    }

    var idx = index_mod.Index.readFromFile(allocator, git_dir, io.io) catch null;
    defer if (idx) |*i| i.deinit(allocator);

    // Changed by the merge, so writing it would overwrite the worktree.
    var changed = checkout.FileMap.init(allocator);
    defer checkout.freeMap(allocator, &changed);
    for (merged.entries) |e| {
        const head_entry = head_files.get(e.path);

        // A conflicted entry carries our own blob as its `sha` while the merge
        // will write conflict markers over the file, so it counts as changed
        // even though the SHA matches HEAD.
        const differs = head_entry == null or !std.mem.eql(u8, &head_entry.?.sha, &e.sha);
        if (differs or e.conflict) {
            // The map keeps the slice, so ownership transfers here: freeing
            // the key right after the insert left a dangling key and the whole
            // set of "at risk" paths came out empty, so the dirty-tree check
            // never fired.
            const key = try allocator.dupe(u8, e.path);
            if (changed.get(key) != null) {
                allocator.free(key);
                continue;
            }
            try changed.put(key, .{ .sha = e.sha, .mode = e.mode });
        }
    }

    var it = changed.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        const content = std.Io.Dir.cwd().readFileAlloc(io.io, path, allocator, .unlimited) catch continue;
        defer allocator.free(content);

        const work = checkout.blobSha(allocator, content) catch continue;
        const staged = if (idx) |*i| indexShaOf(i, path) else null;
        if (staged != null and std.mem.eql(u8, &staged.?, &work)) continue;

        try risk.append(allocator, try allocator.dupe(u8, path));
    }

    return risk.toOwnedSlice(allocator);
}

fn indexShaOf(idx: *const index_mod.Index, path: []const u8) ?[20]u8 {
    for (idx.entries.items) |entry| {
        if (entry.stage != .normal) continue;
        const clean = if (std.mem.startsWith(u8, entry.name, "./")) entry.name[2..] else entry.name;
        if (std.mem.eql(u8, clean, path)) return entry.sha;
    }
    return null;
}

/// Conflicted merge: stage the cleanly merged paths, write conflict markers to
/// the working tree for the rest, and record MERGE_HEAD/MERGE_MSG so the user
/// can resolve and `gitz commit`.
fn reportConflicts(
    allocator: std.mem.Allocator,
    repo: Repo,
    io: Io,
    store: storage_mod.StorageBackend,
    merged: *const tree_merge.TreeMergeResult,
    target_sha: [20]u8,
    name: []const u8,
    merge_msg: ?[]const u8,
) !void {
    var idx = index_mod.Index.init(allocator);
    defer idx.deinit(allocator);

    // The index holds every path of the merged tree, but only the paths the
    // merge actually changed are written to the working tree. Rewriting all of
    // them reset unrelated dirty files to their committed content.
    var head_files = checkout.FileMap.init(allocator);
    defer checkout.freeMap(allocator, &head_files);
    {
        const refs_manager = refs_mod.Refs.init(repo);
        if (refs_manager.read(allocator, io.io, "HEAD")) |hs| {
            if (store.read(allocator, io.io, hs)) |obj| {
                var o = obj;
                defer o.deinit(allocator);
                if (o == .commit) {
                    const t = o.commit.tree;
                    checkout.flattenTree(allocator, io.io, store, t, "", &head_files) catch {};
                }
            } else |_| {}
        } else |_| {}
    }

    for (merged.entries) |e| {
        const head_entry = head_files.get(e.path);
        const differs = head_entry == null or !std.mem.eql(u8, &head_entry.?.sha, &e.sha);
        const touched = differs or e.conflict;

        if (e.conflict) {
            try io.eprint("CONFLICT (content): Merge conflict in {s}\n", .{e.path});

            // The conflicted path is staged as three entries -- base, ours and
            // theirs -- which is what lets `status` report an unmerged path and
            // makes `commit` refuse until the user resolves it.
            //
            // A single stage-0 entry pointing at our side was written instead,
            // so `gitz status` showed the file as merely modified and a plain
            // `gitz commit` completed the merge with the other side thrown away
            // and nothing in the output to say so.
            for ([_]index_mod.Stage{ .base, .ours, .theirs }) |stage| {
                const stage_sha = stageBlob(merged, e.path, stage) orelse continue;
                try idx.add(allocator, e.path, stage_sha, .{ .mode = e.mode, .stage = stage });
            }

            if (touched) {
                if (e.marker_content) |markers| {
                    if (std.fs.path.dirname(e.path)) |dir| {
                        std.Io.Dir.cwd().createDirPath(io.io, dir) catch {};
                    }
                    var wf = std.Io.Dir.cwd().createFile(io.io, e.path, .{}) catch continue;
                    defer wf.close(io.io);
                    std.Io.File.writeStreamingAll(wf, io.io, markers) catch {};
                }
            }
        } else {
            try idx.add(allocator, e.path, e.sha, .{ .mode = e.mode });
            if (!touched) continue;
            const content = checkout.readBlob(allocator, io.io, store, e.sha) orelse continue;
            defer allocator.free(content);
            if (std.fs.path.dirname(e.path)) |dir| {
                std.Io.Dir.cwd().createDirPath(io.io, dir) catch {};
            }
            var wf = std.Io.Dir.cwd().createFile(io.io, e.path, .{}) catch continue;
            defer wf.close(io.io);
            std.Io.File.writeStreamingAll(wf, io.io, content) catch {};
        }
    }

    try idx.writeToFile(repo.worktree_dir, allocator, io.io);

    // Leave the merge in progress, exactly like git.
    const head_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo.worktree_dir, MERGE_HEAD });
    defer allocator.free(head_path);
    {
        const hex = Sha1.hex(target_sha);
        var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
        defer hf.close(io.io);
        var wbuf: [42]u8 = undefined;
        try std.Io.File.writeStreamingAll(hf, io.io, try std.fmt.bufPrint(&wbuf, "{s}\n", .{&hex}));
    }

    const msg_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo.worktree_dir, MERGE_MSG });
    defer allocator.free(msg_path);
    {
        var msg_buf: [256]u8 = undefined;
        const m = merge_msg orelse try std.fmt.bufPrint(&msg_buf, "Merge branch '{s}'", .{name});
        io.writeFile(msg_path, m) catch {};
    }
}

fn abortMerge(allocator: std.mem.Allocator, repo: Repo, io: Io) !void {
    const head_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo.worktree_dir, MERGE_HEAD });
    defer allocator.free(head_path);
    // git exits 128 here; printing and returning 0 made a scripted
    // `gitz merge --abort` look like it had undone a merge.
    if (!io.fileExists(head_path)) {
        errors.fatal(io, "There is no merge to abort (MERGE_HEAD missing)", .{});
    }

    const refs_manager = refs_mod.Refs.init(repo);
    var head_info = refs_manager.head(allocator, io.io) catch {
        errors.fatal(io, "not a gitz repository", .{});
    };
    defer head_info.deinit(allocator);
    const current_sha = switch (head_info) {
        .branch => |b| b.sha,
        .detached => |d| d.sha,
        // A merge can only be in progress if HEAD already has commits.
        .unborn => errors.fatal(io, "There is no merge to abort (MERGE_HEAD missing)", .{}),
    };

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);
    checkout.checkoutCommit(allocator, repo, io.io, store, current_sha) catch
        errors.fatal(io, "could not restore the working tree", .{});

    try clearMergeState(allocator, repo.worktree_dir, io);
    try io.print("Merge aborted; restored HEAD to the pre-merge state.\n", .{});
}

pub fn clearMergeState(allocator: std.mem.Allocator, worktree_dir: []const u8, io: Io) !void {
    // SQUASH_MSG is cleared too: `merge --squash` writes it instead of
    // MERGE_HEAD, so `commit` kept picking up a stale message afterwards.
    for ([_][]const u8{ MERGE_HEAD, MERGE_MSG, "SQUASH_MSG" }) |name| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktree_dir, name });
        defer allocator.free(p);
        std.Io.Dir.cwd().deleteFile(io.io, p) catch {};
    }
}

/// Read MERGE_HEAD if a merge is in progress.
pub fn pendingMergeHead(allocator: std.mem.Allocator, worktree_dir: []const u8, io: Io) ?[20]u8 {
    const p = std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktree_dir, MERGE_HEAD }) catch return null;
    defer allocator.free(p);
    const content = io.readFileAlloc(p) catch return null;
    defer allocator.free(content);
    const hex = std.mem.trim(u8, content, " \t\r\n");
    if (hex.len < 40) return null;
    return Sha1.fromHex(hex[0..40]) catch null;
}

fn updateCurrentRef(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: Io,
    refs_manager: refs_mod.Refs,
    head_info: *const refs_mod.HeadInfo,
    sha: [20]u8,
) !void {
    switch (head_info.*) {
        .branch => |b| {
            const current_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{b.name.items});
            defer allocator.free(current_ref);
            try refs_manager.write(allocator, io.io, current_ref, sha);
        },
        // An unborn branch simply gains its first commit.
        .unborn => |u| {
            const current_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{u.name.items});
            defer allocator.free(current_ref);
            try refs_manager.write(allocator, io.io, current_ref, sha);
        },
        .detached => {
            const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
            defer allocator.free(head_path);
            var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
            defer hf.close(io.io);
            const hex = Sha1.hex(sha);
            var wbuf: [42]u8 = undefined;
            try std.Io.File.writeStreamingAll(hf, io.io, try std.fmt.bufPrint(&wbuf, "{s}\n", .{&hex}));
        },
    }
}

/// Check if 'possible_ancestor' is an ancestor of 'commit'
fn isAncestor(allocator: std.mem.Allocator, io: std.Io, store: storage_mod.StorageBackend, commit_sha: [20]u8, possible_ancestor: [20]u8) bool {
    var visited = std.AutoHashMap([20]u8, void).init(allocator);
    defer visited.deinit();

    var queue = std.ArrayList([20]u8){ .items = &.{}, .capacity = 0 };
    defer queue.deinit(allocator);

    queue.append(allocator, commit_sha) catch return false;

    while (queue.items.len > 0) {
        const sha = queue.pop() orelse break;
        if (std.mem.eql(u8, &sha, &possible_ancestor)) return true;
        if (visited.contains(sha)) continue;
        visited.put(sha, {}) catch continue;

        const obj = store.read(allocator, io, sha) catch continue;
        const commit = switch (obj) {
            .commit => |c| c,
            else => continue,
        };

        for (commit.parents) |parent| {
            queue.append(allocator, parent) catch continue;
        }
    }

    return false;
}
