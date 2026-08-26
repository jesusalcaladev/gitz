const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");
const diff_mod = @import("../../core/diff.zig");
const ui = @import("../../util/ui.zig");

/// File change summary for review output.
const FileChange = struct {
    path: []const u8,
    additions: u32,
    deletions: u32,
};

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var base_branch: ?[]const u8 = null;
    var target_branch: ?[]const u8 = null;
    var stat_only = false;
    var context_lines: usize = 3;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--stat")) {
            stat_only = true;
        } else if (std.mem.eql(u8, arg, "-C") and i + 1 < args.len) {
            i += 1;
            context_lines = std.fmt.parseInt(usize, args[i], 10) catch 3;
        } else if (std.mem.startsWith(u8, arg, "--context=")) {
            context_lines = std.fmt.parseInt(usize, arg[10..], 10) catch 3;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (base_branch == null) {
                base_branch = arg;
            } else if (target_branch == null) {
                target_branch = arg;
            }
        }
    }

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    _ = refs_mod.Refs.init(git_dir);

    // Determine base and target
    const refs_manager2 = refs_mod.Refs.init(git_dir);

    var base_sha: [20]u8 = undefined;
    var target_sha: [20]u8 = undefined;

    // Resolve target (defaults to HEAD)
    if (target_branch) |tb| {
        target_sha = resolveRef(allocator, &refs_manager2, io.io, tb) catch |err| {
            try io.eprint("error: cannot resolve target '{s}': {}\n", .{ tb, err });
            return;
        };
    } else {
        const head_sha = refs_manager2.read(allocator, io.io, "HEAD") catch {
            try io.eprint("error: no commits yet\n", .{});
            return;
        };
        target_sha = head_sha;
    }

    // Resolve base (defaults to main/master)
    if (base_branch) |bb| {
        base_sha = resolveRef(allocator, &refs_manager2, io.io, bb) catch |err| {
            try io.eprint("error: cannot resolve base '{s}': {}\n", .{ bb, err });
            return;
        };
    } else {
        // Try main, then master
        base_sha = resolveRef(allocator, &refs_manager2, io.io, "main") catch
            resolveRef(allocator, &refs_manager2, io.io, "master") catch {
            try io.eprint("error: cannot find base branch (tried main, master)\n", .{});
            return;
        };
    }

    // Collect commits between base and target
    var commits = std.ArrayList([20]u8){ .items = &.{}, .capacity = 0 };
    defer commits.deinit(allocator);

    collectCommitsBetween(allocator, store, base_sha, target_sha, &commits);

    if (commits.items.len == 0) {
        try io.print("{s}✓{s} Nothing to review — branches are in sync\n", .{ ui.c.bgreen, ui.c.reset });
        return;
    }

    // Header
    const base_hex = Sha1.hex(base_sha);
    const target_hex = Sha1.hex(target_sha);
    try io.print("\n{s}{s}Review{s} {s}{s}{s} {s}→{s} {s}{s}{s} ({d} commit{s})\n\n", .{
        ui.c.bold, ui.c.bcyan, ui.c.reset,
        ui.c.yellow, base_hex[0..7], ui.c.reset,
        ui.c.dim, ui.c.reset,
        ui.c.bgreen, target_hex[0..7], ui.c.reset,
        commits.items.len,
        if (commits.items.len != 1) "s" else "",
    });

    // Collect per-file change stats by diffing consecutive trees
    var file_changes = std.StringHashMap(FileChange).init(allocator);
    defer {
        var iter = file_changes.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        file_changes.deinit();
    }

    // Walk commits from target back to base, collecting tree diffs
    var current_sha = target_sha;
    var commits_shown: usize = 0;

    while (commits_shown < commits.items.len) {
        const obj = store.read(allocator, io.io, current_sha) catch break;
        const commit = switch (obj) {
            .commit => |c| c,
            else => break,
        };

        // Show each commit in review format
        const hex = Sha1.hex(current_sha);
        // Sanitize author name
        var sane_buf: [64]u8 = undefined;
        var sane_len: usize = 0;
        for (commit.author.name) |ch| {
            if (ch >= 0x20 and ch < 0x7f and sane_len < sane_buf.len) {
                sane_buf[sane_len] = ch;
                sane_len += 1;
            }
        }
        const author_name = if (sane_len > 0) sane_buf[0..sane_len] else "unknown";

        // Get relative timestamp
        const now_ts = std.Io.Timestamp.now(io.io, .real);
        const now: i64 = @intCast(@divTrunc(now_ts.nanoseconds, std.time.ns_per_s));
        const age_seconds = now - commit.author.timestamp;
        const age_str = formatAge(allocator, age_seconds);
        defer allocator.free(age_str);

        try io.print("{s}commit {s}{s}{s} {s}({s} ago){s}\n", .{
            ui.c.yellow, ui.c.bold, hex[0..7], ui.c.reset,
            ui.c.dim, age_str, ui.c.reset,
        });
        try io.print("{s}Author:{s} {s}{s}{s} <{s}>\n", .{
            ui.c.dim, ui.c.reset, ui.c.bold, author_name, ui.c.reset, commit.author.email,
        });
        // Indented message
        var msg_lines = std.mem.splitScalar(u8, commit.message, '\n');
        if (msg_lines.next()) |first_line| {
            try io.print("\n    {s}{s}{s}\n", .{ ui.c.bold, first_line, ui.c.reset });
        }

        // Diff this commit against its parent
        if (!stat_only and commit.parents.len > 0) {
            try showCommitDiff(allocator, store, io, commit.parents[0], commit.tree, context_lines);
        } else if (!stat_only and commit.parents.len == 0) {
            // First commit — show all files as added
            try showCommitDiff(allocator, store, io, null, commit.tree, context_lines);
        }

        // Collect file-level stats
        if (commit.parents.len > 0) {
            try collectFileStats(allocator, store, io.io, commit.parents[0], commit.tree, &file_changes);
        } else {
            try collectFileStats(allocator, store, io.io, null, commit.tree, &file_changes);
        }

        try io.print("\n", .{});

        // Move to parent
        if (commit.parents.len > 0) {
            current_sha = commit.parents[0];
        } else {
            break;
        }
        commits_shown += 1;
    }

    // Summary
    var total_add: u32 = 0;
    var total_del: u32 = 0;
    var summary_iter = file_changes.iterator();
    while (summary_iter.next()) |entry| {
        total_add += entry.value_ptr.additions;
        total_del += entry.value_ptr.deletions;
    }

    const file_count = file_changes.count();
    if (file_count > 0) {
        try io.print("{s}{s}── Summary ──{s}\n", .{ ui.c.bold, ui.c.cyan, ui.c.reset });
        try io.print("  {s}{d}{s} file{s} changed", .{
            ui.c.yellow, file_count, ui.c.reset,
            if (file_count != 1) "s" else "",
        });
        if (total_add > 0) {
            try io.print(", {s}+{d}{s} insertion{s}", .{
                ui.c.bgreen, total_add, ui.c.reset,
                if (total_add != 1) "s" else "",
            });
        }
        if (total_del > 0) {
            try io.print(", {s}-{d}{s} deletion{s}", .{
                ui.c.red, total_del, ui.c.reset,
                if (total_del != 1) "s" else "",
            });
        }
        try io.print("\n", .{});

        // Per-file stats (top 20)
        var stats = std.ArrayList(struct { path: []const u8, add: u32, del: u32 }){ .items = &.{}, .capacity = 0 };
        defer stats.deinit(allocator);

        var stat_iter2 = file_changes.iterator();
        while (stat_iter2.next()) |entry| {
            try stats.append(allocator, .{
                .path = entry.key_ptr.*,
                .add = entry.value_ptr.additions,
                .del = entry.value_ptr.deletions,
            });
        }

        // Sort by total changes descending
        std.mem.sort(@TypeOf(stats.items[0]), stats.items, {}, struct {
            fn cmp(_: void, a: @TypeOf(stats.items[0]), b: @TypeOf(stats.items[0])) bool {
                return (a.add + a.del) > (b.add + b.del);
            }
        }.cmp);

        const show_count = @min(stats.items.len, 20);
        for (stats.items[0..show_count]) |s| {
            var bar_buf: [40]u8 = undefined;
            var bar_len: usize = 0;
            const total = s.add + s.del;
            const add_width = if (total > 0) s.add * 20 / total else 0;
            const del_width = 20 - add_width;

            for (0..add_width) |ai| bar_buf[bar_len + ai] = '#';
            bar_len += add_width;
            for (0..del_width) |di| bar_buf[bar_len + di] = '.';
            bar_len += del_width;

            try io.print("  {s}{s}{s} {s}+{d}{s} {s}-{d}{s}  {s}{s}{s}\n", .{
                ui.c.bold, s.path, ui.c.reset,
                ui.c.bgreen, s.add, ui.c.reset,
                ui.c.red, s.del, ui.c.reset,
                ui.c.dim, bar_buf[0..bar_len], ui.c.reset,
            });
        }
        if (stats.items.len > show_count) {
            try io.print("  {s}... and {d} more files{s}\n", .{
                ui.c.dim, stats.items.len - show_count, ui.c.reset,
            });
        }
    }

    try io.print("\n{s}{s}Review complete{s} — {d} commit{s}, {d} file{s} changed, +{d}/-{d}\n\n", .{
        ui.c.bold, ui.c.bgreen, ui.c.reset,
        commits.items.len, if (commits.items.len != 1) "s" else "",
        file_count, if (file_count != 1) "s" else "",
        total_add, total_del,
    });
}

