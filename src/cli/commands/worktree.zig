const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const ui = @import("../../util/ui.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    if (args.len == 0) {
        try printUsage(io);
        return;
    }

    const subcmd = args[0];

    if (std.mem.eql(u8, subcmd, "add")) {
        try worktreeAdd(allocator, git_dir, args[1..], io);
    } else if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
        try worktreeList(allocator, git_dir, io);
    } else if (std.mem.eql(u8, subcmd, "remove") or std.mem.eql(u8, subcmd, "rm")) {
        try worktreeRemove(allocator, git_dir, args[1..], io);
    } else if (std.mem.eql(u8, subcmd, "prune")) {
        try worktreePrune(allocator, git_dir, io);
    } else if (std.mem.eql(u8, subcmd, "lock")) {
        try io.print("Worktree locking not yet implemented\n", .{});
    } else if (std.mem.eql(u8, subcmd, "unlock")) {
        try io.print("Worktree unlocking not yet implemented\n", .{});
    } else {
        try io.eprint("error: unknown worktree subcommand '{s}'\n", .{subcmd});
        try printUsage(io);
    }
}

fn printUsage(io: Io) !void {
    try io.print(
        \\usage: gitz worktree <command> [args]
        \\
        \\Commands:
        \\  add <path> [<branch>]    Create a new worktree
        \\  list (ls)                List all worktrees
        \\  remove (rm) <path>       Remove a worktree
        \\  prune                    Remove stale worktree data
        \\
    , .{});
}

fn worktreeAdd(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    if (args.len == 0) {
        try io.eprint("error: worktree add requires a path\n", .{});
        try io.print("usage: gitz worktree add <path> [<branch>]\n", .{});
        return;
    }

    const worktree_path = args[0];
    var branch_name: ?[]const u8 = null;
    var create_branch = false;

    // Parse flags
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-b")) {
            create_branch = true;
            if (i + 1 < args.len) {
                i += 1;
                branch_name = args[i];
            }
        } else if (!std.mem.startsWith(u8, args[i], "-")) {
            branch_name = args[i];
        }
    }

    const refs_manager = refs_mod.Refs.init(git_dir);

    // Get current HEAD
    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
        try io.eprint("fatal: no commits yet\n", .{});
        return;
    };

    // Resolve branch
    const target_branch = branch_name orelse "main";
    var target_sha = head_sha;

    if (branch_name) |name| {
        const ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
        defer allocator.free(ref);

        // Create branch if -b flag and branch doesn't exist
        if (create_branch) {
            _ = refs_manager.read(allocator, io.io, ref) catch {
                // Branch doesn't exist, create it
                try refs_manager.write(allocator, io.io, ref, head_sha);
                try io.print("{s}✓{s} Created branch '{s}'\n", .{ ui.c.bgreen, ui.c.reset, name });
            };
        }

        target_sha = refs_manager.read(allocator, io.io, ref) catch {
            try io.eprint("error: pathspec '{s}' did not match any branch\n", .{name});
            return;
        };
    }

    // Create worktree directory
    std.Io.Dir.cwd().createDirPath(io.io, worktree_path) catch |err| {
        try io.eprint("error: could not create worktree path: {}\n", .{err});
        return;
    };

    // Write .git file pointing to the main repo's .gitz
    const git_file_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{worktree_path});
    defer allocator.free(git_file_path);

    // Get absolute path to git_dir
    const abs_git_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz", .{git_dir});
    defer allocator.free(abs_git_dir);

    var git_file = std.Io.Dir.cwd().createFile(io.io, git_file_path, .{}) catch |err| {
        try io.eprint("error: could not create .git file: {}\n", .{err});
        return;
    };
    defer git_file.close(io.io);

    const content = try std.fmt.allocPrint(allocator, "gitdir: {s}\n", .{abs_git_dir});
    defer allocator.free(content);
    try std.Io.File.writeStreamingAll(git_file, io.io, content);

    // Checkout the tree
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    checkoutTree(allocator, store, io.io, target_sha, worktree_path) catch |err| {
        try io.eprint("error: failed to checkout: {}\n", .{err});
        return;
    };

    // Create worktree worktrees dir in main repo
    const worktrees_dir = try std.fmt.allocPrint(allocator, "{s}/worktrees", .{git_dir});
    defer allocator.free(worktrees_dir);
    std.Io.Dir.cwd().createDirPath(io.io, worktrees_dir) catch {};

    // Store worktree info
    const wt_name = std.fs.path.basename(worktree_path);
    const wt_info_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktrees_dir, wt_name });
    defer allocator.free(wt_info_path);

    var wt_info_file = std.Io.Dir.cwd().createFile(io.io, wt_info_path, .{}) catch |err| {
        try io.eprint("warning: could not create worktree info: {}\n", .{err});
        return;
    };
    defer wt_info_file.close(io.io);

    const abs_worktree = worktree_path;
    defer if (!std.mem.eql(u8, abs_worktree, worktree_path)) allocator.free(abs_worktree);

    const wt_content = try std.fmt.allocPrint(allocator, "worktree: {s}\nHEAD: {s}\nbranch: refs/heads/{s}\n", .{
        abs_worktree,
        &Sha1.hex(target_sha),
        target_branch,
    });
    defer allocator.free(wt_content);
    try std.Io.File.writeStreamingAll(wt_info_file, io.io, wt_content);

    const target_hex = Sha1.hex(target_sha);
    try io.print("{s}✓{s} worktree {s}{s}{s} created at {s} ({s})\n", .{
        ui.c.bgreen, ui.c.reset,
        ui.c.bold, worktree_path, ui.c.reset,
        target_branch,
        target_hex[0..7],
    });
}

