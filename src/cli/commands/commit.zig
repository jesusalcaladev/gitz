const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const object = @import("../../core/object.zig");
const storage_mod = @import("../../core/storage.zig");
const refs_mod = @import("../../core/refs.zig");
const index_mod = @import("../../core/index.zig");
const config_cmd = @import("config.zig");
const merge_cmd = @import("merge.zig");
const checkout_mod = @import("../../core/checkout.zig");
const Repo = @import("../../core/repo.zig").Repo;

pub fn execute(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    // For a repository with no worktrees the three directories coincide, so
    // the existing path building below is unchanged. A linked worktree gets
    // the right directory per role from `repo`.
    const git_dir = repo.worktree_dir;
    var message: ?[]const u8 = null;
    var auto_stage = false;
    var amend = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) and i + 1 < args.len) {
            i += 1;
            message = args[i];
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            auto_stage = true;
        } else if (std.mem.eql(u8, arg, "--amend")) {
            amend = true;
        } else if (std.mem.startsWith(u8, arg, "-") and !std.mem.startsWith(u8, arg, "--") and arg.len > 1) {
            // Bundled short flags: `-am "msg"` means `-a -m "msg"`, and `-m`
            // consumes the next argument as its value. This is the single most
            // common git incantation, so it has to work.
            const flags = arg[1..];
            var k: usize = 0;
            while (k < flags.len) : (k += 1) {
                switch (flags[k]) {
                    'a' => auto_stage = true,
                    'm' => {
                        if (k + 1 < flags.len) {
                            // e.g. -mmsg — the rest of the token is the message.
                            message = flags[k + 1 ..];
                            k = flags.len;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            message = args[i];
                        }
                    },
                    else => {},
                }
            }
        }
    }

    if (message == null) {
        // A merge in progress carries its own message, like git does.
        if (merge_cmd.pendingMergeHead(allocator, git_dir, io) != null) {
            message = mergeMessage(allocator, git_dir, io) orelse "Merge";
        } else {
            try io.eprint("error: please provide a commit message with -m\n", .{});
            std.process.exit(1);
        }
    }

    // Auto-stage if -a flag
    if (auto_stage) {
        try autoStageAll(allocator, repo, io);
    }

    var idx = try index_mod.Index.readFromFile(allocator, repo.worktree_dir, io.io);
    if (idx.count() == 0) {
        try io.eprint("nothing to commit, working tree clean\n", .{});
        idx.deinit(allocator);
        std.process.exit(1);
    }

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);
    const refs_manager = refs_mod.Refs.init(repo);

    // A conflicted merge cannot be committed yet. The index holds three entries
    // per conflicted path (base/ours/theirs); writing a tree would have to pick
    // one of them, so the other side would be recorded as if it had been
    // agreed. Git refuses, and says which paths are in the way.
    if (!amend and idx.hasConflicts()) {
        const paths = idx.conflictedPaths(allocator);
        defer {
            for (paths) |p| allocator.free(p);
            allocator.free(paths);
        }
        try io.eprint("error: Committing is not possible because you have unmerged files.\n", .{});
        try io.eprint("hint: Fix them up in the work tree, and then use 'gitz add'\n", .{});
        try io.eprint("hint: as appropriate to mark resolution and make a commit.\n", .{});
        try io.eprint("Unmerged paths:\n", .{});
        for (paths) |p| try io.eprint("\t{s}\n", .{p});
        std.process.exit(1);
    }

    const tree_sha = try idx.writeTree(store, allocator, io.io);

    // "Nothing to commit" is about the tree, not about how many entries the
    // index happens to hold. After a commit the index is repopulated from the
    // tree, so `count() > 0` was true even with nothing staged: a stray
    // `gitz commit -m ...` silently created an empty commit and exited 0.
    // Comparing the index tree with HEAD's tree is what git does.
    if (!amend) {
        if (refs_manager.read(allocator, io.io, "HEAD")) |head_sha| {
            if (headTreeEquals(store, allocator, io, head_sha, tree_sha)) {
                try io.eprint("nothing to commit, working tree clean\n", .{});
                idx.deinit(allocator);
                std.process.exit(1);
            }
        } else |_| {
            // Unborn HEAD: the first commit is legitimate.
        }
    }

    // Get author info from config
    const author_name = config_cmd.getUserName(allocator, repo.common_dir, io);
    defer if (!std.mem.eql(u8, author_name, "GitZ User")) allocator.free(author_name);
    const author_email = config_cmd.getUserEmail(allocator, repo.common_dir, io);
    defer if (!std.mem.eql(u8, author_email, "user@gitz.dev")) allocator.free(author_email);

    // Get parent commit
    var parents: [][20]u8 = &.{};

    if (amend) {
        const current_sha = refs_manager.read(allocator, io.io, "HEAD") catch null;
        if (current_sha) |sha| {
            const obj = store.read(allocator, io.io, sha) catch null;
            if (obj) |o| {
                const commit = switch (o) {
                    .commit => |c| c,
                    else => null,
                };
                if (commit) |c| {
                    if (c.parents.len > 0) {
                        parents = try allocator.alloc([20]u8, c.parents.len);
                        @memcpy(parents, c.parents);
                    }
                }
            }
        }
    } else {
        const parent_sha = refs_manager.read(allocator, io.io, "HEAD") catch null;
        if (parent_sha) |sha| {
            var all_zero = true;
            for (sha) |b| {
                if (b != 0) {
                    all_zero = false;
                    break;
                }
            }
            if (!all_zero) {
                parents = try allocator.alloc([20]u8, 1);
                parents[0] = sha;
            }
        }

        // A merge left in progress by `gitz merge` completes here: the commit
        // gets a second parent and the merge state is cleared, exactly like
        // `git commit` after a conflicted merge.
        if (merge_cmd.pendingMergeHead(allocator, git_dir, io)) |theirs| {
            if (parents.len == 0) {
                parents = try allocator.alloc([20]u8, 1);
                parents[0] = theirs;
            } else {
                parents = try allocator.realloc(parents, 2);
                parents[1] = theirs;
            }
        }
    }

    const now_ts = std.Io.Timestamp.now(io.io, .real);
    const now: i64 = @intCast(@divTrunc(now_ts.nanoseconds, std.time.ns_per_s));

    const commit = object.Commit{
        .tree = tree_sha,
        .parents = parents,
        .author = .{ .name = author_name, .email = author_email, .timestamp = now, .timezone = "+0000" },
        .committer = .{ .name = author_name, .email = author_email, .timestamp = now, .timezone = "+0000" },
        .message = message.?,
    };

    const commit_sha = try store.write(allocator, io.io, object.GitObject{ .commit = commit });

    // Update HEAD. A detached HEAD holds a raw SHA rather than a `ref:` line,
    // and the old code only handled the symbolic case: the commit object was
    // written and the command reported success, orphaning the commit
    // immediately. Git updates a detached HEAD in place, so we do too.
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);

    var head_was_detached = false;
    if (std.Io.Dir.cwd().openFile(io.io, head_path, .{})) |head_file_open| {
        var file = head_file_open;
        defer file.close(io.io);
        var buf: [256]u8 = undefined;
        const n = file.readStreaming(io.io, &.{&buf}) catch 0;
        const content = std.mem.trim(u8, buf[0..n], &[_]u8{ '\n', '\r', ' ' });

        if (std.mem.startsWith(u8, content, "ref: ")) {
            const target = content[5..];
            try refs_manager.write(allocator, io.io, target, commit_sha);
        } else {
            head_was_detached = true;
            const hex_sha = Sha1.hex(commit_sha);
            var wbuf: [64]u8 = undefined;
            const line = try std.fmt.bufPrint(&wbuf, "{s}\n", .{hex_sha});
            var f = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
            defer f.close(io.io);
            try std.Io.File.writeStreamingAll(f, io.io, line);
        }
    } else |_| {
        try io.eprint("error: could not update HEAD\n", .{});
        std.process.exit(1);
    }

    const hex = Sha1.hex(commit_sha);
    if (amend) {
        try io.print("[{s}] {s} (amend)\n", .{ hex[0..7], message.? });
    } else if (head_was_detached) {
        // git prints the "(root-commit)" / "(no branch)" style hint; the
        // detached case is the important part: the commit is now reachable.
        try io.print("[{s}] {s} (HEAD detached)\n", .{ hex[0..7], message.? });
    } else {
        try io.print("[{s}] {s}\n", .{ hex[0..7], message.? });
    }

    for (parents) |_| {}
    allocator.free(parents);

    // Rebuild index from committed tree to keep status accurate
    idx.deinit(allocator);
    idx = index_mod.Index.init(allocator);
    rebuildIndexFromTree(&idx, store, allocator, io.io, tree_sha, "");
    try idx.writeToFile(repo.worktree_dir, allocator, io.io);
    idx.deinit(allocator);

    // The merge is finished: drop the in-progress state so the next `gitz
    // merge` or `gitz status` does not think one is still open.
    merge_cmd.clearMergeState(allocator, git_dir, io) catch {};
}