/// Resolve a ref name (branch, tag, SHA prefix) to a full SHA.
fn resolveRef(allocator: std.mem.Allocator, refs_manager: *const refs_mod.Refs, io: std.Io, name: []const u8) ![20]u8 {
    // Try as full branch
    const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
    defer allocator.free(branch_ref);
    if (refs_manager.read(allocator, io, branch_ref)) |sha| {
        return sha;
    } else |_| {}

    // Try as tag
    const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{name});
    defer allocator.free(tag_ref);
    if (refs_manager.read(allocator, io, tag_ref)) |sha| {
        return sha;
    } else |_| {}

    // Try as remote branch
    const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}", .{name});
    defer allocator.free(remote_ref);
    if (refs_manager.read(allocator, io, remote_ref)) |sha| {
        return sha;
    } else |_| {}

    // Try as HEAD
    if (std.mem.eql(u8, name, "HEAD")) {
        return refs_manager.read(allocator, io, "HEAD") catch return error.RefNotFound;
    }

    // Try as hex SHA prefix (first 40 chars)
    if (name.len >= 4 and name.len <= 40) {
        var padded: [40]u8 = undefined;
        @memcpy(padded[0..name.len], name);
        for (name.len..40) |i| padded[i] = '0';
        const sha = Sha1.fromHex(&padded) catch return error.RefNotFound;
        return sha;
    }

    return error.RefNotFound;
}

