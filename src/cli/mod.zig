const std = @import("std");
const Io = @import("../util/io.zig").Io;
const init_cmd = @import("commands/init.zig");
const add_cmd = @import("commands/add.zig");
const commit_cmd = @import("commands/commit.zig");
const status_cmd = @import("commands/status.zig");
const log_cmd = @import("commands/log.zig");
const branch_cmd = @import("commands/branch.zig");
const switch_cmd = @import("commands/switch.zig");
const diff_cmd = @import("commands/diff.zig");
const stash_cmd = @import("commands/stash.zig");
const tag_cmd = @import("commands/tag.zig");
const reset_cmd = @import("commands/reset.zig");
const merge_cmd = @import("commands/merge.zig");
const rebase_cmd = @import("commands/rebase.zig");
const undo_cmd = @import("commands/undo.zig");
const blame_cmd = @import("commands/blame.zig");
const gc_cmd = @import("commands/gc.zig");
const remote_cmd = @import("commands/remote.zig");
const clone_cmd = @import("commands/clone.zig");
const fetch_cmd = @import("commands/fetch.zig");
const push_cmd = @import("commands/push.zig");
const pull_cmd = @import("commands/pull.zig");
const config_cmd = @import("commands/config.zig");
const sync_cmd = @import("commands/sync.zig");
const pack_refs_cmd = @import("commands/pack_refs.zig");
const search_cmd = @import("commands/search.zig");
const review_cmd = @import("commands/review.zig");
const show_cmd = @import("commands/show.zig");
const clean_cmd = @import("commands/clean.zig");
const shortlog_cmd = @import("commands/shortlog.zig");
const worktree_cmd = @import("commands/worktree.zig");

const VERSION = "0.7.0";

pub fn printHelp(io: Io) !void {
    try io.print(
        \\
        \\  gitz v{s} — Git, but faster.
        \\
        \\  USAGE:
        \\      gitz <command> [options]
        \\
        \\  LOCAL COMMANDS:
        \\      init        Initialize a new repository
        \\      add         Stage files for commit
        \\      commit      Record changes to the repository
        \\      status      Show working tree status
        \\      diff        Show changes between commits, working tree, and staging
        \\      log         Show commit history
        \\      branch      List, create, or delete branches
        \\      switch      Switch to a branch or create a new one
        \\      merge       Join two branches together
        \\      rebase      Reapply commits on top of another base
        \\      stash       Stash changes in a dirty working directory
        \\      reset       Reset current HEAD to a specified state
        \\      undo        Undo the last commit (create inverse)
        \\      tag         Create, list, delete tags
        \\      blame       Show what revision and author last modified each line
        \\      gc          Clean up unreachable objects
        \\      config      Get and set repository options
        \\      search      Search file contents and commit messages
        \\      review      Code review between branches
        \\      show        Show commit details and diff
        \\      clean       Remove untracked files
        \\      shortlog    Summarize commits by author
        \\      worktree    Manage multiple working trees
        \\
        \\  REMOTE COMMANDS:
        \\      clone       Clone a repository from a URL
        \\      fetch       Download objects and refs from a remote
        \\      push        Update remote refs using associated local objects
        \\      pull        Fetch from and integrate with another repository
        \\      remote      Manage set of tracked repositories
        \\      sync        Fetch + rebase + push the current branch in one step
        \\      pack-refs   Compact loose refs into packed-refs
        \\
        \\  GLOBAL OPTIONS:
        \\      -h, --help      Show this help message
        \\      -v, --version   Show version
        \\
    , .{VERSION});
}

