const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const refs_mod = @import("../../core/refs.zig");
const http = @import("../../transport/http.zig");
const remote_cmd = @import("remote.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var remote_name: ?[]const u8 = null;
    var refspec: ?[]const u8 = null;
    var force = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (remote_name == null) {
                remote_name = arg;
            } else if (refspec == null) {
                refspec = arg;
            }
        }
    }

    const name = remote_name orelse "origin";
    const ref = refspec orelse refspec: {
        // Get current branch name
        const refs_manager = refs_mod.Refs.init(git_dir);
        var head_info = refs_manager.head(allocator, io.io) catch {
            try io.eprint("fatal: not a gitz repository\n", .{});
            return;
        };
        defer head_info.deinit(allocator);
        break :refspec switch (head_info) {
            .branch => |b| try allocator.dupe(u8, b.name.items),
            .detached => {
                try io.eprint("fatal: not on a branch\n", .{});
                return;
            },
        };
    };
    defer if (refspec == null) allocator.free(ref);

    // Get remote URL
    const url = remote_cmd.getRemoteUrl(allocator, git_dir, name, io);
    defer if (url) |u| allocator.free(u);

    if (url == null) {
        try io.eprint("fatal: '{s}' does not appear to be a git repository\n", .{name});
        return;
    }

    // Get the commit SHA to push
    const refs_manager = refs_mod.Refs.init(git_dir);
    const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{ref});
    defer allocator.free(ref_name);

    const push_sha = refs_manager.read(allocator, io.io, ref_name) catch {
        try io.eprint("error: src refspec '{s}' does not match any\n", .{ref});
        return;
    };

    // Check if force is needed (non-fast-forward)
    if (!force) {
        // In a full implementation, we'd check if the remote has commits
        // that would be lost. For now, allow all pushes.
    }

    var transport = try http.HttpTransport.init(allocator, io.io, url.?);
    defer transport.deinit();

    // The wire protocol requires the fully-qualified ref name.
    const full_ref = if (std.mem.startsWith(u8, ref, "refs/"))
        try allocator.dupe(u8, ref)
    else
        try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{ref});
    defer allocator.free(full_ref);

    transport.push(git_dir, full_ref, push_sha) catch |err| {
        try io.eprint("error: failed to push '{s}' to {s}\n", .{ ref, url.? });
        switch (err) {
            error.PushRejected => {
                try io.eprint("! [remote rejected] {s} (check remote permissions/history)\n", .{ref});
                return;
            },
            else => return err,
        }
    };

    try io.print("To {s}\n", .{url.?});
    try io.print("   *       {s} -> {s}\n", .{ ref, full_ref });
}