/// Collect all commits reachable from `target` but not from `base`.
fn collectCommitsBetween(
    allocator: std.mem.Allocator,
    store: storage_mod.StorageBackend,
    base: [20]u8,
    target: [20]u8,
    result: *std.ArrayList([20]u8),
) void {
    // Mark all commits reachable from base
    var visited = std.AutoHashMap([20]u8, void).init(allocator);
    defer visited.deinit();

    markReachable(allocator, store, base, &visited);

    // Collect commits reachable from target but NOT from base
    collectUnique(allocator, store, target, &visited, result);
}

fn markReachable(
    allocator: std.mem.Allocator,
    store: storage_mod.StorageBackend,
    sha: [20]u8,
    visited: *std.AutoHashMap([20]u8, void),
) void {
    if (visited.get(sha)) |_| return;
    visited.put(sha, {}) catch return;

    const obj = store.read(allocator, undefined, sha) catch return;
    const commit = switch (obj) {
        .commit => |c| c,
        else => return,
    };

    for (commit.parents) |parent| {
        markReachable(allocator, store, parent, visited);
    }
}

fn collectUnique(
    allocator: std.mem.Allocator,
    store: storage_mod.StorageBackend,
    sha: [20]u8,
    base_reachable: *std.AutoHashMap([20]u8, void),
    result: *std.ArrayList([20]u8),
) void {
    if (base_reachable.get(sha)) |_| return;

    var already_added = std.AutoHashMap([20]u8, void).init(allocator);
    defer already_added.deinit();

    // BFS from target, collecting commits not in base_reachable
    var queue = std.ArrayList([20]u8){ .items = &.{}, .capacity = 0 };
    defer queue.deinit(allocator);

    queue.append(allocator, sha) catch return;
    already_added.put(sha, {}) catch return;

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);
        if (base_reachable.get(current)) |_| continue;

        result.append(allocator, current) catch continue;

        const obj = store.read(allocator, undefined, current) catch continue;
        const commit = switch (obj) {
            .commit => |c| c,
            else => continue,
        };

        for (commit.parents) |parent| {
            if (!already_added.contains(parent) and !base_reachable.contains(parent)) {
                already_added.put(parent, {}) catch continue;
                queue.append(allocator, parent) catch continue;
            }
        }
    }
}

