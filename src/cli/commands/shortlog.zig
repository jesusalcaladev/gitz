const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");
const ui = @import("../../util/ui.zig");

const AuthorStat = struct {
    name: []const u8,
    count: u32,
};

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var sort_by_count = false;
    var summary_only = false;
    var count: usize = 200;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--summary")) {
            summary_only = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--numbered")) {
            sort_by_count = true;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--email")) {
            // Show emails too
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            // Parse -N style count
            if (arg.len > 1) {
                const num = std.fmt.parseInt(usize, arg[1..], 10) catch null;
                if (num) |n| {
                    count = n;
                }
            }
        }
    }

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const refs_manager = refs_mod.Refs.init(git_dir);

    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
        try io.print("No commits yet.\n", .{});
        return;
    };

    // Collect all commits from HEAD
    var commits = std.ArrayList([20]u8){ .items = &.{}, .capacity = 0 };
    defer commits.deinit(allocator);

    collectCommits(allocator, io.io, store, head_sha, &commits, count);

    // Aggregate by author
    var author_map = std.StringHashMap(u32).init(allocator);
    defer {
        var iter = author_map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        author_map.deinit();
    }

    var commit_msgs = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = commit_msgs.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        commit_msgs.deinit();
    }

    for (commits.items) |sha| {
        const obj = store.read(allocator, io.io, sha) catch continue;
        const commit = switch (obj) {
            .commit => |c| c,
            else => continue,
        };

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

        const owned_name = allocator.dupe(u8, author_name) catch continue;
        const gop = author_map.getOrPut(owned_name) catch {
            allocator.free(owned_name);
            continue;
        };
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
            allocator.free(owned_name);
        } else {
            gop.value_ptr.* = 1;
            // Store first commit message for this author
            var msg_lines = std.mem.splitScalar(u8, commit.message, '\n');
            if (msg_lines.next()) |first_line| {
                const owned_msg = allocator.dupe(u8, first_line) catch "";
                commit_msgs.put(owned_name, owned_msg) catch {};
            }
        }
    }

    // Convert to sortable list
    var stats = std.ArrayList(AuthorStat){ .items = &.{}, .capacity = 0 };
    defer stats.deinit(allocator);

    var iter = author_map.iterator();
    while (iter.next()) |entry| {
        try stats.append(allocator, .{
            .name = entry.key_ptr.*,
            .count = entry.value_ptr.*,
        });
    }

    // Sort by count (descending) or by name
    if (sort_by_count) {
        std.mem.sort(AuthorStat, stats.items, {}, struct {
            fn cmp(_: void, a: AuthorStat, b: AuthorStat) bool {
                return a.count > b.count;
            }
        }.cmp);
    } else {
        std.mem.sort(AuthorStat, stats.items, {}, struct {
            fn cmp(_: void, a: AuthorStat, b: AuthorStat) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.cmp);
    }

    // Output
    const total_commits: u32 = @intCast(commits.items.len);
    var total_lines_buf: [32]u8 = undefined;
    const total_str = try std.fmt.bufPrint(&total_lines_buf, "{d}", .{total_commits});

    for (stats.items) |stat| {
        if (summary_only) {
            try io.print("{s}{d:>5}{s}  {s}{s}{s}\n", .{
                ui.c.yellow, stat.count, ui.c.reset,
                ui.c.bold, stat.name, ui.c.reset,
            });
        } else {
            // Show first commit message for each author
            if (commit_msgs.get(stat.name)) |msg| {
                try io.print("{s}{d:>5}{s}  {s}{s}{s}\n", .{
                    ui.c.yellow, stat.count, ui.c.reset,
                    ui.c.bold, stat.name, ui.c.reset,
                });
                try io.print("      {s}{s}{s}\n", .{ ui.c.dim, msg, ui.c.reset });
            } else {
                try io.print("{s}{d:>5}{s}  {s}{s}{s}\n", .{
                    ui.c.yellow, stat.count, ui.c.reset,
                    ui.c.bold, stat.name, ui.c.reset,
                });
            }
        }
    }

    // Footer
    if (stats.items.len > 0) {
        try io.print("\n{s}── {d} contributor{s}, {s} commit{s} total ──{s}\n", .{
            ui.c.dim,
            stats.items.len,
            if (stats.items.len != 1) "s" else "",
            total_str,
            if (total_commits != 1) "s" else "",
            ui.c.reset,
        });
    }
}

fn collectCommits(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage_mod.StorageBackend,
    sha: [20]u8,
    result: *std.ArrayList([20]u8),
    max_count: usize,
) void {
    var visited = std.AutoHashMap([20]u8, void).init(allocator);
    defer visited.deinit();

    var queue = std.ArrayList([20]u8){ .items = &.{}, .capacity = 0 };
    defer queue.deinit(allocator);

    queue.append(allocator, sha) catch return;
    visited.put(sha, {}) catch return;

    while (queue.items.len > 0 and result.items.len < max_count) {
        const current = queue.swapRemove(0);
        result.append(allocator, current) catch continue;

        const obj = store.read(allocator, io, current) catch continue;
        const commit = switch (obj) {
            .commit => |c| c,
            else => continue,
        };

        for (commit.parents) |parent| {
            if (!visited.contains(parent)) {
                visited.put(parent, {}) catch continue;
                queue.append(allocator, parent) catch continue;
            }
        }
    }
}