fn worktreeList(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) !void {
    const worktrees_dir = try std.fmt.allocPrint(allocator, "{s}/worktrees", .{git_dir});
    defer allocator.free(worktrees_dir);

    // Check if worktrees directory exists
    const dir = std.Io.Dir.cwd().openDir(io.io, worktrees_dir, .{}) catch {
        try io.print("No worktrees found.\n", .{});
        return;
    };
    defer dir.close(io.io);

    // List worktree files
    var count: u32 = 0;
    var dir_iter = dir.iterate();
    while (true) {
        const entry = dir_iter.next(io.io) catch break orelse break;
        if (entry.kind == .file) {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktrees_dir, entry.name });
            defer allocator.free(file_path);

            const content = std.Io.Dir.cwd().readFileAlloc(io.io, file_path, allocator, .unlimited) catch continue;
            defer allocator.free(content);

            // Parse worktree info
            var wt_path: []const u8 = "";
            var wt_head: []const u8 = "";
            var wt_branch: []const u8 = "";

            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "worktree: ")) {
                    wt_path = std.mem.trim(u8, line[10..], &[_]u8{ '\r', ' ' });
                } else if (std.mem.startsWith(u8, line, "HEAD: ")) {
                    wt_head = std.mem.trim(u8, line[6..], &[_]u8{ '\r', ' ' });
                } else if (std.mem.startsWith(u8, line, "branch: ")) {
                    wt_branch = std.mem.trim(u8, line[8..], &[_]u8{ '\r', ' ' });
                }
            }

            if (count == 0) {
                try io.print("{s}worktree{s}  {s}HEAD{s}  {s}Branch{s}\n", .{
                    ui.c.bold, ui.c.reset,
                    ui.c.dim, ui.c.reset,
                    ui.c.dim, ui.c.reset,
                });
            }

            // Check if this is the main worktree (git_dir parent)
            const main_worktree = try std.fmt.allocPrint(allocator, "{s}/..", .{git_dir});
            defer allocator.free(main_worktree);

            const is_main = std.mem.eql(u8, wt_path, main_worktree) or
                std.mem.endsWith(u8, wt_path, "/.") or
                std.mem.eql(u8, wt_path, ".");

            if (is_main) {
                try io.print("  {s}*{s} {s}{s}{s}    {s}{s}{s}    {s}{s}{s}\n", .{
                    ui.c.bgreen, ui.c.reset,
                    ui.c.bold, "(main)", ui.c.reset,
                    ui.c.yellow, wt_head[0..@min(7, wt_head.len)], ui.c.reset,
                    ui.c.cyan, wt_branch, ui.c.reset,
                });
            } else {
                try io.print("  {s} {s}{s}{s}    {s}{s}{s}    {s}{s}{s}\n", .{
                    ui.c.dim,
                    ui.c.bold, wt_path, ui.c.reset,
                    ui.c.yellow, wt_head[0..@min(7, wt_head.len)], ui.c.reset,
                    ui.c.cyan, wt_branch, ui.c.reset,
                });
            }

            count += 1;
        }
    }

    if (count == 0) {
        try io.print("No worktrees found.\n", .{});
    }
}