/// Show the diff between two tree objects (parent..commit)
fn showCommitDiff(
    allocator: std.mem.Allocator,
    store: storage_mod.StorageBackend,
    io: Io,
    parent_sha: ?[20]u8,
    commit_tree: [20]u8,
    _: usize,
) !void {
    // Collect files from parent tree
    var parent_files = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = parent_files.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        parent_files.deinit();
    }

    if (parent_sha) |ps| {
        const parent_obj = store.read(allocator, io.io, ps) catch return;
        const parent_commit = switch (parent_obj) {
            .commit => |c| c,
            else => return,
        };
        collectFileContents(allocator, store, io.io, parent_commit.tree, "", &parent_files);
    }

    // Collect files from commit tree
    var commit_files = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = commit_files.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        commit_files.deinit();
    }
    collectFileContents(allocator, store, io.io, commit_tree, "", &commit_files);

    // Diff each changed file
    var commit_iter = commit_files.iterator();
    while (commit_iter.next()) |entry| {
        const path = entry.key_ptr.*;
        const new_content = entry.value_ptr.*;

        if (parent_files.get(path)) |old_content| {
            if (std.mem.eql(u8, old_content, new_content)) continue;

            // Modified — show diff
            try io.print("{s}diff --git a/{s} b/{s}{s}\n", .{ ui.c.cyan, path, path, ui.c.reset });
            try io.print("{s}--- a/{s}{s}\n", .{ ui.c.red, path, ui.c.reset });
            try io.print("{s}+++ b/{s}{s}\n", .{ ui.c.bgreen, path, ui.c.reset });

            // Split into lines
            var old_lines_list = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
            defer old_lines_list.deinit(allocator);
            var old_iter = std.mem.splitScalar(u8, old_content, '\n');
            while (old_iter.next()) |line| {
                try old_lines_list.append(allocator, line);
            }

            var new_lines_list = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
            defer new_lines_list.deinit(allocator);
            var new_iter = std.mem.splitScalar(u8, new_content, '\n');
            while (new_iter.next()) |line| {
                try new_lines_list.append(allocator, line);
            }

            const d = try diff_mod.myersDiff(allocator, old_lines_list.items, new_lines_list.items);
            defer d.deinit(allocator);

            for (d.hunks) |hunk| {
                try io.print("{s}@@ -{d},{d} +{d},{d} @@{s}\n", .{
                    ui.c.cyan, hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count, ui.c.reset,
                });
                for (hunk.lines) |line| {
                    switch (line.type) {
                        .context => try io.print(" {s}{s}{s}\n", .{ ui.c.dim, line.content, ui.c.reset }),
                        .added => try io.print("{s}+{s}{s}\n", .{ ui.c.bgreen, line.content, ui.c.reset }),
                        .deleted => try io.print("{s}-{s}{s}\n", .{ ui.c.red, line.content, ui.c.reset }),
                    }
                }
            }
        } else {
            // New file
            try io.print("{s}new file {s}+{d}{s}\n", .{ ui.c.bgreen, ui.c.reset, countLines(new_content), ui.c.reset });
            try io.print("{s}diff --git a/{s} b/{s}{s}\n", .{ ui.c.cyan, path, path, ui.c.reset });
            try io.print("{s}--- /dev/null{s}\n", .{ ui.c.red, ui.c.reset });
            try io.print("{s}+++ b/{s}{s}\n", .{ ui.c.bgreen, path, ui.c.reset });

            var lines = std.mem.splitScalar(u8, new_content, '\n');
            while (lines.next()) |line| {
                if (line.len > 0 or lines.rest().len > 0) {
                    try io.print("{s}+{s}{s}\n", .{ ui.c.bgreen, line, ui.c.reset });
                }
            }
        }
    }

    // Deleted files
    var parent_iter = parent_files.iterator();
    while (parent_iter.next()) |entry| {
        const path = entry.key_ptr.*;
        if (!commit_files.contains(path)) {
            try io.print("{s}deleted file {s}-{d}{s}\n", .{ ui.c.red, ui.c.reset, countLines(entry.value_ptr.*), ui.c.reset });
            try io.print("{s}diff --git a/{s} b/{s}{s}\n", .{ ui.c.cyan, path, path, ui.c.reset });
            try io.print("{s}--- a/{s}{s}\n", .{ ui.c.red, path, ui.c.reset });
            try io.print("{s}+++ /dev/null{s}\n", .{ ui.c.bgreen, ui.c.reset });
        }
    }
}

