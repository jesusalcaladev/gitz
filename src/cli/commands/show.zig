const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");
const diff_mod = @import("../../core/diff.zig");
const ui = @import("../../util/ui.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var stat_only = false;
    var sha_str: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--stat")) {
            stat_only = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            sha_str = arg;
        }
    }

    // Default to HEAD
    const refs_manager = refs_mod.Refs.init(git_dir);
    var resolved_sha: [20]u8 = undefined;

    if (sha_str) |s| {
        resolved_sha = resolveSha(allocator, &refs_manager, io.io, git_dir, s) catch |err| {
            try io.eprint("error: cannot resolve '{s}': {}\n", .{ s, err });
            return;
        };
    } else {
        resolved_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
            try io.eprint("error: no commits yet\n", .{});
            return;
        };
    }

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const obj = store.read(allocator, io.io, resolved_sha) catch {
        try io.eprint("error: object {s} not found\n", .{ Sha1.hex(resolved_sha)[0..7] });
        return;
    };

    switch (obj) {
        .commit => |commit| {
            try showCommit(allocator, store, io, resolved_sha, commit, stat_only);
        },
        .tag => |tag| {
            try io.print("{s}tag {s}{s}{s}\n", .{ ui.c.yellow, ui.c.bold, tag.tag_name, ui.c.reset });
            try io.print("Tagger: {s} <{s}>\n", .{ tag.tagger.name, tag.tagger.email });
            var tag_ts_buf: [32]u8 = undefined;
            try io.print("Date:   {s}\n", .{formatTimestamp(tag.tagger.timestamp, &tag_ts_buf)});
            try io.print("\n    {s}\n\n", .{tag.message});

            // Show the tagged object
            const tagged_obj = store.read(allocator, io.io, tag.object) catch return;
            switch (tagged_obj) {
                .commit => |c| try showCommit(allocator, store, io, tag.object, c, stat_only),
                else => {
                    const hex = Sha1.hex(tag.object);
                    try io.print("Object: {s}\n", .{hex[0..7]});
                },
            }
        },
        .tree => {
            try io.print("tree {s}\n", .{Sha1.hex(resolved_sha)[0..7]});
            try io.print("(use 'gitz ls-tree' to list contents)\n", .{});
        },
        .blob => |blob| {
            try io.print("blob {s}\n", .{Sha1.hex(resolved_sha)[0..7]});
            try io.print("{s}", .{blob.content});
        },
    }
}

fn showCommit(
    allocator: std.mem.Allocator,
    store: storage_mod.StorageBackend,
    io: Io,
    sha: [20]u8,
    commit: object.Commit,
    stat_only: bool,
) !void {
    const hex = Sha1.hex(sha);

    // Header
    try io.print("{s}commit {s}{s}{s}\n", .{ ui.c.yellow, ui.c.bold, hex[0..7], ui.c.reset });

    // Sanitize author
    var sane_buf: [64]u8 = undefined;
    var sane_len: usize = 0;
    for (commit.author.name) |ch| {
        if (ch >= 0x20 and ch < 0x7f and sane_len < sane_buf.len) {
            sane_buf[sane_len] = ch;
            sane_len += 1;
        }
    }
    const author_name = if (sane_len > 0) sane_buf[0..sane_len] else "unknown";

    try io.print("{s}Author:{s} {s}{s}{s} <{s}>\n", .{
        ui.c.dim, ui.c.reset, ui.c.bold, author_name, ui.c.reset, commit.author.email,
    });
    var ts_buf: [32]u8 = undefined;
    try io.print("{s}Date:{s}   {s}\n", .{ ui.c.dim, ui.c.reset, formatTimestamp(commit.author.timestamp, &ts_buf) });

    // Message (indented)
    try io.print("\n", .{});
    var msg_lines = std.mem.splitScalar(u8, commit.message, '\n');
    while (msg_lines.next()) |line| {
        try io.print("    {s}\n", .{line});
    }
    try io.print("\n", .{});

    // Diff against parent
    if (commit.parents.len > 0) {
        if (stat_only) {
            try showStatDiff(allocator, store, io, commit.parents[0], commit.tree);
        } else {
            try showFullDiff(allocator, store, io, commit.parents[0], commit.tree);
        }
    } else {
        // First commit — show all files as added
        if (stat_only) {
            try showStatDiff(allocator, store, io, null, commit.tree);
        } else {
            try showFullDiff(allocator, store, io, null, commit.tree);
        }
    }
}

