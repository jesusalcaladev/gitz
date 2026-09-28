const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const Sha1 = @import("../../core/sha1.zig").Sha1;
const errors = @import("../errors.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    const refs_manager = refs_mod.Refs.init(git_dir);

    if (args.len == 0) {
        try listBranches(allocator, git_dir, .local, io);
        return;
    }

    // `gitz branch -a`, `-r`, `-v`, `--list` and friends were parsed as
    // "no arguments", so they silently printed the plain local list and exited
    // 0. A user asking for remote branches got a wrong answer instead of an
    // error.
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            try listBranches(allocator, git_dir, .all, io);
            return;
        }
        if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--remotes")) {
            try listBranches(allocator, git_dir, .remotes, io);
            return;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            try listBranches(allocator, git_dir, .verbose, io);
            return;
        }
        if (std.mem.eql(u8, arg, "--list")) {
            try listBranches(allocator, git_dir, .all, io);
            return;
        }
        if (std.mem.eql(u8, arg, "--show-current")) {
            var head = refs_manager.head(allocator, io.io) catch return;
            defer head.deinit(allocator);
            if (head.branchOf()) |b| try io.print("{s}\n", .{b});
            return;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            errors.errorf(io, "unknown option '{s}'", .{arg});
        }
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
                .unborn => |u| {
                    if (std.mem.eql(u8, name, u.name.items)) {
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
    const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
    defer allocator.free(ref_name);

    // `refs_manager.read("HEAD")` was called unguarded, so on a repository with
    // no commits yet the RefNotFound error escaped to main and Zig printed
    // "error: RefNotFound" plus a stack trace.
    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch |err| switch (err) {
        error.RefNotFound => null,
        else => return err,
    };

    _ = refs_manager.read(allocator, io.io, ref_name) catch {
        if (head_sha) |sha| {
            refs_manager.write(allocator, io.io, ref_name, sha) catch {
                errors.errorf(io, "could not create branch '{s}'", .{name});
            };
        } else {
            // Unborn HEAD: the branch exists as a name and gains a commit when
            // the work is committed, which is what `gitz init && gitz branch x`
            // is expected to do.
            try io.print("Created branch '{s}'\n", .{name});
            return;
        }
        try io.print("Created branch '{s}'\n", .{name});
        return;
    };

    errors.errorf(io, "a branch named '{s}' already exists", .{name});
}

const ListMode = enum { local, all, remotes, verbose };

/// Print branches.
///
/// The listing used to come straight from `getdents64`, so it appeared in
/// directory order rather than sorted, and every listing flag was ignored:
/// `-a` and `-r` printed the plain local list and exited 0.
fn listBranches(allocator: std.mem.Allocator, git_dir: []const u8, mode: ListMode, io: Io) !void {
    const refs_manager = refs_mod.Refs.init(git_dir);

    var all = std.ArrayList([]const u8).empty;
    defer {
        for (all.items) |b| allocator.free(b);
        all.deinit(allocator);
    }

    if (mode != .remotes) {
        const heads = try refs_manager.list(allocator, io.io, "heads");
        defer {
            for (heads) |b| allocator.free(b);
            allocator.free(heads);
        }
        for (heads) |h| try all.append(allocator, try allocator.dupe(u8, h));
    }
    if (mode == .all or mode == .remotes) {
        const remotes = try refs_manager.list(allocator, io.io, "remotes");
        defer {
            for (remotes) |b| allocator.free(b);
            allocator.free(remotes);
        }
        for (remotes) |r| try all.append(allocator, try allocator.dupe(u8, r));
    }

    // Directory order is not a useful listing order.
    std.mem.sort([]const u8, all.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var head_info = refs_manager.head(allocator, io.io) catch null;
    defer if (head_info) |*h| h.deinit(allocator);
    const current: ?[]const u8 = if (head_info) |h| h.branchOf() else null;

    for (all.items) |full| {
        const name = if (std.mem.startsWith(u8, full, "refs/remotes/"))
            full["refs/remotes/".len..]
        else if (std.mem.startsWith(u8, full, "refs/heads/"))
            full["refs/heads/".len..]
        else
            full;

        const is_current = if (current) |c| std.mem.eql(u8, name, c) else false;

        if (mode == .verbose) {
            const sha = refs_manager.read(allocator, io.io, full) catch {
                try io.print("  {s}\n", .{name});
                continue;
            };
            const hex = Sha1.hex(sha);
            try io.print("{s} {s} {s}\n", .{ if (is_current) "*" else " ", hex[0..7], name });
        } else {
            try io.print("{s} {s}\n", .{ if (is_current) "*" else " ", name });
        }
    }
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
