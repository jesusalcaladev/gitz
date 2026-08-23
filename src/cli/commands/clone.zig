const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const zlib_mod = @import("../../core/zlib.zig");
const http = @import("../../transport/http.zig");
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const Sha1 = @import("../../core/sha1.zig").Sha1;

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, io: Io) !void {
    if (args.len == 0) {
        try io.eprint("usage: gitz clone <url> [directory]\n", .{});
        std.process.exit(1);
    }

    const url = args[0];

    const dest = if (args.len > 1) args[1] else dest: {
        const last_slash = std.mem.lastIndexOf(u8, url, "/") orelse url.len;
        var name = url[last_slash..];
        if (name.len > 0 and name[0] == '/') name = name[1..];
        if (std.mem.lastIndexOf(u8, name, ":")) |colon_pos| {
            name = name[colon_pos + 1 ..];
        }
        if (std.mem.endsWith(u8, name, ".git")) {
            name = name[0 .. name.len - 4];
        }
        break :dest name;
    };

    try io.print("Cloning into '{s}'...\n", .{dest});

    // Create destination directory structure
    std.Io.Dir.cwd().createDirPath(io.io, dest) catch {};

    // Create .gitz structure
    const gitz_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dest});
    defer allocator.free(gitz_dir);
    std.Io.Dir.cwd().createDirPath(io.io, gitz_dir) catch {};

    const refs_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/heads", .{dest});
    defer allocator.free(refs_dir);
    std.Io.Dir.cwd().createDirPath(io.io, refs_dir) catch {};

    const tags_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/tags", .{dest});
    defer allocator.free(tags_dir);
    std.Io.Dir.cwd().createDirPath(io.io, tags_dir) catch {};

    const objects_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/objects", .{dest});
    defer allocator.free(objects_dir);
    std.Io.Dir.cwd().createDirPath(io.io, objects_dir) catch {};

    // Write HEAD
    const head_path = try std.fmt.allocPrint(allocator, "{s}/.gitz/HEAD", .{dest});
    defer allocator.free(head_path);
    var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
    defer hf.close(io.io);
    try std.Io.File.writeStreamingAll(hf, io.io, "ref: refs/heads/main\n");

    // Write remote config
    const remotes_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/remotes", .{dest});
    defer allocator.free(remotes_dir);
    std.Io.Dir.cwd().createDirPath(io.io, remotes_dir) catch {};
    const remote_path = try std.fmt.allocPrint(allocator, "{s}/.gitz/remotes/origin", .{dest});
    defer allocator.free(remote_path);
    io.writeFile(remote_path, url) catch {};

    // Use native HTTP transport to discover refs and fetch objects
    var transport = http.HttpTransport.init(allocator, io.io, url) catch {
        try io.eprint("fatal: could not connect to '{s}'\n", .{url});
        return;
    };
    defer transport.deinit();

    const remote_refs = transport.discoverRefs() catch {
        try io.eprint("fatal: could not read from remote repository.\n", .{});
        try io.eprint("Please make sure you have the correct access rights\n", .{});
        try io.eprint("and the repository exists.\n", .{});
        return;
    };
    defer {
        for (remote_refs) |r| allocator.free(r.name);
        allocator.free(remote_refs);
    }

    if (remote_refs.len == 0) {
        try io.eprint("fatal: no refs found on remote\n", .{});
        return;
    }

    // Find default branch (main or master)
    var head_sha: ?[20]u8 = null;
    var default_branch: ?[]const u8 = null;
    for (remote_refs) |ref| {
        if (std.mem.eql(u8, ref.name, "refs/heads/main") or
            std.mem.eql(u8, ref.name, "refs/heads/master"))
        {
            head_sha = ref.sha;
            default_branch = ref.name;
            break;
        }
    }
    if (head_sha == null) {
        head_sha = remote_refs[0].sha;
        default_branch = remote_refs[0].name;
    }

    // Write all remote refs locally
    const refs_manager = refs_mod.Refs.init(gitz_dir);
    var ref_count: u32 = 0;
    for (remote_refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            refs_manager.write(allocator, io.io, ref.name, ref.sha) catch continue;
            ref_count += 1;

            // Write remote-tracking ref
            const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{ref.name[11..]});
            defer allocator.free(remote_ref);
            const remote_ref_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/remotes/origin", .{dest});
            defer allocator.free(remote_ref_dir);
            std.Io.Dir.cwd().createDirPath(io.io, remote_ref_dir) catch {};
            refs_manager.write(allocator, io.io, remote_ref, ref.sha) catch {};
        } else if (std.mem.startsWith(u8, ref.name, "refs/tags/")) {
            refs_manager.write(allocator, io.io, ref.name, ref.sha) catch {};
            ref_count += 1;
        }
    }

    // Set HEAD to default branch
    if (default_branch) |db| {
        const branch_name = if (std.mem.startsWith(u8, db, "refs/heads/")) db[11..] else db;
        const symbolic_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name});
        defer allocator.free(symbolic_ref);
        refs_manager.writeSymbolic(allocator, io.io, "HEAD", symbolic_ref) catch {};
    }

    // Fetch all objects
    transport.fetch(gitz_dir, remote_refs, &.{}) catch {
        try io.eprint("warning: fetch incomplete, some objects may be missing\n", .{});
    };

    // Checkout files from HEAD commit
    if (head_sha) |sha| {
        checkoutFiles(allocator, io, gitz_dir, sha, dest) catch {
            try io.eprint("warning: checkout incomplete\n", .{});
        };
    }

    var object_count: u32 = 0;
    // Count objects in the new repo
    const obj_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/objects", .{dest});
    defer allocator.free(obj_dir);
    countObjects(allocator, io, obj_dir, &object_count) catch {};

    try io.print("Cloned into '{s}'\n", .{dest});
    try io.print("  {d} refs, {d} objects\n", .{ ref_count, object_count });
}