fn showFullDiff(
    allocator: std.mem.Allocator,
    store: storage_mod.StorageBackend,
    io: Io,
    parent_sha: ?[20]u8,
    tree_sha: [20]u8,
) !void {
    // Collect parent files
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
        collectFiles(allocator, store, io.io, parent_commit.tree, "", &parent_files);
    }

    // Collect commit files
    var commit_files = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = commit_files.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        commit_files.deinit();
    }
    collectFiles(allocator, store, io.io, tree_sha, "", &commit_files);

    // Modified + added
    var commit_iter = commit_files.iterator();
    while (commit_iter.next()) |entry| {
        const path = entry.key_ptr.*;
        const new_content = entry.value_ptr.*;

        if (parent_files.get(path)) |old_content| {
            if (std.mem.eql(u8, old_content, new_content)) continue;

            try io.print("{s}diff --git a/{s} b/{s}{s}\n", .{ ui.c.cyan, path, path, ui.c.reset });
            try io.print("{s}--- a/{s}{s}\n", .{ ui.c.red, path, ui.c.reset });
            try io.print("{s}+++ b/{s}{s}\n", .{ ui.c.bgreen, path, ui.c.reset });

            var old_lines = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
            defer old_lines.deinit(allocator);
            var old_iter = std.mem.splitScalar(u8, old_content, '\n');
            while (old_iter.next()) |l| try old_lines.append(allocator, l);

            var new_lines = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
            defer new_lines.deinit(allocator);
            var new_iter = std.mem.splitScalar(u8, new_content, '\n');
            while (new_iter.next()) |l| try new_lines.append(allocator, l);

            const d = try diff_mod.myersDiff(allocator, old_lines.items, new_lines.items);
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
            try io.print("{s}new file mode 100644{s}\n", .{ ui.c.bgreen, ui.c.reset });
            try io.print("{s}diff --git a/{s} b/{s}{s}\n", .{ ui.c.cyan, path, path, ui.c.reset });
            try io.print("{s}--- /dev/null{s}\n", .{ ui.c.red, ui.c.reset });
            try io.print("{s}+++ b/{s}{s}\n", .{ ui.c.bgreen, path, ui.c.reset });

            var lines = std.mem.splitScalar(u8, new_content, '\n');
            while (lines.next()) |line| {
                try io.print("{s}+{s}{s}\n", .{ ui.c.bgreen, line, ui.c.reset });
            }
        }
    }

    // Deleted files
    var parent_iter = parent_files.iterator();
    while (parent_iter.next()) |entry| {
        const path = entry.key_ptr.*;
        if (!commit_files.contains(path)) {
            try io.print("{s}deleted file mode 100644{s}\n", .{ ui.c.red, ui.c.reset });
            try io.print("{s}diff --git a/{s} b/{s}{s}\n", .{ ui.c.cyan, path, path, ui.c.reset });
            try io.print("{s}--- a/{s}{s}\n", .{ ui.c.red, path, ui.c.reset });
            try io.print("{s}+++ /dev/null{s}\n", .{ ui.c.bgreen, ui.c.reset });

            var lines = std.mem.splitScalar(u8, entry.value_ptr.*, '\n');
            while (lines.next()) |line| {
                try io.print("{s}-{s}{s}\n", .{ ui.c.red, line, ui.c.reset });
            }
        }
    }
}

fn showStatDiff(
    allocator: std.mem.Allocator,
    store: storage_mod.StorageBackend,
    io: Io,
    parent_sha: ?[20]u8,
    tree_sha: [20]u8,
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
        const parent_obj = store.read(allocator, io.io, ps) catch return;
        const parent_commit = switch (parent_obj) {
            .commit => |c| c,
            else => return,
        };
        collectFiles(allocator, store, io.io, parent_commit.tree, "", &parent_files);
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
    collectFiles(allocator, store, io.io, tree_sha, "", &commit_files);

    var total_add: u32 = 0;
    var total_del: u32 = 0;

    var commit_iter = commit_files.iterator();
    while (commit_iter.next()) |entry| {
        const path = entry.key_ptr.*;
        const new_content = entry.value_ptr.*;

        if (parent_files.get(path)) |old_content| {
            if (std.mem.eql(u8, old_content, new_content)) continue;

            const add = countLines(new_content);
            const del = countLines(old_content);
            total_add += add;
            total_del += del;

            var bar_buf: [30]u8 = undefined;
            var bar_len: usize = 0;
            const total = add + del;
            const add_w = if (total > 0) add * 15 / total else 0;
            const del_w = 15 - add_w;

            for (0..add_w) |i| bar_buf[bar_len + i] = '#';
            bar_len += add_w;
            for (0..del_w) |i| bar_buf[bar_len + i] = '.';
            bar_len += del_w;

            try io.print(" {s}{s}{s} | {s}+{d}{s} {s}-{d}{s}  {s}{s}{s}\n", .{
                ui.c.bold, path, ui.c.reset,
                ui.c.bgreen, add, ui.c.reset,
                ui.c.red, del, ui.c.reset,
                ui.c.dim, bar_buf[0..bar_len], ui.c.reset,
            });
        } else {
            const add = countLines(new_content);
            total_add += add;
            try io.print(" {s}{s}{s} | {s}+{d}{s}  {s}new file{s}\n", .{
                ui.c.bgreen, path, ui.c.reset,
                ui.c.bgreen, add, ui.c.reset,
                ui.c.dim, ui.c.reset,
            });
        }
    }

    // Deleted
    var parent_iter = parent_files.iterator();
    while (parent_iter.next()) |entry| {
        if (!commit_files.contains(entry.key_ptr.*)) {
            const del = countLines(entry.value_ptr.*);
            total_del += del;
            try io.print(" {s}{s}{s} | {s}-{d}{s}  {s}deleted{s}\n", .{
                ui.c.red, entry.key_ptr.*, ui.c.reset,
                ui.c.red, del, ui.c.reset,
                ui.c.dim, ui.c.reset,
            });
        }
    }

    if (total_add + total_del > 0) {
        try io.print(" {s}{d}{s} file{s} changed", .{
            ui.c.bold, (commit_files.count()), ui.c.reset,
            if (commit_files.count() != 1) "s" else "",
        });
        if (total_add > 0) try io.print(", {s}+{d}{s} insertion{s}", .{ ui.c.bgreen, total_add, ui.c.reset, if (total_add != 1) "s" else "" });
        if (total_del > 0) try io.print(", {s}-{d}{s} deletion{s}", .{ ui.c.red, total_del, ui.c.reset, if (total_del != 1) "s" else "" });
        try io.print("\n", .{});
    }
}

