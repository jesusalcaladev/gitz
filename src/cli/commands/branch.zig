const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const Sha1 = @import("../../core/sha1.zig").Sha1;
const errors = @import("../errors.zig");

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
        if (!refs_mod.Refs.isValidRefName(name)) {
            errors.errorf(io, "'{s}' is not a valid branch name", .{name});
        }
        const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
        defer allocator.free(ref_name);

        // The current branch can never be deleted, not even with -D. Removing it
        // left HEAD pointing at a ref that no longer existed, so the next
        // `gitz status` reported "HEAD detached at 0000000" and the next
        // `gitz commit` created a root commit on a bogus history.
        var head_info = refs_manager.head(allocator, io.io) catch null;
        defer if (head_info) |*h| h.deinit(allocator);

        if (head_info) |hi| {
            switch (hi) {
                .branch => |b| {
                    if (std.mem.eql(u8, name, b.name.items)) {
                        try io.eprint("error: cannot delete branch '{s}': checked out\n", .{name});
                        std.process.exit(1);
                    }
                },
                .detached => {},
            }
        }

        const target_sha = refs_manager.read(allocator, io.io, ref_name) catch {
            try io.eprint("error: branch '{s}' not found\n", .{name});
            std.process.exit(1);
        };
        const target_hex = Sha1.hex(target_sha);

        // `-d` refuses to delete a branch whose commits are not reachable from
        // the current HEAD, exactly like git. There was no mergedness check at
        // all, so a plain `-d` destroyed work that was not merged anywhere, and
        // a later gc made it unrecoverable.
        if (!force_delete) {
            const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
            const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch null;
            // "Fully merged" means the branch tip is reachable *from* the
            // current HEAD, so the walk starts at HEAD and looks for the tip.
            const merged = if (head_sha) |h| isAncestor(allocator, io.io, store, target_sha, h) else false;
            if (!merged) {
                try io.eprint("error: the branch '{s}' is not fully merged\n", .{name});
                try io.eprint("If you are sure you want to delete it, run 'gitz branch -D {s}'.\n", .{name});
                std.process.exit(1);
            }
        }

        refs_manager.delete(allocator, io.io, ref_name) catch {
            try io.eprint("error: branch '{s}' not found\n", .{name});
            std.process.exit(1);
        };
        try io.print("Deleted branch {s} (was {s})\n", .{ name, target_hex[0..7] });
        return;
    }

    // Create branch
    const name = branch_name orelse return;
    if (!refs_mod.Refs.isValidRefName(name)) {
        errors.errorf(io, "'{s}' is not a valid branch name", .{name});
    }
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
    std.process.exit(1);
}

/// Whether `ancestor` is reachable from `descendant` by walking parents.
///
/// Used by `branch -d` to decide whether a branch is fully merged. The walk is
/// bounded and keeps a visited set so a corrupt (cyclic) commit graph cannot
/// spin forever.
fn isAncestor(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage_mod.StorageBackend,
    ancestor: [20]u8,
    descendant: [20]u8,
) bool {
    var visited = std.AutoHashMap([20]u8, void).init(allocator);
    defer visited.deinit();

    var queue = std.ArrayList([20]u8).empty;
    defer queue.deinit(allocator);

    queue.append(allocator, descendant) catch return false;

    const max_steps: usize = 1_000_000;
    var steps: usize = 0;

    while (queue.items.len > 0) {
        steps += 1;
        if (steps > max_steps) return false;

        const sha = queue.orderedRemove(0);
        if (std.mem.eql(u8, &sha, &ancestor)) return true;
        if (visited.contains(sha)) continue;
        visited.put(sha, {}) catch return false;

        const obj = store.read(allocator, io, sha) catch continue;
        defer obj.deinit(allocator);
        const commit = switch (obj) {
            .commit => |c| c,
            else => continue,
        };
        for (commit.parents) |parent| queue.append(allocator, parent) catch {};
    }

    return false;
}
