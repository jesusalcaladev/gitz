const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const refs_mod = @import("../../core/refs.zig");
const fetch_cmd = @import("fetch.zig");
const rebase_cmd = @import("rebase.zig");
const push_cmd = @import("push.zig");

/// gitz sync [remote] — one-step fetch + rebase + push for the current branch.
pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var remote_name: ?[]const u8 = null;
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) remote_name = arg;
    }
    const name = remote_name orelse "origin";

    // Current branch (needed to compute <remote>/<branch>)
    const refs_manager = refs_mod.Refs.init(git_dir);
    const branch: ?[]const u8 = blk: {
        var head_info = refs_manager.head(allocator, io.io) catch break :blk null;
        defer head_info.deinit(allocator);
        break :blk switch (head_info) {
            .branch => |b| allocator.dupe(u8, b.name.items) catch null,
            .detached => null,
        };
    };
    const target_branch = branch orelse {
        try io.eprint("fatal: gitz sync requires a branch (HEAD is detached)\n", .{});
        std.process.exit(1);
    };

    // Step 1: fetch
    try io.print("{s}→ Fetching {s}{s}\n", .{ "\x1b[1m\x1b[96m", name, "\x1b[0m" });
    const fetch_args = [_][]const u8{name};
    try fetch_cmd.execute(allocator, git_dir, &fetch_args, io);

    // Step 2: rebase local commits onto <remote>/<branch>
    const upstream = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ name, target_branch });
    try io.print("{s}→ Rebasing onto {s}{s}\n", .{ "\x1b[1m\x1b[96m", upstream, "\x1b[0m" });
    const rebase_args = [_][]const u8{upstream};
    try rebase_cmd.execute(allocator, git_dir, &rebase_args, io);

    // Step 3: push
    try io.print("{s}→ Pushing {s} to {s}{s}\n", .{ "\x1b[1m\x1b[96m", target_branch, name, "\x1b[0m" });
    const push_args = [_][]const u8{ name, target_branch };
    try push_cmd.execute(allocator, git_dir, &push_args, io);

    try io.print("{s}✓ Sync complete{s}\n", .{ "\x1b[1m\x1b[92m", "\x1b[0m" });
}