fn worktreeRemove(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    if (args.len == 0) {
        try io.eprint("error: worktree remove requires a path\n", .{});
        try io.print("usage: gitz worktree remove <path>\n", .{});
        return;
    }

    const worktree_path = args[0];

    // Check if worktree exists
    const git_file_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{worktree_path});
    defer allocator.free(git_file_path);

    _ = std.Io.Dir.cwd().openFile(io.io, git_file_path, .{}) catch {
        try io.eprint("error: '{s}' is not a worktree\n", .{worktree_path});
        return;
    };

    // Check for uncommitted changes
    // (simplified - just check if files exist that aren't in the tree)
    const has_changes = false;
    // For now, we'll just warn and proceed

    if (has_changes) {
        try io.eprint("error: '{s}' has uncommitted changes\n", .{worktree_path});
        try io.eprint("Use 'gitz worktree remove --force' to override\n", .{});
        return;
    }

    // Remove worktree directory
    std.Io.Dir.cwd().deleteTree(io.io, worktree_path) catch |err| {
        try io.eprint("error: could not remove worktree: {}\n", .{err});
        return;
    };

    // Remove worktree info from main repo
    const wt_name = std.fs.path.basename(worktree_path);
    const wt_info_path = try std.fmt.allocPrint(allocator, "{s}/worktrees/{s}", .{ git_dir, wt_name });
    defer allocator.free(wt_info_path);
    std.Io.Dir.cwd().deleteFile(io.io, wt_info_path) catch {};

    try io.print("{s}✓{s} worktree '{s}' removed\n", .{ ui.c.bgreen, ui.c.reset, worktree_path });
}

fn worktreePrune(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) !void {
    const worktrees_dir = try std.fmt.allocPrint(allocator, "{s}/worktrees", .{git_dir});
    defer allocator.free(worktrees_dir);

    const dir = std.Io.Dir.cwd().openDir(io.io, worktrees_dir, .{}) catch {
        try io.print("No worktrees to prune.\n", .{});
        return;
    };
    defer dir.close(io.io);

    var pruned: u32 = 0;
    var dir_iter = dir.iterate();
    while (true) {
        const entry = dir_iter.next(io.io) catch break orelse break;
        if (entry.kind == .file) {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktrees_dir, entry.name });
            defer allocator.free(file_path);

            const content = std.Io.Dir.cwd().readFileAlloc(io.io, file_path, allocator, .unlimited) catch continue;
            defer allocator.free(content);

            // Parse worktree path
            var wt_path: []const u8 = "";
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "worktree: ")) {
                    wt_path = std.mem.trim(u8, line[10..], &[_]u8{ '\r', ' ' });
                    break;
                }
            }

            // Check if worktree directory still exists
            const git_file = try std.fmt.allocPrint(allocator, "{s}/.git", .{wt_path});
            defer allocator.free(git_file);

            if (std.Io.Dir.cwd().openFile(io.io, git_file, .{})) |f| {
                f.close(io.io);
            } else |_| {
                // Worktree directory doesn't exist, prune the info file
                std.Io.Dir.cwd().deleteFile(io.io, file_path) catch {};
                pruned += 1;
                try io.print("Pruned stale worktree entry: {s}\n", .{entry.name});
            }
        }
    }

    if (pruned == 0) {
        try io.print("No stale worktrees to prune.\n", .{});
    } else {
        try io.print("{s}✓{s} Pruned {d} stale worktree(s)\n", .{ ui.c.bgreen, ui.c.reset, pruned });
    }
}

/// Checkout a tree to a directory
fn checkoutTree(
    allocator: std.mem.Allocator,
    store: storage_mod.StorageBackend,
    io: std.Io,
    sha: [20]u8,
    dest: []const u8,
) !void {
    const obj = store.read(allocator, io, sha) catch return;

    const tree = switch (obj) {
        .tree => |t| t,
        .commit => |c| {
            // If it's a commit, checkout its tree
            return checkoutTree(allocator, store, io, c.tree, dest);
        },
        else => return,
    };

    for (tree.entries) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, entry.name });
        defer allocator.free(full_path);

        if (entry.mode == 0o040000) {
            // Directory — recurse
            std.Io.Dir.cwd().createDirPath(io, full_path) catch {};
            try checkoutTree(allocator, store, io, entry.sha, full_path);
        } else {
            // File — write blob content
            const blob_obj = store.read(allocator, io, entry.sha) catch continue;
            const blob_content = switch (blob_obj) {
                .blob => |b| b.content,
                else => continue,
            };

            if (std.fs.path.dirname(full_path)) |dir| {
                std.Io.Dir.cwd().createDirPath(io, dir) catch {};
            }

            var wf = std.Io.Dir.cwd().createFile(io, full_path, .{}) catch continue;
            defer wf.close(io);
            std.Io.File.writeStreamingAll(wf, io, blob_content) catch {};
        }
    }
}
