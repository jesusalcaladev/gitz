const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const refs = @import("../../core/refs.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    const refs_manager = refs.Refs.init(git_dir);

    if (args.len == 0) {
        try io.print("usage: gitz switch <branch>\n", .{});
        return;
    }

    var create = false;
    var branch_name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-c")) {
            create = true;
        } else if (branch_name == null) {
            branch_name = args[i];
        }
    }

    const name = branch_name orelse return;

    if (create) {
        const current_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
            try io.print("fatal: no commits yet\n", .{});
            return;
        };

        const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
        defer allocator.free(ref_name);

        _ = refs_manager.read(allocator, io.io, ref_name) catch {
            refs_manager.write(allocator, io.io, ref_name, current_sha) catch {
                try io.eprint("error: could not create branch '{s}'\n", .{name});
                return;
            };
            try refs_manager.writeSymbolic(allocator, io.io, "HEAD", ref_name);
            try io.print("Switched to a new branch '{s}'\n", .{name});
            return;
        };

        try io.eprint("error: a branch named '{s}' already exists\n", .{name});
        return;
    }

    const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
    defer allocator.free(ref_name);

    const sha = refs_manager.read(allocator, io.io, ref_name) catch {
        try io.eprint("error: pathspec '{s}' did not match any branch\n", .{name});
        return;
    };

    try refs_manager.writeSymbolic(allocator, io.io, "HEAD", ref_name);
    try refs_manager.write(allocator, io.io, ref_name, sha);
    try io.print("Switched to branch '{s}'\n", .{name});
}
