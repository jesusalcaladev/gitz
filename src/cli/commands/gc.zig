const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const storage_mod = @import("../../core/storage.zig");
const objectstore_mod = @import("../../core/objectstore.zig");
const refs_mod = @import("../../core/refs.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    _ = args;

    try io.print("Counting objects: ", .{});

    // 1. First, prune unreachable objects
    var reachable = std.AutoHashMap([20]u8, void).init(allocator);
    defer reachable.deinit();

    const refs_manager = refs_mod.Refs.init(git_dir);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);

    const heads = try refs_manager.list(allocator, io.io, "heads");
    defer {
        for (heads) |h| allocator.free(h);
        allocator.free(heads);
    }
    const tags = try refs_manager.list(allocator, io.io, "tags");
    defer {
        for (tags) |t| allocator.free(t);
        allocator.free(tags);
    }

    for (heads) |ref| {
        const sha = refs_manager.read(allocator, io.io, ref) catch continue;
        try markReachable(allocator, io.io, store, &reachable, sha);
    }
    for (tags) |ref| {
        const sha = refs_manager.read(allocator, io.io, ref) catch continue;
        try markReachable(allocator, io.io, store, &reachable, sha);
    }

    var loose_count: u32 = 0;
    var freed_count: u32 = 0;
    const objects_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir});
    defer allocator.free(objects_dir_path);

    for (0..256) |hi| {
        var dir_name_buf: [3]u8 = undefined;
        dir_name_buf[0] = "0123456789abcdef"[hi >> 4];
        dir_name_buf[1] = "0123456789abcdef"[hi & 0x0f];
        dir_name_buf[2] = 0;

        const dir_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ objects_dir_path, dir_name_buf[0..2] });
        defer allocator.free(dir_path);

        var dir = std.Io.Dir.cwd().openDir(io.io, dir_path, .{}) catch continue;
        defer dir.close(io.io);

        var iter = dir.iterate();
        while (iter.next(io.io) catch null) |entry| {
            if (entry.kind != .file) continue;

            loose_count += 1;

            var full_hex: [40]u8 = undefined;
            full_hex[0] = dir_name_buf[0];
            full_hex[1] = dir_name_buf[1];
            @memcpy(full_hex[2..][0..entry.name.len], entry.name);

            const sha = Sha1.fromHex(full_hex[0 .. 2 + entry.name.len]) catch continue;

            if (!reachable.contains(sha)) {
                const obj_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
                defer allocator.free(obj_path);
                std.Io.Dir.cwd().deleteFile(io.io, obj_path) catch {};
                freed_count += 1;
            }
        }
    }

    try io.print("{d}, done.\n", .{loose_count});
    if (freed_count > 0) {
        try io.print("Pruning {d} unreachable objects\n", .{freed_count});
    } else {
        try io.print("No unreachable objects to prune.\n", .{});
    }

    // 2. Pack loose objects into DAG-aware packfiles
    if (freed_count > 0 or loose_count > 100) {
        try io.print("Packing objects with DAG-aware layout...\n", .{});
        var obj_store = objectstore_mod.ObjectStore.init(git_dir);
        defer obj_store.deinit(allocator);

        const packed_count = obj_store.gc(allocator, io.io) catch |err| {
            try io.print("gc packing failed: {s}\n", .{@errorName(err)});
            return;
        };

        if (packed_count > 0) {
            try io.print("Packed {d} objects into DAG-ordered packfile\n", .{packed_count});
            try io.print("Objects are now sorted topologically for sequential cache-friendly reads\n", .{});
        }
    }
}

fn markReachable(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage_mod.StorageBackend,
    reachable: *std.AutoHashMap([20]u8, void),
    sha: [20]u8,
) !void {
    if (reachable.contains(sha)) return;
    try reachable.put(sha, {});

    const obj = store.read(allocator, io, sha) catch return;
    switch (obj) {
        .commit => |commit| {
            for (commit.parents) |parent| {
                try markReachable(allocator, io, store, reachable, parent);
            }
            try markReachable(allocator, io, store, reachable, commit.tree);
        },
        .tree => |tree| {
            for (tree.entries) |entry| {
                try markReachable(allocator, io, store, reachable, entry.sha);
            }
        },
        .blob => {},
        .tag => |tag| {
            try markReachable(allocator, io, store, reachable, tag.object);
        },
    }
}
