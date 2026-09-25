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

/// State written by a conflicted merge so a later `gitz commit` can finish it,
/// mirroring git's MERGE_HEAD / MERGE_MSG.
const MERGE_HEAD = "MERGE_HEAD";
const MERGE_MSG = "MERGE_MSG";

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var no_ff = false;
    var ff_only = false;
    var abort = false;
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
        } else if ((std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) and i + 1 < args.len) {
            i += 1;
            merge_msg = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            branch_name = arg;
        }
    }

    if (abort) {
        try abortMerge(allocator, git_dir, io);
        return;
    }

    const name = branch_name orelse {
        try io.eprint("usage: gitz merge [--no-ff] [--ff-only] [--abort] [-m msg] <branch>\n", .{});
        std.process.exit(errors.ExitFailure);
    };

    const refs_manager = refs_mod.Refs.init(git_dir);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);

    var head_info = refs_manager.head(allocator, io.io) catch {
        errors.fatal(io, "not a gitz repository", .{});
    };
    defer head_info.deinit(allocator);

    const current_sha = switch (head_info) {
        .branch => |b| b.sha,
        .detached => |d| d.sha,
    };

    const target_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
    defer allocator.free(target_ref);

    const target_sha = refs_manager.read(allocator, io.io, target_ref) catch {
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
        if (try wouldLoseWork(allocator, git_dir, io, store, target_sha)) {
            errors.errorf(io, "Your local changes would be overwritten by merge. Commit or stash them first.", .{});
        }
        try updateCurrentRef(allocator, git_dir, io, refs_manager, &head_info, target_sha);
        checkout.checkoutCommit(allocator, git_dir, io.io, store, target_sha) catch
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

    var conflicts: usize = 0;
    for (merged.entries) |e| {
        if (e.conflict) conflicts += 1;
    }

    if (conflicts > 0) {
        try reportConflicts(allocator, git_dir, io, store, &merged, target_sha, name, merge_msg);
        // A conflicted merge must not move HEAD: git leaves the merge in
        // progress so the user can resolve and commit.
        errors.exitWith(io, errors.ExitFailure, "Automatic merge failed; fix conflicts and then commit the result.", .{});
    }

    // No conflicts: build the merged tree, commit it, then move HEAD and
    // refresh both the working tree and the index so the repository stays
    // self-consistent.
    const tree_sha = try writeMergedTree(allocator, io, store, &merged);
    const merge_sha = try writeMergeCommit(allocator, git_dir, io, store, tree_sha, current_sha, target_sha, merge_msg, name);
    try updateCurrentRef(allocator, git_dir, io, refs_manager, &head_info, merge_sha);
    try writeWorktree(allocator, git_dir, io, store, &merged);

    var idx = index_mod.Index.init(allocator);
    defer idx.deinit(allocator);
    try indexFromMerged(allocator, &idx, &merged);
    try idx.writeToFile(git_dir, allocator, io.io);

    const hex = Sha1.hex(merge_sha);
    try io.print("Merge made by the 'ort' strategy.\n", .{});
    try io.print(" {s}\n", .{hex[0..7]});
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

fn writeMergeCommit(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
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

    const author_name = config_cmd.getUserName(allocator, git_dir, io);
    defer if (!std.mem.eql(u8, author_name, "GitZ User")) allocator.free(author_name);
    const author_email = config_cmd.getUserEmail(allocator, git_dir, io);
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
    git_dir: []const u8,
    io: Io,
    store: storage_mod.StorageBackend,
    merged: *const tree_merge.TreeMergeResult,
) !void {
    // Remember which paths the pre-merge index tracked so removals can be
    // detected.
    var old_index = index_mod.Index.readFromFile(allocator, git_dir, io.io) catch null;
    defer if (old_index) |*oi| oi.deinit(allocator);

    for (merged.entries) |e| {
        if (std.fs.path.dirname(e.path)) |dir| {
            std.Io.Dir.cwd().createDirPath(io.io, dir) catch {};
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

/// True when the working tree has uncommitted changes to files that the
/// fast-forward would replace.
fn wouldLoseWork(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: Io,
    store: storage_mod.StorageBackend,
    target_sha: [20]u8,
) !bool {
    const report = checkout.checkSafeToReplace(allocator, git_dir, io.io, store, target_sha) catch
        return false;
    var r = report;
    defer r.deinit(allocator);
    return r.paths.len > 0;
}

/// Conflicted merge: stage the cleanly merged paths, write conflict markers to
/// the working tree for the rest, and record MERGE_HEAD/MERGE_MSG so the user
/// can resolve and `gitz commit`.
fn reportConflicts(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: Io,
    store: storage_mod.StorageBackend,
    merged: *const tree_merge.TreeMergeResult,
    target_sha: [20]u8,
    name: []const u8,
    merge_msg: ?[]const u8,
) !void {
    var idx = index_mod.Index.init(allocator);
    defer idx.deinit(allocator);

    for (merged.entries) |e| {
        if (e.conflict) {
            try io.eprint("CONFLICT (content): Merge conflict in {s}\n", .{e.path});
            // The index keeps the "ours" blob until the user resolves it; the
            // working tree shows the markers so they can see both sides.
            try idx.add(allocator, e.path, e.sha, .{ .mode = e.mode });
            if (e.marker_content) |markers| {
                if (std.fs.path.dirname(e.path)) |dir| {
                    std.Io.Dir.cwd().createDirPath(io.io, dir) catch {};
                }
                var wf = std.Io.Dir.cwd().createFile(io.io, e.path, .{}) catch continue;
                defer wf.close(io.io);
                std.Io.File.writeStreamingAll(wf, io.io, markers) catch {};
            }
        } else {
            try idx.add(allocator, e.path, e.sha, .{ .mode = e.mode });
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
    try idx.writeToFile(git_dir, allocator, io.io);

    // Leave the merge in progress, exactly like git.
    const head_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, MERGE_HEAD });
    defer allocator.free(head_path);
    {
        const hex = Sha1.hex(target_sha);
        var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
        defer hf.close(io.io);
        var wbuf: [42]u8 = undefined;
        try std.Io.File.writeStreamingAll(hf, io.io, try std.fmt.bufPrint(&wbuf, "{s}\n", .{&hex}));
    }

    const msg_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, MERGE_MSG });
    defer allocator.free(msg_path);
    {
        var msg_buf: [256]u8 = undefined;
        const m = merge_msg orelse try std.fmt.bufPrint(&msg_buf, "Merge branch '{s}'", .{name});
        io.writeFile(msg_path, m) catch {};
    }
}

fn abortMerge(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) !void {
    const head_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, MERGE_HEAD });
    defer allocator.free(head_path);
    if (!io.fileExists(head_path)) {
        try io.print("No merge in progress.\n", .{});
        return;
    }

    const refs_manager = refs_mod.Refs.init(git_dir);
    var head_info = refs_manager.head(allocator, io.io) catch {
        errors.fatal(io, "not a gitz repository", .{});
    };
    defer head_info.deinit(allocator);
    const current_sha = switch (head_info) {
        .branch => |b| b.sha,
        .detached => |d| d.sha,
    };

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    checkout.checkoutCommit(allocator, git_dir, io.io, store, current_sha) catch
        errors.fatal(io, "could not restore the working tree", .{});

    try clearMergeState(allocator, git_dir, io);
    try io.print("Merge aborted; restored HEAD to the pre-merge state.\n", .{});
}

pub fn clearMergeState(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) !void {
    for ([_][]const u8{ MERGE_HEAD, MERGE_MSG }) |name| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, name });
        defer allocator.free(p);
        std.Io.Dir.cwd().deleteFile(io.io, p) catch {};
    }
}

/// Read MERGE_HEAD if a merge is in progress.
pub fn pendingMergeHead(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) ?[20]u8 {
    const p = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, MERGE_HEAD }) catch return null;
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
