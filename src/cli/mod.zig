const std = @import("std");
const builtin = @import("builtin");
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
const completions_cmd = @import("commands/completions.zig");

const VERSION = "0.4.0";

pub const Exit = struct {
    pub const usage: u8 = 1;
    pub const fatal: u8 = 128;
};

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
        \\      completions Generate shell completions
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

pub fn dispatch(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8, io_in: Io) !void {
    var io = io_in;
    if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        try printHelp(io);
        return;
    }

    if (std.mem.eql(u8, command, "-v") or std.mem.eql(u8, command, "--version")) {
        try io.print("gitz version {s}\n", .{VERSION});
        return;
    }

    // Validate the command before looking for a repository. This keeps usage
    // errors independent of the current directory and leaves machine-readable
    // stdout untouched.
    if (!isKnownCommand(command)) {
        try unknownCommand(command, io);
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

    if (std.mem.eql(u8, command, "completions")) {
        try completions_cmd.execute(allocator, args, io);
        return;
    }

    // Find git_dir. This also moves the process to the worktree root, so the
    // command below needs a mutable `io` to record the subdirectory prefix.
    const git_dir = findGitDir(allocator, &io) catch {
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
        unknownCommand(command, io);
    }
}

pub fn isKnownCommand(command: []const u8) bool {
    const commands = [_][]const u8{
        "init",   "add",    "commit", "status",      "diff",   "log",
        "branch", "switch", "merge",  "rebase",      "stash",  "tag",
        "reset",  "undo",   "blame",  "gc",          "config", "search",
        "review", "sync",   "lfs",    "clone",       "fetch",  "push",
        "pull",   "remote", "update", "completions",
    };
    for (commands) |known| {
        if (std.mem.eql(u8, command, known)) return true;
    }
    return false;
}

fn unknownCommand(command: []const u8, io: Io) noreturn {
    io.eprint("gitz: '{s}' is not a gitz command. See 'gitz --help'.\n", .{command}) catch {};
    std.process.exit(Exit.usage);
}

/// Locate the repository's git directory.
///
/// The previous implementation only checked the current directory for `.gitz`,
/// so every command failed from any subdirectory (`cd src && gitz status` →
/// "not a gitz repository"). Git walks up the tree, honours `GIT_DIR`, and
/// accepts both a `.git` directory and a `.git` *file* (the worktree/submodule
/// indirection). All of that is implemented here so gitz behaves the way
/// anyone typing `gitz` in a project directory expects.
///
/// `GIT_DIR` wins when set. Otherwise `.gitz` is preferred over `.git` in the
/// same directory, so a gitz repository is never shadowed by a git one.
fn findGitDir(allocator: std.mem.Allocator, io: *Io) ![]const u8 {
    if (io.get("GIT_DIR")) |env_dir| {
        defer allocator.free(env_dir);
        if (env_dir.len > 0) return allocator.dupe(u8, env_dir);
    }

    // `realPath("")` resolves relative to the cwd *handle* and fails on POSIX,
    // so the current directory is obtained by resolving ".".
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io.io, ".", allocator);
    var dir = try allocator.dupe(u8, cwd);
    defer allocator.free(dir);

    // An owned copy, because the walk frees and reallocates `dir` on every
    // iteration and the starting directory is still needed to compute the
    // subdirectory prefix.
    const start_dir = try allocator.dupe(u8, cwd);
    defer allocator.free(start_dir);

    while (true) {
        if (try gitDirIn(allocator, io.*, dir)) |found| {
            // Commands treat every path as relative to the worktree root, so
            // from a subdirectory `root.txt` looked like a deleted file. Move
            // the process to the root and remember the subdirectory prefix so
            // user-supplied pathspecs can be rebased onto it.
            try moveToWorktreeRoot(io, dir);
            io.setSubdirPrefix(start_dir, dir);
            return found;
        }

        const parent = std.fs.path.dirname(dir) orelse break;
        if (std.mem.eql(u8, parent, dir)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(dir);
        dir = next;
    }

    return error.NotAGitRepo;
}

/// Change the process working directory to the repository's worktree root.
///
/// `std.Io` has no chdir in the vtable, so the POSIX syscall is used directly,
/// consistent with the raw `getdents64`/`openat` calls elsewhere in the tree.
fn moveToWorktreeRoot(io: *Io, root: []const u8) !void {
    _ = io;
    if (builtin.os.tag != .linux) return;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (root.len >= buf.len) return;
    @memcpy(buf[0..root.len], root);
    buf[root.len] = 0;

    const rc = std.os.linux.chdir(@ptrCast(&buf));
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => {}, // Staying put is better than aborting the command.
    }
}

/// Resolve the git dir for one directory, handling the `.git` file indirection.
///
/// A `.git` file contains `gitdir: <path>`, which git supports for worktrees and
/// submodules. Ignoring it made every such repository invisible.
fn gitDirIn(allocator: std.mem.Allocator, io: Io, dir: []const u8) !?[]const u8 {
    if (io.isDirAt(dir, ".gitz")) {
        return try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dir});
    }

    if (io.isDirAt(dir, ".git")) {
        return try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    }

    if (io.isFileAt(dir, ".gitz")) {
        return try resolveGitdirFile(allocator, io, dir, ".gitz");
    }
    if (io.isFileAt(dir, ".git")) {
        return try resolveGitdirFile(allocator, io, dir, ".git");
    }

    return null;
}

/// Read a `gitdir: <path>` indirection file and resolve the path it points to.
fn resolveGitdirFile(allocator: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8) !?[]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(path);

    const content = io.readFileAlloc(path) catch return null;
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir:")) return null;

    const target = std.mem.trim(u8, trimmed["gitdir:".len..], " \t\r\n");
    if (target.len == 0) return null;

    if (std.fs.path.isAbsolute(target)) {
        return try allocator.dupe(u8, target);
    }
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, target });
}
