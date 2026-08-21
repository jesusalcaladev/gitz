const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const loose = @import("../../core/loose.zig");
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var soft = false;
    var count: usize = 1;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--soft")) {
            soft = true;
        } else if (std.mem.eql(u8, args[i], "--hard")) {
            soft = false;
        } else if (std.mem.startsWith(u8, args[i], "HEAD~")) {
            const num_str = args[i][5..];
            count = std.fmt.parseInt(usize, num_str, 10) catch 1;
        } else if (std.mem.startsWith(u8, args[i], "-")) {
            // skip flags
        } else {
            count = std.fmt.parseInt(usize, args[i], 10) catch 1;
        }
    }

    const refs_manager = refs_mod.Refs.init(git_dir);
    const store = loose.LooseStore.init(git_dir);

    const current_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
        try io.eprint("fatal: no commits yet\n", .{});
        return;
    };

    var target_sha = current_sha;
    for (0..count) |_| {
        const obj = store.read(allocator, io.io, target_sha) catch {
            try io.eprint("fatal: cannot read commit\n", .{});
            return;
        };
        const commit = switch (obj) {
            .commit => |c| c,
            else => {
                try io.eprint("fatal: HEAD is not a commit\n", .{});
                return;
            },
        };
        if (commit.parents.len == 0) {
            try io.eprint("error: cannot undo the initial commit\n", .{});
            return;
        }
        target_sha = commit.parents[0];
    }

    const target_obj = store.read(allocator, io.io, target_sha) catch {
        try io.eprint("fatal: cannot read target commit\n", .{});
        return;
    };
    const target_commit = switch (target_obj) {
        .commit => |c| c,
        else => unreachable,
    };

    var head_file = std.Io.Dir.cwd().openFile(io.io,
        try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir}),
        .{},
    ) catch {
        try io.eprint("fatal: could not open HEAD\n", .{});
        return;
    };
    defer head_file.close(io.io);

    var head_buf: [256]u8 = undefined;
    const n = try head_file.readStreaming(io.io, &.{&head_buf});
    const head_content = std.mem.trim(u8, head_buf[0..n], &[_]u8{ '\n', '\r', ' ' });

    if (std.mem.startsWith(u8, head_content, "ref: ")) {
        const ref_target = head_content[5..];
        try refs_manager.write(allocator, io.io, ref_target, target_sha);

        const hex_old = Sha1.hex(current_sha);
        const hex_new = Sha1.hex(target_sha);
        try io.print("HEAD is now at {s} {s}\n", .{ hex_new[0..7], target_commit.message });
        _ = hex_old;
    } else {
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
        defer allocator.free(head_path);
        var f = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
        defer f.close(io.io);
        const hex = Sha1.hex(target_sha);
        var wbuf: [42]u8 = undefined;
        const wline = try std.fmt.bufPrint(&wbuf, "{s}\n", .{&hex});
        try std.Io.File.writeStreamingAll(f, io.io, wline);
    }

    if (!soft) {
        try io.print("(use 'gitz diff' to verify)\n", .{});
    }
}
