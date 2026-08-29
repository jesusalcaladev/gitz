const std = @import("std");
const Io = @import("../../util/io.zig").Io;

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var remote_name: ?[]const u8 = null;
    var use_git = false;
    var force = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--git") or std.mem.eql(u8, arg, "-g")) {
            use_git = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try io.print(
                \\usage: gitz sync [remote] [--force] [--git]
                \\
                \\Fetch and rebase onto the remote branch.
                \\Equivalent to: gitz fetch <remote> && gitz rebase <remote>/<branch>
                \\
                \\Options:
                \\  --force, -f    Force push after sync (use with caution)
                \\  --git, -g      Use system git for fetch/rebase
                \\
            , .{});
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            remote_name = arg;
        }
    }

    const name = remote_name orelse "origin";

    // Detect current branch
    const current_branch = detectCurrentBranch(allocator, git_dir, io) catch {
        try io.eprint("fatal: not on any branch\n", .{});
        return;
    };
    defer allocator.free(current_branch);

    try io.print("\x1b[1;36mSyncing {s} ({s})...\x1b[0m\n\n", .{ name, current_branch });

    // Step 1: Fetch
    try io.print("\x1b[2m[1/2] Fetching from {s}...\x1b[0m\n", .{name});
    const fetch_args = [_][]const u8{name};
    @import("fetch.zig").execute(allocator, git_dir, &fetch_args, io) catch {
        try io.eprint("\x1b[31mFetch failed.\x1b[0m\n", .{});
        if (!use_git) {
            try io.print("Try: gitz sync --git\n", .{});
        }
        return;
    };

    // Step 2: Rebase onto remote branch
    const remote_branch = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ name, current_branch });
    defer allocator.free(remote_branch);

    try io.print("\x1b[2m[2/2] Rebasing onto {s}...\x1b[0m\n", .{remote_branch});
    const rebase_args = [_][]const u8{remote_branch};
    @import("rebase.zig").execute(allocator, git_dir, &rebase_args, io) catch {
        if (force) {
            try io.print("\x1b[33mRebase had conflicts, but --force was specified.\x1b[0m\n", .{});
            try io.print("Note: --force does not auto-resolve conflicts. Use 'gitz rebase --abort' to cancel.\n", .{});
        } else {
            try io.eprint("\x1b[31mRebase failed (conflicts?).\x1b[0m\n", .{});
            try io.print("To abort: gitz rebase --abort\n", .{});
            try io.print("To force: gitz sync --force\n", .{});
        }
        return;
    };

    try io.print("\n\x1b[1;32m✓ Sync complete!\x1b[0m\n", .{});
    try io.print("  Branch \x1b[1m{s}\x1b[0m is now up to date with \x1b[1m{s}\x1b[0m\n", .{ current_branch, remote_branch });
}

fn detectCurrentBranch(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: Io,
) ![]const u8 {
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);

    var f = std.Io.Dir.cwd().openFile(io.io, head_path, .{}) catch return error.NotOnBranch;
    defer f.close(io.io);

    var buf: [256]u8 = undefined;
    const n = try f.readStreaming(io.io, &.{&buf});
    const content = std.mem.trim(u8, buf[0..n], " \n\r");

    if (std.mem.startsWith(u8, content, "ref: refs/heads/")) {
        return try allocator.dupe(u8, content[15..]);
    }

    return error.DetachedHead;
}
