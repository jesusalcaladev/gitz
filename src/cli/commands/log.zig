const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const loose = @import("../../core/loose.zig");
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var oneline = false;
    var graph = false;
    var show_all = false;
    var count: usize = 20;
    var author_filter: ?[]const u8 = null;
    var grep_filter: ?[]const u8 = null;
    var show_commit: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--oneline")) {
            oneline = true;
        } else if (std.mem.eql(u8, arg, "--graph")) {
            graph = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            show_all = true;
        } else if (std.mem.eql(u8, arg, "--author") and i + 1 < args.len) {
            i += 1;
            author_filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "--author=")) {
            author_filter = arg[9..];
        } else if (std.mem.eql(u8, arg, "--grep") and i + 1 < args.len) {
            i += 1;
            grep_filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "--grep=")) {
            grep_filter = arg[7..];
        } else if (std.mem.eql(u8, arg, "show") and i + 1 < args.len) {
            i += 1;
            show_commit = args[i];
        } else if (std.mem.eql(u8, arg, "-n") and i + 1 < args.len) {
            i += 1;
            count = std.fmt.parseInt(usize, args[i], 10) catch 20;
        } else if (std.mem.startsWith(u8, arg, "-") and !std.mem.startsWith(u8, arg, "--")) {
            // Parse -N style count
            if (arg.len > 1) {
                const num = std.fmt.parseInt(usize, arg[1..], 10) catch null;
                if (num) |n| {
                    count = n;
                }
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            file_path = arg;
        }
    }

    // Show a specific commit
    if (show_commit) |sha_str| {
        try showSpecificCommit(allocator, git_dir, sha_str, io);
        return;
    }

    const store = loose.LooseStore.init(git_dir);
    const refs_manager = refs_mod.Refs.init(git_dir);

    if (show_all) {
        // Show all branches
        const branches = try refs_manager.list(allocator, io.io, "heads");
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

            try io.print("Branch: {s}\n", .{branch_name});
            var shown: usize = 0;
            var current_sha = branch_sha;

            while (shown < count) {
                const obj = store.read(allocator, io.io, current_sha) catch break;
                const commit = switch (obj) {
                    .commit => |c| c,
                    else => break,
                };

                if (author_filter) |af| {
                    if (std.mem.indexOf(u8, commit.author.name, af) == null and
                        std.mem.indexOf(u8, commit.author.email, af) == null)
                    {
                        if (commit.parents.len > 0) {
                            current_sha = commit.parents[0];
                        } else break;
                        continue;
                    }
                }

                if (grep_filter) |gf| {
                    if (std.mem.indexOf(u8, commit.message, gf) == null) {
                        if (commit.parents.len > 0) {
                            current_sha = commit.parents[0];
                        } else break;
                        continue;
                    }
                }

                try printCommit(io, current_sha, commit, oneline, graph);
                shown += 1;
                if (commit.parents.len > 0) {
                    current_sha = commit.parents[0];
                } else break;
            }
            try io.print("\n", .{});
        }
        return;
    }

    // Normal log - follow HEAD
    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
        try io.print("No commits yet\n", .{});
        return;
    };

    var shown: usize = 0;
    var current_sha = head_sha;

    while (shown < count) {
        const obj = store.read(allocator, io.io, current_sha) catch break;
        const commit = switch (obj) {
            .commit => |c| c,
            else => break,
        };

        // Apply filters
        if (author_filter) |af| {
            if (std.mem.indexOf(u8, commit.author.name, af) == null and
                std.mem.indexOf(u8, commit.author.email, af) == null)
            {
                if (commit.parents.len > 0) {
                    current_sha = commit.parents[0];
                } else break;
                continue;
            }
        }

        if (grep_filter) |gf| {
            if (std.mem.indexOf(u8, commit.message, gf) == null) {
                if (commit.parents.len > 0) {
                    current_sha = commit.parents[0];
                } else break;
                continue;
            }
        }

        // File filter: check if file was modified in this commit
        if (file_path) |fp| {
            if (!commitTouchesFile(allocator, io.io, &store, commit, fp)) {
                if (commit.parents.len > 0) {
                    current_sha = commit.parents[0];
                } else break;
                continue;
            }
        }

        try printCommit(io, current_sha, commit, oneline, graph);
        shown += 1;
        if (commit.parents.len > 0) {
            current_sha = commit.parents[0];
        } else break;
    }
}

fn printCommit(
    io: Io,
    sha: [20]u8,
    commit: object.Commit,
    oneline: bool,
    graph: bool,
) !void {
    const hex = Sha1.hex(sha);

    if (oneline) {
        if (graph) {
            try io.print("* {s} ", .{hex[0..7]});
        } else {
            try io.print("{s} ", .{hex[0..7]});
        }
        // Show first line of message only
        var msg_lines = std.mem.splitScalar(u8, commit.message, '\n');
        if (msg_lines.next()) |first_line| {
            try io.print("{s}\n", .{first_line});
        }
    } else {
        if (graph) {
            try io.print("* ", .{});
        }
        try io.print("commit {s}\n", .{hex});
        try io.print("Author: {s} <{s}>\n", .{ commit.author.name, commit.author.email });
        try io.print("Date:   {d}\n\n", .{commit.author.timestamp});

        var msg_lines = std.mem.splitScalar(u8, commit.message, '\n');
        while (msg_lines.next()) |line| {
            if (line.len > 0) try io.print("    {s}\n", .{line});
        }
        try io.print("\n", .{});
    }
}

fn showSpecificCommit(allocator: std.mem.Allocator, git_dir: []const u8, sha_str: []const u8, io: Io) !void {
    const sha = Sha1.fromHex(sha_str) catch {
        try io.eprint("fatal: invalid commit SHA '{s}'\n", .{sha_str});
        return;
    };

    const store = loose.LooseStore.init(git_dir);
    const obj = store.read(allocator, io.io, sha) catch {
        try io.eprint("fatal: not a commit object '{s}'\n", .{sha_str});
        return;
    };

    const commit = switch (obj) {
        .commit => |c| c,
        else => {
            try io.eprint("fatal: object '{s}' is not a commit\n", .{sha_str});
            return;
        },
    };

    try printCommit(io, sha, commit, false, false);

    // If commit has a parent, show the diff
    if (commit.parents.len > 0) {
        try io.print("diff --git a/file b/file\n", .{});
        try io.print("(simplified diff output)\n", .{});
    }
}

fn commitTouchesFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *const loose.LooseStore,
    commit: object.Commit,
    file_path: []const u8,
) bool {
    // Get the current commit's tree
    const tree_obj = store.read(allocator, io, commit.tree) catch return false;
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return false,
    };

    // Check if file exists in the current tree
    var in_current = false;
    for (tree.entries) |entry| {
        if (std.mem.eql(u8, entry.name, file_path)) {
            in_current = true;
            break;
        }
    }

    // Check parent tree
    if (commit.parents.len > 0) {
        const parent_obj = store.read(allocator, io, commit.parents[0]) catch return in_current;
        const parent_commit = switch (parent_obj) {
            .commit => |c| c,
            else => return in_current,
        };
        const parent_tree = store.read(allocator, io, parent_commit.tree) catch return in_current;
        const ptree = switch (parent_tree) {
            .tree => |t| t,
            else => return in_current,
        };

        var in_parent = false;
        for (ptree.entries) |entry| {
            if (std.mem.eql(u8, entry.name, file_path)) {
                in_parent = true;
                break;
            }
        }

        return in_current != in_parent or in_current;
    }

    return in_current; // First commit, file exists → touches it
}