pub fn dispatch(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8, io: Io) !void {
    if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        try printHelp(io);
        return;
    }

    if (std.mem.eql(u8, command, "-v") or std.mem.eql(u8, command, "--version")) {
        try io.print("gitz v{s}\n", .{VERSION});
        return;
    }

    // Commands that don't need .gitz
    if (std.mem.eql(u8, command, "init")) {
        try init_cmd.execute(allocator, args, io);
        return;
    }

    if (std.mem.eql(u8, command, "clone")) {
        try clone_cmd.execute(allocator, args, io);
        return;
    }

    // Find git_dir
    const git_dir = findGitDir(allocator, io) catch {
        try io.eprint("fatal: not a gitz repository (or any parent): .gitz\n", .{});
        try io.eprint("Hint: run 'gitz init' to create one\n", .{});
        std.process.exit(128);
    };
    defer allocator.free(git_dir);

    if (std.mem.eql(u8, command, "add")) {
        try add_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "commit")) {
        try commit_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "status")) {
        try status_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "log")) {
        try log_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "branch")) {
        try branch_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "switch")) {
        try switch_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "diff")) {
        try diff_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "stash")) {
        try stash_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "tag")) {
        try tag_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "reset")) {
        try reset_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "merge")) {
        try merge_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "rebase")) {
        try rebase_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "undo")) {
        try undo_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "blame")) {
        try blame_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "gc")) {
        try gc_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "remote")) {
        try remote_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "sync")) {
        try sync_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "pack-refs")) {
        try pack_refs_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "fetch")) {
        try fetch_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "push")) {
        try push_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "pull")) {
        try pull_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "config")) {
        try config_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "search")) {
        try search_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "review")) {
        try review_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "show")) {
        try show_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "clean")) {
        try clean_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "shortlog")) {
        try shortlog_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "worktree")) {
        try worktree_cmd.execute(allocator, git_dir, args, io);
    } else {
        try io.print("gitz: '{s}' is not a gitz command.\n\n", .{command});
        try printHelp(io);
        std.process.exit(1);
    }
}

/// Find the .gitz or .git directory by walking up the directory tree.
/// Supports monorepos where .gitz may be in a parent directory.
/// Also supports git worktrees via .git file pointing to the actual git dir.
fn findGitDir(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    var dir_path = try std.fmt.allocPrint(allocator, ".", .{});
    defer allocator.free(dir_path);

    // Walk up to 256 levels (practical limit)
    for (0..256) |_| {
        // Check for .gitz directory
        const gitz_path = try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dir_path});
        defer allocator.free(gitz_path);
        
        if (io.fileExists(gitz_path)) {
            // Check if it's a real directory or a worktree .git file
            const git_file_path = try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dir_path});
            defer allocator.free(git_file_path);
            
            // Try to read as file first (worktree case: .gitz contains "gitdir: ...")
            if (std.Io.Dir.cwd().readFileAlloc(io.io, git_file_path, allocator, .unlimited)) |content| {
                defer allocator.free(content);
                
                // If content starts with "gitdir:", it's a worktree reference
                if (std.mem.startsWith(u8, content, "gitdir: ")) {
                    const gitdir = std.mem.trim(u8, content[8..], &[_]u8{ '\n', '\r', ' ' });
                    return allocator.dupe(u8, gitdir);
                }
            } else |_| {}
            
            // Normal directory case
            return try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dir_path});
        }
        
        // Also check for .git directory (git compatibility)
        const git_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir_path});
        defer allocator.free(git_path);
        
        if (io.fileExists(git_path)) {
            // Check if .git is a file (worktree case)
            const git_file_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir_path});
            defer allocator.free(git_file_path);
            
            if (std.Io.Dir.cwd().readFileAlloc(io.io, git_file_path, allocator, .unlimited)) |content| {
                defer allocator.free(content);
                
                // If content starts with "gitdir:", it's a worktree reference
                if (std.mem.startsWith(u8, content, "gitdir: ")) {
                    const gitdir = std.mem.trim(u8, content[8..], &[_]u8{ '\n', '\r', ' ' });
                    return allocator.dupe(u8, gitdir);
                }
            } else |_| {}
            
            return try std.fmt.allocPrint(allocator, "{s}/.git", .{dir_path});
        }
        
        // Move up one directory
        const parent = std.fs.path.dirname(dir_path) orelse break;
        const new_path = try std.fmt.allocPrint(allocator, "{s}", .{parent});
        allocator.free(dir_path);
        dir_path = new_path;
    }
    
    return error.NotAGitRepo;
}
