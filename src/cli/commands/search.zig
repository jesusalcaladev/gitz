const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var query: ?[]const u8 = null;
    var search_messages = true;
    var search_content = false;
    var count: usize = 50;
    var context_lines: usize = 2;
    var author_filter: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--content") or std.mem.eql(u8, arg, "-c")) {
            search_content = true;
        } else if (std.mem.eql(u8, arg, "--message") or std.mem.eql(u8, arg, "-m")) {
            search_messages = true;
            search_content = false;
        } else if (std.mem.eql(u8, arg, "--all")) {
            search_messages = true;
            search_content = true;
        } else if (std.mem.eql(u8, arg, "-n") and i + 1 < args.len) {
            i += 1;
            count = std.fmt.parseInt(usize, args[i], 10) catch 50;
        } else if (std.mem.eql(u8, arg, "-C") and i + 1 < args.len) {
            i += 1;
            context_lines = std.fmt.parseInt(usize, args[i], 10) catch 2;
        } else if (std.mem.eql(u8, arg, "--author") and i + 1 < args.len) {
            i += 1;
            author_filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "--author=")) {
            author_filter = arg[9..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            query = arg;
        }
    }

    const q = query orelse {
        try io.eprint("usage: gitz search [-c|--content] [-m|--message] [--all] [-n <count>] [--author=<name>] <query>\n", .{});
        try io.eprint("\nSearch commit messages and file contents.\n", .{});
        try io.eprint("\nOptions:\n", .{});
        try io.eprint("  -c, --content     Search file contents (slower)\n", .{});
        try io.eprint("  -m, --message     Search commit messages only (default)\n", .{});
        try io.eprint("  --all             Search both messages and content\n", .{});
        try io.eprint("  -n <count>        Max commits to search (default: 50)\n", .{});
        try io.eprint("  -C <lines>        Context lines for content matches (default: 2)\n", .{});
        try io.eprint("  --author=<name>   Filter by author name/email\n", .{});
        std.process.exit(1);
    };

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const refs_manager = refs_mod.Refs.init(git_dir);

    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
        try io.print("No commits yet\n", .{});
        return;
    };

    var found: usize = 0;
    var searched: usize = 0;
    var current_sha = head_sha;

    try io.print("\x1b[1;36mSearching for '{s}'...\x1b[0m\n\n", .{q});

    while (searched < count) {
        const obj = store.read(allocator, io.io, current_sha) catch break;
        const commit = switch (obj) {
            .commit => |c| c,
            else => break,
        };

        // Author filter
        if (author_filter) |af| {
            if (std.mem.indexOf(u8, commit.author.name, af) == null and
                std.mem.indexOf(u8, commit.author.email, af) == null)
            {
                if (commit.parents.len > 0) {
                    current_sha = commit.parents[0];
                } else break;
                searched += 1;
                continue;
            }
        }

        var matched_in_message = false;

        // Search commit message
        if (search_messages) {
            if (std.mem.indexOf(u8, commit.message, q)) |_| {
                matched_in_message = true;
                found += 1;
                const hex = Sha1.hex(current_sha);
                var msg_lines = std.mem.splitScalar(u8, commit.message, '\n');
                const first_line = msg_lines.next() orelse "";
                try io.print("\x1b[1;33mcommit {s}\x1b[0m \x1b[2m({s} <{s}>)\x1b[0m\n", .{
                    hex[0..7],
                    commit.author.name,
                    commit.author.email,
                });
                try io.print("    \x1b[1m{s}\x1b[0m\n", .{first_line});
                try io.print("\n", .{});
            }
        }

        // Search file content
        if (search_content and !matched_in_message) {
            try searchCommitContent(allocator, io, store, current_sha, commit, q, context_lines, &found);
        }

        if (commit.parents.len > 0) {
            current_sha = commit.parents[0];
        } else break;
        searched += 1;
    }

    if (found == 0) {
        try io.print("\x1b[2mNo matches found.\x1b[0m\n", .{});
    } else {
        try io.print("\x1b[2m{d} match(es) found in {d} commits.\x1b[0m\n", .{ found, searched });
    }
}

fn searchCommitContent(
    allocator: std.mem.Allocator,
    io: Io,
    store: storage_mod.StorageBackend,
    commit_sha: [20]u8,
    commit: object.Commit,
    query: []const u8,
    context_lines: usize,
    found: *usize,
) !void {
    // Get the tree for this commit
    const tree_obj = store.read(allocator, io.io, commit.tree) catch return;
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return,
    };

    // Search through tree entries
    for (tree.entries) |entry| {
        if (entry.mode == 0o040000) continue; // skip directories

        const blob_obj = store.read(allocator, io.io, entry.sha) catch continue;
        const blob = switch (blob_obj) {
            .blob => |b| b,
            else => continue,
        };

        // Search for query in blob content
        if (std.mem.indexOf(u8, blob.content, query)) |_| {
            found.* += 1;
            const hex = Sha1.hex(commit_sha);
            try io.print("\x1b[1;33mcommit {s}\x1b[0m \x1b[2m({s} <{s}>)\x1b[0m\n", .{
                hex[0..7],
                commit.author.name,
                commit.author.email,
            });
            var msg_lines = std.mem.splitScalar(u8, commit.message, '\n');
            const first_line = msg_lines.next() orelse "";
            try io.print("    \x1b[1m{s}\x1b[0m\n", .{first_line});
            try io.print("    \x1b[36m{s}\x1b[0m\n", .{entry.name});

            // Show matching lines with context
            var lines = std.mem.splitScalar(u8, blob.content, '\n');
            var line_num: u32 = 0;
            while (lines.next()) |line| {
                line_num += 1;
                if (std.mem.indexOf(u8, line, query)) |_| {
                    const start: u32 = if (line_num > @as(u32, @intCast(context_lines))) line_num - @as(u32, @intCast(context_lines)) else 1;
                    var ctx_lines = std.mem.splitScalar(u8, blob.content, '\n');
                    var ctx_num: u32 = 0;
                    while (ctx_lines.next()) |ctx_line| {
                        ctx_num += 1;
                        if (ctx_num >= start and ctx_num <= line_num + context_lines) {
                            if (ctx_num == line_num) {
                                try io.print("    \x1b[32m{d:>4} | {s}\x1b[0m\n", .{ ctx_num, ctx_line });
                            } else {
                                try io.print("    \x1b[2m{d:>4} | {s}\x1b[0m\n", .{ ctx_num, ctx_line });
                            }
                        }
                        if (ctx_num > line_num + context_lines) break;
                    }
                    try io.print("\n", .{});
                    break; // One match per file per commit
                }
            }
        }
    }
}
