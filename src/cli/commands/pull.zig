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

    // Determine the current branch so we rebase onto <remote>/<same-branch>
    const refs_manager = @import("../../core/refs.zig").Refs.init(git_dir);
    const current_branch: ?[]const u8 = blk: {
        var head_info = refs_manager.head(allocator, io.io) catch break :blk null;
        defer head_info.deinit(allocator);
        break :blk switch (head_info) {
            .branch => |b| allocator.dupe(u8, b.name.items) catch null,
            .detached => null,
        };
    };

    const target_branch = current_branch orelse "main";

    if (merge_mode) {
        try io.print("Merging {s}/{s} into current branch...\n", .{ name, target_branch });
        const merge_args = [_][]const u8{try std.fmt.allocPrint(allocator, "{s}/{s}", .{ name, target_branch })};
        try @import("merge.zig").execute(allocator, git_dir, &merge_args, io);
    } else {
        try io.print("Rebasing onto {s}/{s}...\n", .{ name, target_branch });
        const rebase_args = [_][]const u8{try std.fmt.allocPrint(allocator, "{s}/{s}", .{ name, target_branch })};
        try @import("rebase.zig").execute(allocator, git_dir, &rebase_args, io);
    }
}