fn collectFiles(
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
            collectFiles(allocator, store, io, entry.sha, full_path, files);
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
            const owned = allocator.dupe(u8, content) catch {
                allocator.free(full_path);
                continue;
            };
            files.put(full_path, owned) catch {
                allocator.free(full_path);
                allocator.free(owned);
            };
        }
    }
}

fn resolveSha(
    allocator: std.mem.Allocator,
    refs_manager: *const refs_mod.Refs,
    io: std.Io,
    git_dir: []const u8,
    name: []const u8,
) ![20]u8 {
    // Try as HEAD
    if (std.mem.eql(u8, name, "HEAD")) {
        return refs_manager.read(allocator, io, "HEAD") catch return error.RefNotFound;
    }

    // Try HEAD~N
    if (std.mem.startsWith(u8, name, "HEAD~")) {
        const n_str = name[5..];
        const n = std.fmt.parseInt(usize, n_str, 10) catch return error.RefNotFound;
        var current = refs_manager.read(allocator, io, "HEAD") catch return error.RefNotFound;
        const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io, git_dir);
        for (0..n) |_| {
            const obj = store.read(allocator, io, current) catch return error.RefNotFound;
            const commit = switch (obj) {
                .commit => |c| c,
                else => return error.RefNotFound,
            };
            if (commit.parents.len == 0) return error.RefNotFound;
            current = commit.parents[0];
        }
        return current;
    }

    // Try as branch
    const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
    defer allocator.free(branch_ref);
    if (refs_manager.read(allocator, io, branch_ref)) |sha| return sha else |_| {}

    // Try as tag
    const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{name});
    defer allocator.free(tag_ref);
    if (refs_manager.read(allocator, io, tag_ref)) |sha| return sha else |_| {}

    // Try as hex prefix (at least 4 chars)
    if (name.len >= 4) {
        var padded: [40]u8 = undefined;
        @memcpy(&padded, name);
        @memset(padded[name.len..], '0');
        return Sha1.fromHex(&padded) catch return error.RefNotFound;
    }

    return error.RefNotFound;
}

fn formatTimestamp(ts: i64, buf: []u8) []const u8 {
    const epoch_seconds = @as(u64, @intCast(ts));
    const days_since_epoch = @divTrunc(epoch_seconds, 86400);
    const seconds_in_day = @mod(epoch_seconds, 86400);

    const year = 1970 + @divTrunc(days_since_epoch, 365);
    const month = @mod(@divTrunc(days_since_epoch, 30), 12) + 1;
    const day = @mod(days_since_epoch, 30) + 1;
    const hour = @divTrunc(seconds_in_day, 3600);
    const minute = @mod(@divTrunc(seconds_in_day, 60), 60);

    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    return std.fmt.bufPrint(buf, "{s} {d:2} {d:2}:{d:0>2}:00 {d}", .{
        month_names[month - 1],
        day,
        hour,
        minute,
        year,
    }) catch "unknown date";
}

fn countLines(content: []const u8) u32 {
    if (content.len == 0) return 0;
    var count: u32 = 1;
    for (content) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}
