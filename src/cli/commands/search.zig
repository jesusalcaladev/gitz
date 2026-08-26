const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const ui = @import("../../util/ui.zig");

/// gitz search <pattern> [--message] [--context <N>] [--all] [--path <glob>]
///
/// Searches file contents (default) or commit messages (--message) for a
/// pattern. Displays matching lines with file names and line numbers, colored
/// and contextualised like `git grep`.
pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var search_messages = false;
    var context_lines: usize = 0;
    var search_all = false;
    var path_filter: ?[]const u8 = null;
    var pattern: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--message") or std.mem.eql(u8, arg, "-m")) {
            search_messages = true;
        } else if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
            search_all = true;
        } else if (std.mem.eql(u8, arg, "--context") or std.mem.eql(u8, arg, "-C")) {
            i += 1;
            if (i < args.len) {
                context_lines = std.fmt.parseInt(usize, args[i], 10) catch 3;
            }
        } else if (std.mem.startsWith(u8, arg, "--context=")) {
            context_lines = std.fmt.parseInt(usize, arg[10..], 10) catch 3;
        } else if (std.mem.eql(u8, arg, "--path") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i < args.len) path_filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // skip unknown flags
        } else {
            if (pattern == null) pattern = arg;
        }
    }

    const pat = pattern orelse {
        try io.eprint("usage: gitz search [--message] [--context <N>] [--all] [--path <glob>] <pattern>\n", .{});
        std.process.exit(1);
    };

    if (search_messages) {
        try searchCommitMessages(allocator, git_dir, pat, context_lines, search_all, io);
    } else {
        try searchFileContents(allocator, git_dir, pat, path_filter, io);
    }
}

// ── File content search ────────────────────────────────────────────────────

fn searchFileContents(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    pattern: []const u8,
    path_filter: ?[]const u8,
    io: Io,
) !void {
    const refs_manager = refs_mod.Refs.init(git_dir);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);

    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
        try io.print("No commits yet — nothing to search.\n", .{});
        return;
    };

    const commit_obj = store.read(allocator, io.io, head_sha) catch return;
    const commit = switch (commit_obj) {
        .commit => |c| c,
        else => return,
    };

    var match_count: u32 = 0;
    try searchTreeContents(allocator, io, git_dir, store, commit.tree, "", pattern, path_filter, &match_count);

    if (match_count == 0) {
        try io.print("{s}No matches found.{s}\n", .{ ui.c.dim, ui.c.reset });
    } else {
        try io.print("\n{s}{d}{s} match(es) found.\n", .{ ui.c.bold, match_count, ui.c.reset });
    }
}

fn searchTreeContents(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: []const u8,
    store: storage_mod.StorageBackend,
    tree_sha: [20]u8,
    prefix: []const u8,
    pattern: []const u8,
    path_filter: ?[]const u8,
    count: *u32,
) !void {
    const tree_obj = store.read(allocator, io.io, tree_sha) catch return;
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        if (entry.mode == 0o040000) {
            const sub_prefix = if (prefix.len > 0)
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
            else
                try allocator.dupe(u8, entry.name);
            defer allocator.free(sub_prefix);
            try searchTreeContents(allocator, io, git_dir, store, entry.sha, sub_prefix, pattern, path_filter, count);
        } else {
            const file_path = if (prefix.len > 0)
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
            else
                try allocator.dupe(u8, entry.name);
            defer allocator.free(file_path);

            // Apply path filter
            if (path_filter) |pf| {
                if (std.mem.indexOf(u8, file_path, pf) == null) continue;
            }

            // Read blob
            const blob_obj = store.read(allocator, io.io, entry.sha) catch continue;
            const content = switch (blob_obj) {
                .blob => |b| b.content,
                else => continue,
            };

            // Skip binary files (null bytes)
            if (std.mem.indexOfScalar(u8, content, 0) != null) continue;

            try searchInContent(allocator, io, file_path, content, pattern, count);
        }
    }
}

fn searchInContent(
    _: std.mem.Allocator,
    io: Io,
    file_path: []const u8,
    content: []const u8,
    pattern: []const u8,
    count: *u32,
) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 1;
    var printed_file_header = false;

    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, pattern)) |_| {
            if (!printed_file_header) {
                try io.print("\n{s}{s}{s}:\n", .{ ui.c.bcyan, file_path, ui.c.reset });
                printed_file_header = true;
            }
            try io.print("  {s}{d:>4}{s}: ", .{ ui.c.dim, line_num, ui.c.reset });

            // Highlight the match
            var remaining = line;
            while (remaining.len > 0) {
                if (std.mem.indexOf(u8, remaining, pattern)) |pos| {
                    try io.print("{s}", .{remaining[0..pos]});
                    try io.print("{s}{s}{s}", .{ ui.c.bold, remaining[pos..][0..pattern.len], ui.c.reset });
                    remaining = remaining[pos + pattern.len ..];
                } else {
                    try io.print("{s}", .{remaining});
                    break;
                }
            }
            try io.print("\n", .{});
            count.* += 1;
        }
        line_num += 1;
    }
}