/// Read MERGE_MSG written by a conflicted merge.
///
/// Returns an owned copy: the command allocator is an arena, and freeing a
/// buffer that happens to be the arena's last allocation hands the memory back
/// for reuse, so handing out a slice into a temporary file buffer would leave
/// the message dangling by the time the commit is written.
fn mergeMessage(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) ?[]const u8 {
    const p = std.fmt.allocPrint(allocator, "{s}/MERGE_MSG", .{git_dir}) catch return null;
    defer allocator.free(p);
    const content = io.readFileAlloc(p) catch return null;
    defer allocator.free(content);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

/// Whether two commits point at the same tree, meaning the index records no
/// change relative to HEAD.
fn headTreeEquals(
    store: storage_mod.StorageBackend,
    allocator: std.mem.Allocator,
    io: Io,
    head_sha: [20]u8,
    index_tree: [20]u8,
) bool {
    if (std.mem.eql(u8, &head_sha, &index_tree)) return true;
    const head_obj = store.read(allocator, io.io, head_sha) catch return false;
    defer head_obj.deinit(allocator);
    const head_commit = switch (head_obj) {
        .commit => |c| c,
        else => return false,
    };
    return std.mem.eql(u8, &head_commit.tree, &index_tree);
}

/// Recursively rebuild index entries from a tree object
fn rebuildIndexFromTree(idx: *index_mod.Index, store: storage_mod.StorageBackend, allocator: std.mem.Allocator, io: std.Io, tree_sha: [20]u8, prefix: []const u8) void {
    const tree_obj = store.read(allocator, io, tree_sha) catch return;
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        if (entry.mode == 0o040000) {
            // Directory — recurse
            const sub_prefix = if (prefix.len > 0)
                std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name }) catch continue
            else
                allocator.dupe(u8, entry.name) catch continue;
            rebuildIndexFromTree(idx, store, allocator, io, entry.sha, sub_prefix);
            allocator.free(sub_prefix);
        } else {
            // File — add to index
            const full_path = if (prefix.len > 0)
                std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name }) catch continue
            else
                allocator.dupe(u8, entry.name) catch continue;
            idx.entries.append(allocator, .{
                .sha = entry.sha,
                .mode = entry.mode,
                .name = full_path,
            }) catch {
                allocator.free(full_path);
            };
        }
    }
}

