const std = @import("std");
const Io = @import("../../util/io.zig").Io;

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var merge_mode = false;
    var remote_name: ?[]const u8 = null;
    var use_git = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--merge") or std.mem.eql(u8, arg, "-m")) {
            merge_mode = true;
        } else if (std.mem.eql(u8, arg, "--rebase") or std.mem.eql(u8, arg, "-r")) {
            merge_mode = false;
        } else if (std.mem.eql(u8, arg, "--git") or std.mem.eql(u8, arg, "-g")) {
            use_git = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            remote_name = arg;
        }
    }

    const name = remote_name orelse "origin";

    // Try git fallback if --git flag or if gitz transport might fail
    if (use_git) {
        try pullViaGit(allocator, git_dir, name, merge_mode, io);
        return;
    }

    // Step 1: Fetch
    try io.print("Fetching {s}\n", .{name});
    const fetch_args = [_][]const u8{name};
    @import("fetch.zig").execute(allocator, git_dir, &fetch_args, io) catch {
        // Fetch failed, try git fallback
        try io.print("Note: Falling back to git for pull\n", .{});
        try pullViaGit(allocator, git_dir, name, merge_mode, io);
        return;
    };

    // Step 2: Merge or rebase
    if (merge_mode) {
        try io.print("Merging {s}/main into current branch...\n", .{name});
        const merge_args = [_][]const u8{ try std.fmt.allocPrint(allocator, "{s}/main", .{name}) };
        defer allocator.free(merge_args[0]);
        try @import("merge.zig").execute(allocator, git_dir, &merge_args, io);
    } else {
        // Default: rebase
        try io.print("Rebasing onto {s}/main...\n", .{name});
        const rebase_args = [_][]const u8{ try std.fmt.allocPrint(allocator, "{s}/main", .{name}) };
        defer allocator.free(rebase_args[0]);
        try @import("rebase.zig").execute(allocator, git_dir, &rebase_args, io);
    }
}

/// Pull using system git as fallback
fn pullViaGit(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    remote_name: []const u8,
    merge_mode: bool,
    io: Io,
) !void {
    var git_cmd = std.ArrayList(u8).empty;
    defer git_cmd.deinit(allocator);
    try git_cmd.appendSlice(allocator, "GIT_DIR=");
    try git_cmd.appendSlice(allocator, git_dir);
    try git_cmd.appendSlice(allocator, " GIT_INDEX_FILE=/dev/null git pull ");
    try git_cmd.appendSlice(allocator, remote_name);
    if (merge_mode) {
        try git_cmd.appendSlice(allocator, " --merge");
    } else {
        try git_cmd.appendSlice(allocator, " --rebase");
    }

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "sh");
    try argv.append(allocator, "-c");
    try argv.append(allocator, git_cmd.items);

    const result = std.process.run(allocator, io.io, .{
        .argv = argv.items,
    }) catch |err| {
        try io.eprint("error: git pull failed: {}\n", .{err});
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stdout.len > 0) {
        try io.print("{s}", .{result.stdout});
    }
    if (result.stderr.len > 0) {
        try io.eprint("{s}", .{result.stderr});
    }
}