/// Count loose objects by scanning the fixed 256 shard dirs (objects/XX).
/// Deterministic layout walk avoids fragile recursive directory iteration.
fn countObjects(allocator: std.mem.Allocator, io: Io, dir_path: []const u8, count: *u32) !void {
    var total: u32 = 0;
    var shard: usize = 0;
    while (shard < 256) : (shard += 1) {
        const shard_path = try std.fmt.allocPrint(allocator, "{s}/{x:0>2}", .{ dir_path, shard });
        defer allocator.free(shard_path);

        var dir = std.Io.Dir.cwd().openDir(io.io, shard_path, .{ .iterate = true }) catch continue;
        defer dir.close(io.io);

        var iter = dir.iterate();
        while (true) {
            const entry = iter.next(io.io) catch break orelse break;
            if (entry.kind != .directory and entry.name.len == 38) {
                total += 1;
            }
        }
    }
    count.* = total;
}

/// Checkout files from a commit into a directory
fn checkoutFiles(allocator: std.mem.Allocator, io: Io, git_dir: []const u8, commit_sha: [20]u8, dest: []const u8) !void {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);

    // Read commit
    const obj = store.read(allocator, io.io, commit_sha) catch return;
    const commit = switch (obj) {
        .commit => |c| c,
        else => return,
    };

    // Read tree
    const tree_obj = store.read(allocator, io.io, commit.tree) catch return;
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        checkoutTreeEntry(allocator, io, git_dir, entry, dest) catch continue;
    }
}

fn checkoutTreeEntry(allocator: std.mem.Allocator, io: Io, git_dir: []const u8, entry: object.TreeEntry, dest: []const u8) !void {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const blob_obj = store.read(allocator, io.io, entry.sha) catch return;

    switch (blob_obj) {
        .blob => |b| {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, entry.name });
            defer allocator.free(file_path);

            // Ensure parent directory exists
            if (std.fs.path.dirname(file_path)) |dir| {
                std.Io.Dir.cwd().createDirPath(io.io, dir) catch {};
            }

            var file = std.Io.Dir.cwd().createFile(io.io, file_path, .{}) catch return;
            defer file.close(io.io);
            try std.Io.File.writeStreamingAll(file, io.io, b.content);
        },
        .tree => |t| {
            // Recurse into subdirectory
            const sub_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, entry.name });
            defer allocator.free(sub_dir);
            std.Io.Dir.cwd().createDirPath(io.io, sub_dir) catch {};
            for (t.entries) |sub_entry| {
                checkoutTreeEntry(allocator, io, git_dir, sub_entry, dest) catch continue;
            }
        },
        else => {},
    }
}