// ── Commit message search ──────────────────────────────────────────────────

fn searchCommitMessages(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    pattern: []const u8,
    context_lines: usize,
    search_all: bool,
    io: Io,
) !void {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const refs_manager = refs_mod.Refs.init(git_dir);

    var match_count: u32 = 0;

    if (search_all) {
        // Search all branches
        const branches = refs_manager.list(allocator, io.io, "heads") catch {
            try io.print("No branches found.\n", .{});
            return;
        };
        defer {
            for (branches) |b| allocator.free(b);
            allocator.free(branches);
        }

        for (branches) |branch_ref| {
            const branch_sha = refs_manager.read(allocator, io.io, branch_ref) catch continue;
            const branch_name = if (std.mem.startsWith(u8, branch_ref, "refs/heads/"))
                branch_ref[11..]
            else
                branch_ref;

            var current_sha = branch_sha;
            var depth: usize = 0;
            while (depth < 500) : (depth += 1) {
                const obj = store.read(allocator, io.io, current_sha) catch break;
                const commit = switch (obj) {
                    .commit => |c| c,
                    else => break,
                };

                if (std.mem.indexOf(u8, commit.message, pattern) != null) {
                    const hex = Sha1.hex(current_sha);
                    var msg_lines = std.mem.splitScalar(u8, commit.message, '\n');
                    const first_line = msg_lines.next() orelse "";

                    try io.print("{s}commit {s}{s} {s}({s}){s}\n", .{
                        ui.c.yellow, ui.c.reset, hex[0..7],
                        ui.c.dim, branch_name, ui.c.reset,
                    });
                    // Highlight pattern in first line
                    try printHighlightedLine(io, first_line, pattern);
                    try io.print("\n", .{});
                    match_count += 1;

                    // Show context lines (additional commit lines)
                    if (context_lines > 0) {
                        var ctx: usize = 0;
                        while (msg_lines.next()) |line| {
                            if (ctx >= context_lines) break;
                            try io.print("    {s}{s}{s}\n", .{ ui.c.dim, line, ui.c.reset });
                            ctx += 1;
                        }
                        try io.print("\n", .{});
                    }
                }

                if (commit.parents.len == 0) break;
                current_sha = commit.parents[0];
            }
        }
    } else {
        // Search HEAD
        const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
            try io.print("No commits yet.\n", .{});
            return;
        };

        var current_sha = head_sha;
        var depth: usize = 0;
        while (depth < 500) : (depth += 1) {
            const obj = store.read(allocator, io.io, current_sha) catch break;
            const commit = switch (obj) {
                .commit => |c| c,
                else => break,
            };

            if (std.mem.indexOf(u8, commit.message, pattern) != null) {
                const hex = Sha1.hex(current_sha);
                var msg_lines = std.mem.splitScalar(u8, commit.message, '\n');
                const first_line = msg_lines.next() orelse "";

                try io.print("{s}commit {s}{s}\n", .{ ui.c.yellow, hex[0..7], ui.c.reset });
                try printHighlightedLine(io, first_line, pattern);
                try io.print("\n", .{});
                match_count += 1;

                if (context_lines > 0) {
                    var ctx: usize = 0;
                    while (msg_lines.next()) |line| {
                        if (ctx >= context_lines) break;
                        try io.print("    {s}{s}{s}\n", .{ ui.c.dim, line, ui.c.reset });
                        ctx += 1;
                    }
                    try io.print("\n", .{});
                }
            }

            if (commit.parents.len == 0) break;
            current_sha = commit.parents[0];
        }
    }

    if (match_count == 0) {
        try io.print("{s}No matching commits.{s}\n", .{ ui.c.dim, ui.c.reset });
    } else {
        try io.print("\n{s}{d}{s} matching commit(s) found.\n", .{ ui.c.bold, match_count, ui.c.reset });
    }
}

fn printHighlightedLine(io: Io, line: []const u8, pattern: []const u8) !void {
    var remaining = line;
    while (remaining.len > 0) {
        if (std.mem.indexOf(u8, remaining, pattern)) |pos| {
            try io.print("{s}", .{remaining[0..pos]});
            try io.print("{s}{s}{s}", .{ ui.c.bold, remaining[pos..][0..pattern.len], ui.c.reset });
            remaining = remaining[pos + pattern.len ..];
        } else {
            try io.print("{s}", .{remaining});
            break;
        }
    }
}
