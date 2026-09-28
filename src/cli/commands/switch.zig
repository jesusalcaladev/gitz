const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const checkout = @import("../../core/checkout.zig");
const errors = @import("../errors.zig");

/// gitz switch <branch>          -> change to an existing branch
/// gitz switch -c <branch>       -> create the branch at HEAD and change to it
///
/// Unlike the old implementation (which only rewrote HEAD), this performs a
/// real checkout: the index and working tree end up matching the target
/// commit, and uncommitted work is never silently destroyed.
pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var create = false;
    var name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--create")) {
            create = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try io.eprint("error: unknown option '{s}'\n", .{arg});
            try io.eprint("usage: gitz switch [-c] <branch>\n", .{});
            std.process.exit(1);
        } else if (name == null) {
            name = arg;
        }
    }

    const branch_name = name orelse {
        try io.eprint("usage: gitz switch [-c] <branch>\n", .{});
        std.process.exit(1);
    };

    const refs_manager = refs_mod.Refs.init(git_dir);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);

    if (!refs_mod.Refs.isValidRefName(branch_name)) {
        errors.errorf(io, "'{s}' is not a valid branch name", .{branch_name});
    }
    const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name});
    defer allocator.free(ref_name);

    var target_sha: [20]u8 = undefined;

    if (refs_manager.read(allocator, io.io, ref_name)) |sha| {
        if (create) {
            try io.eprint("error: a branch named '{s}' already exists\n", .{branch_name});
            std.process.exit(1);
        }
        target_sha = sha;
    } else |_| {
        if (!create) {
            try io.eprint("error: switch '{s}' did not match any branch\n", .{branch_name});
            try io.eprint("hint: run 'gitz switch -c {s}' to create it\n", .{branch_name});
            std.process.exit(1);
        }
        // Create the branch from the current HEAD.
        var head_info = refs_manager.head(allocator, io.io) catch null;
        defer if (head_info) |*h| h.deinit(allocator);
        const current = if (head_info) |h| h.sha() else null;
        if (current == null) {
            // HEAD is unborn: git still lets you name the next branch, which is
            // what `gitz switch -c` is for on a fresh repository. HEAD simply
            // points at the new, still-unborn branch.
            try refs_manager.writeSymbolic(allocator, io.io, "HEAD", ref_name);
            try io.print("Switched to a new branch '{s}'\n", .{branch_name});
            return;
        }
        try refs_manager.write(allocator, io.io, ref_name, current.?);
        target_sha = current.?;
    }

    // Refuse to switch if the target commit object is missing.
    if (!store.exists(io.io, target_sha)) {
        try io.eprint("fatal: the target commit of '{s}' does not exist\n", .{branch_name});
        std.process.exit(1);
    }

    // Safety: never clobber uncommitted changes.
    var dirty = checkout.checkSafeToReplace(allocator, git_dir, io.io, store, target_sha) catch null;
    defer if (dirty) |*d| d.deinit(allocator);
    if (dirty) |d| {
        if (d.paths.len > 0) {
            try io.eprint("error: your local changes would be overwritten by switch:\n", .{});
            for (d.paths) |p| try io.eprint("  {s}\n", .{p});
            try io.eprint("hint: commit or discard your changes first\n", .{});
            std.process.exit(1);
        }
    }

    // Real checkout: index + working tree match the target commit.
    checkout.checkoutCommit(allocator, git_dir, io.io, store, target_sha) catch |err| {
        try io.eprint("fatal: checkout failed: {}\n", .{err});
        std.process.exit(1);
    };

    // Point HEAD at the branch.
    try refs_manager.writeSymbolic(allocator, io.io, "HEAD", ref_name);

    // An in-progress merge is no longer relevant after an explicit switch.
    std.Io.Dir.cwd().deleteFile(io.io, try std.fmt.allocPrint(allocator, "{s}/MERGE_HEAD", .{git_dir})) catch {};

    try io.print("Switched to branch '{s}'\n", .{branch_name});
}