/// Collect all file contents from a tree recursively.
fn collectFileContents(
    allocator: std.mem.Allocator,
    store: storage_mod.StorageBackend,
    io: std.Io,
    tree_sha: [20]u8,
    prefix: []const u8,
    files: *std.StringHashMap([]const u8),
) void {
    const obj = store.read(allocator, io, tree_sha) catch return;
    const tree = switch (obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        const full_path = if (prefix.len > 0)
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name }) catch continue
        else
            allocator.dupe(u8, entry.name) catch continue;

        if (entry.mode == 0o040000) {
            collectFileContents(allocator, store, io, entry.sha, full_path, files);
            allocator.free(full_path);
        } else {
            const blob_obj = store.read(allocator, io, entry.sha) catch {
                allocator.free(full_path);
                continue;
            };
            const content = switch (blob_obj) {
                .blob => |b| b.content,
                else => {
                    allocator.free(full_path);
                    continue;
                },
            };
            const owned_content = allocator.dupe(u8, content) catch {
                allocator.free(full_path);
                continue;
            };
            files.put(full_path, owned_content) catch {
                allocator.free(full_path);
                allocator.free(owned_content);
            };
        }
    }
}

/// Collect per-file addition/deletion counts for summary.
fn collectFileStats(
    allocator: std.mem.Allocator,
    store: storage_mod.StorageBackend,
    io: std.Io,
    parent_sha: ?[20]u8,
    commit_tree: [20]u8,
    stats: *std.StringHashMap(FileChange),
) !void {
    var parent_files = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = parent_files.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        parent_files.deinit();
    }

    if (parent_sha) |ps| {
        const parent_obj = store.read(allocator, io, ps) catch return;
        const parent_commit = switch (parent_obj) {
            .commit => |c| c,
            else => return,
        };
        collectFileContents(allocator, store, io, parent_commit.tree, "", &parent_files);
    }

    var commit_files = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = commit_files.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        commit_files.deinit();
    }
    collectFileContents(allocator, store, io, commit_tree, "", &commit_files);

    // Modified + added
    var commit_iter = commit_files.iterator();
    while (commit_iter.next()) |entry| {
        const path = entry.key_ptr.*;
        const new_content = entry.value_ptr.*;

        const old_content = parent_files.get(path);

        var additions: u32 = 0;
        var deletions: u32 = 0;

        if (old_content) |old| {
            if (std.mem.eql(u8, old, new_content)) continue;

            // Count added/removed lines
            var old_lines = std.mem.splitScalar(u8, old, '\n');
            var new_lines = std.mem.splitScalar(u8, new_content, '\n');
            var old_set = std.StringHashMap(void).init(allocator);
            defer old_set.deinit();
            while (old_lines.next()) |l| {
                old_set.put(l, {}) catch {};
            }
            var new_set = std.StringHashMap(void).init(allocator);
            defer new_set.deinit();
            while (new_lines.next()) |l| {
                new_set.put(l, {}) catch {};
            }
            // Simplified: count length difference in lines as approximation
            additions = @intCast(countLines(new_content));
            deletions = @intCast(countLines(old));
        } else {
            additions = @intCast(countLines(new_content));
        }

        const owned_path = try allocator.dupe(u8, path);
        const gop = try stats.getOrPut(owned_path);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .path = owned_path, .additions = additions, .deletions = deletions };
        } else {
            gop.value_ptr.additions += additions;
            gop.value_ptr.deletions += deletions;
            allocator.free(owned_path);
        }
    }

    // Deleted
    var parent_iter = parent_files.iterator();
    while (parent_iter.next()) |entry| {
        const path = entry.key_ptr.*;
        if (!commit_files.contains(path)) {
            const owned_path = try allocator.dupe(u8, path);
            const gop = try stats.getOrPut(owned_path);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .path = owned_path, .additions = 0, .deletions = @intCast(countLines(entry.value_ptr.*)) };
            } else {
                gop.value_ptr.deletions += @intCast(countLines(entry.value_ptr.*));
                allocator.free(owned_path);
            }
        }
    }
}

fn countLines(content: []const u8) usize {
    if (content.len == 0) return 0;
    var count: usize = 1;
    for (content) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

fn formatAge(allocator: std.mem.Allocator, seconds: i64) []const u8 {
    if (seconds < 0) return "just now";
    if (seconds < 60) return "seconds ago";
    if (seconds < 3600) {
        const mins = @divTrunc(seconds, 60);
        return std.fmt.allocPrint(allocator, "{d} minute{s}", .{ mins, if (mins != 1) "s" else "" }) catch "unknown";
    }
    if (seconds < 86400) {
        const hours = @divTrunc(seconds, 3600);
        return std.fmt.allocPrint(allocator, "{d} hour{s}", .{ hours, if (hours != 1) "s" else "" }) catch "unknown";
    }
    const days = @divTrunc(seconds, 86400);
    return std.fmt.allocPrint(allocator, "{d} day{s}", .{ days, if (days != 1) "s" else "" }) catch "unknown";
}
