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
const update_cmd = @import("commands/update.zig");
const search_cmd = @import("commands/search.zig");
const review_cmd = @import("commands/review.zig");
const sync_cmd = @import("commands/sync.zig");
const lfs_cmd = @import("commands/lfs.zig");

const VERSION = "0.3.0";

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
        \\      search      Search commit messages and file contents
        \\      review      Code review (diff between branches/commits)
        \\      sync        Fetch and rebase onto remote branch
        \\      lfs         Git Large File Storage
        \\
        \\  REMOTE COMMANDS:
        \\      clone       Clone a repository from a URL
        \\      fetch       Download objects and refs from a remote
        \\      push        Update remote refs using associated local objects
        \\      pull        Fetch from and integrate with another repository
        \\      remote      Manage set of tracked repositories
        \\      update      Update gitz to the latest version
        \\
        \\  REMOTE OPTIONS:
        \\      --git, -g       Use system git for push/pull/fetch
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
        try io.print("gitz version {s}\n", .{VERSION});
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

    if (std.mem.eql(u8, command, "update")) {
        try update_cmd.execute(allocator, args, io);
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
    } else if (std.mem.eql(u8, command, "sync")) {
        try sync_cmd.execute(allocator, git_dir, args, io);
    } else if (std.mem.eql(u8, command, "lfs")) {
        try lfs_cmd.execute(allocator, git_dir, args, io);
    } else {
        try io.print("gitz: '{s}' is not a gitz command.\n\n", .{command});
        try printHelp(io);
        std.process.exit(1);
    }
}

fn findGitDir(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    _ = allocator;
    if (io.fileExists(".gitz")) {
        return io.allocator.dupe(u8, ".gitz");
    }
    return error.NotAGitRepo;
}
