const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const index_mod = @import("../../core/index.zig");

pub const ResetMode = enum { soft, mixed, hard };

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var mode: ResetMode = .mixed;
    var target: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--soft")) {
            mode = .soft;
        } else if (std.mem.eql(u8, arg, "--mixed")) {
            mode = .mixed;
        } else if (std.mem.eql(u8, arg, "--hard")) {
            mode = .hard;
        } else if (std.mem.startsWith(u8, arg, "--mixed=")) {
            mode = .mixed;
            target = arg[8..];
        } else if (std.mem.startsWith(u8, arg, "--soft=")) {
            mode = .soft;
            target = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--hard=")) {
            mode = .hard;
            target = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try io.eprint("error: unknown option '{s}'\n", .{arg});
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (target == null) {
                target = arg;
            }
        }
    }

    if (target == null) {
        try io.print("usage: gitz reset [--soft|--mixed|--hard] [commit]\n", .{});
        return;
    }

    const refs_manager = refs_mod.Refs.init(git_dir);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);

    // Resolve target commit
    const commit_sha = resolveCommit(allocator, io.io, refs_manager, store, target.?) catch {
        try io.eprint("fatal: bad target '{s}'\n", .{target.?});
        return;
    };

    // Get current HEAD
    const current_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
        try io.eprint("fatal: no commits yet\n", .{});
        return;
    };

    // Update HEAD ref
    var head_file = std.Io.Dir.cwd().openFile(io.io,
        try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir}),
        .{},
    ) catch {
        try io.eprint("fatal: could not open HEAD\n", .{});
        return;
    };
    var head_buf: [256]u8 = undefined;
    const n = try head_file.readStreaming(io.io, &.{&head_buf});
    head_file.close(io.io);
    const head_content = std.mem.trim(u8, head_buf[0..n], &[_]u8{ '\n', '\r', ' ' });

    if (std.mem.startsWith(u8, head_content, "ref: ")) {
        const ref_target = head_content[5..];
        try refs_manager.write(allocator, io.io, ref_target, commit_sha);
    } else {
        // Detached HEAD - write SHA directly
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
        defer allocator.free(head_path);
        var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
        defer hf.close(io.io);
        const hex = Sha1.hex(commit_sha);
        var wbuf: [42]u8 = undefined;
        const wline = try std.fmt.bufPrint(&wbuf, "{s}\n", .{&hex});
        try std.Io.File.writeStreamingAll(hf, io.io, wline);
    }

    const hex = Sha1.hex(commit_sha);
    switch (mode) {
        .soft => {
            // Just move HEAD, keep index and working tree
            try io.print("HEAD is now at {s}\n", .{hex[0..7]});
        },
        .mixed => {
            // Move HEAD and reset index to match target commit's tree
            try resetIndex(allocator, git_dir, io.io, store, commit_sha);
            try io.print("HEAD is now at {s}\n", .{hex[0..7]});
        },
        .hard => {
            // Move HEAD, reset index, and overwrite working tree
            try resetIndex(allocator, git_dir, io.io, store, commit_sha);
            try resetWorkingTree(allocator, git_dir, io.io, store, commit_sha);
            try io.print("HEAD is now at {s}\n", .{hex[0..7]});
        },
    }
    _ = current_sha;
}

/// Reset index to match the given commit's tree (recursive)
fn resetIndex(allocator: std.mem.Allocator, git_dir: []const u8, io: std.Io, store: storage_mod.StorageBackend, commit_sha: [20]u8) !void {
    const commit_obj = store.read(allocator, io, commit_sha) catch return;
    const commit = switch (commit_obj) {
        .commit => |c| c,
        else => return,
    };

    var idx = index_mod.Index.init(allocator);
    defer idx.deinit(allocator);

    try flattenTreeToIndex(&idx, store, allocator, io, commit.tree, "");
    try idx.writeToFile(git_dir, allocator, io);
}

fn flattenTreeToIndex(idx: *index_mod.Index, store: storage_mod.StorageBackend, allocator: std.mem.Allocator, io: std.Io, tree_sha: [20]u8, prefix: []const u8) !void {
    const tree_obj = store.read(allocator, io, tree_sha) catch return;
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        if (entry.mode == 0o040000) {
            try flattenTreeToIndex(idx, store, allocator, io, entry.sha, full_path);
            allocator.free(full_path);
        } else {
            try idx.entries.append(allocator, .{
                .sha = entry.sha,
                .mode = entry.mode,
                .name = full_path,
            });
        }
    }
}

/// Reset working tree to match the given commit's tree
fn resetWorkingTree(allocator: std.mem.Allocator, git_dir: []const u8, io: std.Io, store: storage_mod.StorageBackend, commit_sha: [20]u8) !void {
    _ = git_dir;
    const commit_obj = store.read(allocator, io, commit_sha) catch return;
    const commit = switch (commit_obj) {
        .commit => |c| c,
        else => return,
    };

    const tree_obj = store.read(allocator, io, commit.tree) catch return;
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        // Read blob content
        const blob_obj = store.read(allocator, io, entry.sha) catch continue;
        const content = switch (blob_obj) {
            .blob => |b| b.content,
            else => continue,
        };

        // Ensure parent directory exists
        if (std.fs.path.dirname(entry.name)) |dir| {
            std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        }

        // Write file (overwrite)
        var file = std.Io.Dir.cwd().createFile(io, entry.name, .{}) catch continue;
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, content);
    }
}

fn resolveCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    refs_manager: refs_mod.Refs,
    store: storage_mod.StorageBackend,
    ref: []const u8,
) ![20]u8 {
    if (refs_manager.read(allocator, io, ref)) |sha| {
        return sha;
    } else |_| {}

    if (Sha1.fromHex(ref)) |sha| {
        return sha;
    } else |_| {}

    if (std.mem.startsWith(u8, ref, "HEAD~") or std.mem.startsWith(u8, ref, "HEAD^")) {
        const num_str = ref[5..];
        const count = std.fmt.parseInt(usize, num_str, 10) catch 1;

        var current_sha = try refs_manager.read(allocator, io, "HEAD");
        for (0..count) |_| {
            const obj = store.read(allocator, io, current_sha) catch break;
            const commit = switch (obj) {
                .commit => |c| c,
                else => break,
            };
            if (commit.parents.len == 0) break;
            current_sha = commit.parents[0];
        }
        return current_sha;
    }

    return error.InvalidRef;
}
