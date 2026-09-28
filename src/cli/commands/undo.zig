const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");
const checkout = @import("../../core/checkout.zig");
const index_mod = @import("../../core/index.zig");
const errors = @import("../errors.zig");

const Mode = enum { soft, mixed, hard };

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    // `--hard` is the default: the commit being undone is one the user has
    // already decided to abandon, and leaving its changes staged behind made
    // `gitz undo` look like it had done nothing.
    var mode: Mode = .hard;
    var count: usize = 1;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--soft")) {
            mode = .soft;
        } else if (std.mem.eql(u8, arg, "--hard")) {
            mode = .hard;
        } else if (std.mem.eql(u8, arg, "--mixed")) {
            mode = .mixed;
        } else if (std.mem.startsWith(u8, arg, "HEAD~")) {
            count = std.fmt.parseInt(usize, arg[5..], 10) catch 1;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            errors.errorf(io, "unknown option '{s}'", .{arg});
        } else {
            count = std.fmt.parseInt(usize, arg, 10) catch 1;
        }
    }

    const refs_manager = refs_mod.Refs.init(git_dir);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);

    const current_sha = refs_manager.read(allocator, io.io, "HEAD") catch
        errors.fatal(io, "no commits yet", .{});

    var target_sha = current_sha;
    for (0..count) |_| {
        const obj = store.read(allocator, io.io, target_sha) catch
            errors.fatal(io, "cannot read commit", .{});
        var commit_obj = obj;
        const commit = switch (commit_obj) {
            .commit => |c| c,
            else => {
                commit_obj.deinit(allocator);
                errors.fatal(io, "HEAD is not a commit", .{});
            },
        };
        if (commit.parents.len == 0) {
            commit_obj.deinit(allocator);
            errors.errorf(io, "cannot undo the initial commit", .{});
        }
        target_sha = commit.parents[0];
        commit_obj.deinit(allocator);
    }

    const target_obj = store.read(allocator, io.io, target_sha) catch
        errors.fatal(io, "cannot read target commit", .{});
    var target_obj_mut = target_obj;
    defer target_obj_mut.deinit(allocator);
    const target_commit = switch (target_obj_mut) {
        .commit => |c| c,
        else => errors.fatal(io, "target is not a commit", .{}),
    };

    // The index and the working tree move *before* the ref does. `checkoutCommit`
    // compares the target against HEAD to decide which local edits to carry
    // over, so moving the ref first made every undone file look unchanged and
    // left the previous content on disk.
    //
    // Only the ref used to move at all: the undone commit's changes stayed in
    // the working tree and `gitz undo --hard` left the repository looking exactly
    // as it did before, with nothing in the output to say the commit was undone.
    switch (mode) {
        .soft => {},
        .mixed => {
            // The index follows the commit; the working tree is left alone, so the
            // undone changes show up as unstaged modifications.
            var idx = index_mod.Index.init(allocator);
            defer idx.deinit(allocator);
            try collectCommitFiles(allocator, io, store, target_sha, &idx);
            try idx.writeToFile(git_dir, allocator, io.io);
        },
        .hard => {
            checkout.checkoutCommit(allocator, git_dir, io.io, store, target_sha) catch
                errors.fatal(io, "could not restore the working tree", .{});
        },
    }

    moveHead(allocator, git_dir, io, refs_manager, current_sha, target_sha) catch
        errors.fatal(io, "could not update HEAD", .{});

    const hex_new = Sha1.hex(target_sha);
    try io.print("HEAD is now at {s} {s}\n", .{ hex_new[0..7], target_commit.message });
}

fn moveHead(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: Io,
    refs_manager: refs_mod.Refs,
    current_sha: [20]u8,
    target_sha: [20]u8,
) !void {
    _ = current_sha;

    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);

    var head_file = try std.Io.Dir.cwd().openFile(io.io, head_path, .{});
    defer head_file.close(io.io);

    var head_buf: [256]u8 = undefined;
    const n = try head_file.readStreaming(io.io, &.{&head_buf});
    const head_content = std.mem.trim(u8, head_buf[0..n], &[_]u8{ '\n', '\r', ' ' });

    if (std.mem.startsWith(u8, head_content, "ref: ")) {
        try refs_manager.write(allocator, io.io, head_content[5..], target_sha);
        return;
    }

    // Detached HEAD: the SHA in the file is replaced.
    const hex = Sha1.hex(target_sha);
    var wbuf: [42]u8 = undefined;
    const line = try std.fmt.bufPrint(&wbuf, "{s}\n", .{&hex});
    try io.writeFile(head_path, line);
}

/// Stage every file of a commit's tree at its recorded mode.
fn collectCommitFiles(
    allocator: std.mem.Allocator,
    io: Io,
    store: storage_mod.StorageBackend,
    commit_sha: [20]u8,
    idx: *index_mod.Index,
) !void {
    var files = checkout.FileMap.init(allocator);
    defer checkout.freeMap(allocator, &files);

    const obj = store.read(allocator, io.io, commit_sha) catch return;
    var commit_obj = obj;
    defer commit_obj.deinit(allocator);
    const commit = switch (commit_obj) {
        .commit => |c| c,
        else => return,
    };

    try checkout.flattenTree(allocator, io.io, store, commit.tree, "", &files);

    var it = files.iterator();
    while (it.next()) |entry| {
        try idx.add(allocator, entry.key_ptr.*, entry.value_ptr.sha, .{ .mode = entry.value_ptr.mode });
    }
}