fn autoStageAll(allocator: std.mem.Allocator, repo: Repo, io: Io) !void {
    var idx = try index_mod.Index.readFromFile(allocator, repo.worktree_dir, io.io);
    defer idx.deinit(allocator);

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);
    var modified = false;

    // Only update entries that have actually changed
    var i: usize = 0;
    while (i < idx.entries.items.len) {
        const entry = &idx.entries.items[i];
        const clean_name = if (std.mem.startsWith(u8, entry.name, "./"))
            entry.name[2..]
        else
            entry.name;

        // A tracked file missing from the worktree has been deleted.
        // `git commit -a` stages that deletion; skipping it made the commit
        // still contain the file, so it came back on the next checkout while
        // the user's working tree no longer had it.
        const content = std.Io.Dir.cwd().readFileAlloc(io.io, clean_name, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => {
                // `entry` points into the ArrayList, which orderedRemove
                // shifts, so the name is captured before the removal.
                const removed_name = entry.name;
                _ = idx.entries.orderedRemove(i);
                allocator.free(removed_name);
                modified = true;
                continue;
            },
            else => continue,
        };
        defer allocator.free(content);

        // A git blob SHA covers the `blob <len>\0` header, so hashing the raw
        // content never matched and every file looked modified.
        const work_sha = checkout_mod.blobSha(allocator, content) catch continue;

        // The mode lives in the index, so it is refreshed whether or not the
        // content changed: `chmod +x` alone has to be recorded as 100755.
        if (std.Io.Dir.cwd().statFile(io.io, clean_name, .{})) |stat| {
            entry.size = @intCast(@min(stat.size, std.math.maxInt(u32)));
            entry.mtime = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));
            entry.ctime = @intCast(@divTrunc(stat.ctime.nanoseconds, std.time.ns_per_s));
            entry.mode = if (stat.permissions.toMode() & 0o111 != 0) 0o100755 else 0o100644;
        } else |_| {}

        if (!std.mem.eql(u8, &work_sha, &entry.sha)) {
            const blob = object.GitObject{ .blob = .{ .content = content } };
            const new_sha = try store.write(allocator, io.io, blob);
            entry.sha = new_sha;
            modified = true;
        }
        i += 1;
    }

    // Only write if something actually changed
    if (modified) {
        try idx.writeToFile(repo.worktree_dir, allocator, io.io);
    }
}
