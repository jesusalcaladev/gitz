const std = @import("std");
const Io = @import("../../util/io.zig").Io;

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var merge_mode = false;
    var remote_name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--merge") or std.mem.eql(u8, arg, "-m")) {
            merge_mode = true;
        } else if (std.mem.eql(u8, arg, "--rebase") or std.mem.eql(u8, arg, "-r")) {
            merge_mode = false;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            remote_name = arg;
        }
    }

    const name = remote_name orelse "origin";

    // Step 1: Fetch
    try io.print("Fetching {s}\n", .{name});
    const fetch_args = [_][]const u8{name};
    try @import("fetch.zig").execute(allocator, git_dir, &fetch_args, io);

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
