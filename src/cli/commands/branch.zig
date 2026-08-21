const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const refs_mod = @import("../../core/refs.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    const refs_manager = refs_mod.Refs.init(git_dir);

    if (args.len == 0) {
        // List branches
        const branches = try refs_manager.list(allocator, io.io, "heads");
        defer {
            for (branches) |b| allocator.free(b);
            allocator.free(branches);
        }

        var head_info = refs_manager.head(allocator, io.io) catch null;
        defer if (head_info) |*h| h.deinit(allocator);

        for (branches) |branch| {
            const name = if (std.mem.startsWith(u8, branch, "refs/heads/")) branch[11..] else branch;
            if (head_info) |hi| {
                switch (hi) {
                    .branch => |b| {
                        if (std.mem.eql(u8, name, b.name.items)) {
                            try io.print("* {s}\n", .{name});
                        } else {
                            try io.print("  {s}\n", .{name});
                        }
                    },
                    .detached => {
                        try io.print("  {s}\n", .{name});
                    },
                }
            } else {
                try io.print("  {s}\n", .{name});
            }
        }
        return;
    }

    var delete_mode = false;
    var force_delete = false;
    var rename_mode = false;
    var rename_old: ?[]const u8 = null;
    var rename_new: ?[]const u8 = null;
    var branch_name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-d")) {
            delete_mode = true;
        } else if (std.mem.eql(u8, args[i], "-D")) {
            delete_mode = true;
            force_delete = true;
        } else if (std.mem.eql(u8, args[i], "-m")) {
            rename_mode = true;
        } else if (!std.mem.startsWith(u8, args[i], "-")) {
            if (rename_mode) {
                if (rename_old == null) {
                    rename_old = args[i];
                } else {
                    rename_new = args[i];
                }
            } else if (branch_name == null) {
                branch_name = args[i];
            }
        }
    }

    if (rename_mode) {
        const old_name = rename_old orelse {
            try io.eprint("usage: gitz branch -m <old> <new>\n", .{});
            return;
        };
        const new_name = rename_new orelse old_name; // If only one name, it's just a rename of current

        const old_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{old_name});
        defer allocator.free(old_ref);
        const new_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{new_name});
        defer allocator.free(new_ref);

        // Check old branch exists
        const sha = refs_manager.read(allocator, io.io, old_ref) catch {
            try io.eprint("error: branch '{s}' not found\n", .{old_name});
            return;
        };

        // Check new branch doesn't exist
        _ = refs_manager.read(allocator, io.io, new_ref) catch {
            // Good, doesn't exist
            try refs_manager.write(allocator, io.io, new_ref, sha);
            try refs_manager.delete(allocator, io.io, old_ref);

            // Update HEAD if it pointed to old branch
            var head_file = std.Io.Dir.cwd().openFile(io.io,
                try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir}),
                .{},
            ) catch return;
            defer            head_file.close(io.io);
            var head_buf: [256]u8 = undefined;
            const n = try head_file.readStreaming(io.io, &.{&head_buf});
            const head_content = std.mem.trim(u8, head_buf[0..n], &[_]u8{ '\n', '\r', ' ' });
            const expected = try std.fmt.allocPrint(allocator, "ref: {s}", .{old_ref});
            defer allocator.free(expected);
            if (std.mem.eql(u8, head_content, expected)) {
                try refs_manager.writeSymbolic(allocator, io.io, "HEAD", new_ref);
            }

            try io.print("Branch '{s}' renamed to '{s}'\n", .{ old_name, new_name });
            return;
        };

        try io.eprint("error: a branch named '{s}' already exists\n", .{new_name});
        return;
    }

    if (delete_mode) {
        const name = branch_name orelse return;
        const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
        defer allocator.free(ref_name);

        // Check if it's the current branch
        var head_info = refs_manager.head(allocator, io.io) catch null;
        defer if (head_info) |*h| h.deinit(allocator);

        if (head_info) |hi| {
            switch (hi) {
                .branch => |b| {
                    if (std.mem.eql(u8, name, b.name.items) and !force_delete) {
                        try io.eprint("error: cannot delete branch '{s}': checked out\n", .{name});
                        return;
                    }
                },
                .detached => {},
            }
        }

        refs_manager.delete(allocator, io.io, ref_name) catch {
            try io.eprint("error: branch '{s}' not found\n", .{name});
            return;
        };
        try io.print("Deleted branch {s}\n", .{name});
        return;
    }

    // Create branch
    const name = branch_name orelse return;
    const sha = try refs_manager.read(allocator, io.io, "HEAD");
    const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
    defer allocator.free(ref_name);

    _ = refs_manager.read(allocator, io.io, ref_name) catch {
        refs_manager.write(allocator, io.io, ref_name, sha) catch {
            try io.eprint("error: could not create branch '{s}'\n", .{name});
            return;
        };
        try io.print("Created branch '{s}'\n", .{name});
        return;
    };

    try io.eprint("error: a branch named '{s}' already exists\n", .{name});
}
