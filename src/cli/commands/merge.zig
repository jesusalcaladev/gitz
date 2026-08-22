const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var no_ff = false;
    var merge_msg: ?[]const u8 = null;
    var branch_name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--no-ff")) {
            no_ff = true;
        } else if (std.mem.eql(u8, args[i], "-m") and i + 1 < args.len) {
            i += 1;
            merge_msg = args[i];
        } else if (!std.mem.startsWith(u8, args[i], "-")) {
            branch_name = args[i];
        }
    }

    const name = branch_name orelse {
        try io.eprint("usage: gitz merge [--no-ff] [-m msg] <branch>\n", .{});
        std.process.exit(1);
    };

    const refs_manager = refs_mod.Refs.init(git_dir);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);

    // Resolve current branch
    var head_info = refs_manager.head(allocator, io.io) catch {
        try io.eprint("fatal: not a gitz repository\n", .{});
        return;
    };
    defer head_info.deinit(allocator);

    const current_sha = switch (head_info) {
        .branch => |b| b.sha,
        .detached => |d| d.sha,
    };

    // Resolve target branch
    const target_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
    defer allocator.free(target_ref);

    const target_sha = refs_manager.read(allocator, io.io, target_ref) catch {
        try io.eprint("error: branch '{s}' not found\n", .{name});
        return;
    };

    if (std.mem.eql(u8, &current_sha, &target_sha)) {
        try io.print("Already up to date.\n", .{});
        return;
    }

    // Check if target is ancestor of current (already merged)
    if (isAncestor(allocator, io.io, store, current_sha, target_sha)) {
        try io.print("Already up to date.\n", .{});
        return;
    }

    // Check if current is ancestor of target → fast-forward
    const is_ff = isAncestor(allocator, io.io, store, target_sha, current_sha);

    if (is_ff and !no_ff) {
        // Fast-forward: move CURRENT branch pointer to target SHA
        // First try to update the current branch ref
        if (switch (head_info) {
            .branch => |b| blk: {
                const current_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{b.name.items});
                defer allocator.free(current_ref);
                try refs_manager.write(allocator, io.io, current_ref, target_sha);
                break :blk true;
            },
            .detached => blk: {
                // Detached HEAD - update HEAD file directly
                const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
                defer allocator.free(head_path);
                var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
                defer hf.close(io.io);
                const hex2 = Sha1.hex(target_sha);
                var wbuf: [42]u8 = undefined;
                const wline = try std.fmt.bufPrint(&wbuf, "{s}\n", .{&hex2});
                try std.Io.File.writeStreamingAll(hf, io.io, wline);
                break :blk true;
            },
        }) {}
        const hex = Sha1.hex(target_sha);
        try io.print("Fast-forward\n", .{});
        try io.print(" {s}..{s} -> {s}\n", .{ Sha1.hex(current_sha)[0..7], hex[0..7], name });
        return;
    }

    // Create a merge commit with two parents
    // Use target's tree (the branch being merged in)
    const target_obj = store.read(allocator, io.io, target_sha) catch {
        try io.eprint("fatal: cannot read target commit\n", .{});
        return;
    };
    const target_commit = switch (target_obj) {
        .commit => |c| c,
        else => {
            try io.eprint("fatal: target is not a commit\n", .{});
            return;
        },
    };

    const now_ts = std.Io.Timestamp.now(io.io, .real);
    const now: i64 = @intCast(@divTrunc(now_ts.nanoseconds, std.time.ns_per_s));

    // Build merge commit with two parents: current and target
    var parents = try allocator.alloc([20]u8, 2);
    parents[0] = current_sha; // first parent is current branch
    parents[1] = target_sha; // second parent is the branch being merged

    const msg = merge_msg orelse msg: {
        var msg_buf: [128]u8 = undefined;
        const m = try std.fmt.bufPrint(&msg_buf, "Merge branch '{s}'", .{name});
        break :msg m;
    };

    const merge_commit = object.Commit{
        .tree = target_commit.tree,
        .parents = parents,
        .author = .{ .name = "GitZ User", .email = "user@gitz.dev", .timestamp = now, .timezone = "+0000" },
        .committer = .{ .name = "GitZ User", .email = "user@gitz.dev", .timestamp = now, .timezone = "+0000" },
        .message = msg,
    };

    const merge_sha = try store.write(allocator, io.io, object.GitObject{ .commit = merge_commit });

    // Update the CURRENT branch ref (not the target branch)
    if (switch (head_info) {
        .branch => |b| blk: {
            const current_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{b.name.items});
            defer allocator.free(current_ref);
            try refs_manager.write(allocator, io.io, current_ref, merge_sha);
            break :blk true;
        },
        .detached => false,
    }) {} else {
        // Detached HEAD - update HEAD directly
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
        defer allocator.free(head_path);
        var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
        defer hf.close(io.io);
        const hex2 = Sha1.hex(merge_sha);
        var wbuf: [42]u8 = undefined;
        const wline = try std.fmt.bufPrint(&wbuf, "{s}\n", .{&hex2});
        try std.Io.File.writeStreamingAll(hf, io.io, wline);
    }

    const hex = Sha1.hex(merge_sha);
    try io.print("Merge made by the 'ort' strategy.\n", .{});
    try io.print(" {s}\n", .{hex[0..7]});
    allocator.free(parents);
}

/// Check if 'possible_ancestor' is an ancestor of 'commit'
fn isAncestor(allocator: std.mem.Allocator, io: std.Io, store: storage_mod.StorageBackend, commit_sha: [20]u8, possible_ancestor: [20]u8) bool {
    var visited = std.AutoHashMap([20]u8, void).init(allocator);
    defer visited.deinit();

    var queue = std.ArrayList([20]u8){ .items = &.{}, .capacity = 0 };
    defer queue.deinit(allocator);

    queue.append(allocator, commit_sha) catch return false;

    while (queue.items.len > 0) {
        const sha = queue.pop() orelse break;
        if (std.mem.eql(u8, &sha, &possible_ancestor)) return true;
        if (visited.contains(sha)) continue;
        visited.put(sha, {}) catch continue;

        const obj = store.read(allocator, io, sha) catch continue;
        const commit = switch (obj) {
            .commit => |c| c,
            else => continue,
        };

        for (commit.parents) |parent| {
            queue.append(allocator, parent) catch continue;
        }
    }

    return false;
}
