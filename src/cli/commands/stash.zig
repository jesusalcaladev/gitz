const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const loose = @import("../../core/loose.zig");
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");
const index_mod = @import("../../core/index.zig");

const StashInfo = struct { sha: [20]u8, message: []const u8 };

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    if (args.len == 0) {
        try stashSave(allocator, git_dir, null, io);
        return;
    }

    const subcmd = args[0];

    if (std.mem.eql(u8, subcmd, "push") or std.mem.eql(u8, subcmd, "save")) {
        var message: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-m") and i + 1 < args.len) {
                i += 1;
                message = args[i];
            } else if (!std.mem.startsWith(u8, args[i], "-")) {
                if (message == null) message = args[i];
            }
        }
        try stashSave(allocator, git_dir, message, io);
    } else if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
        try stashList(allocator, git_dir, io);
    } else if (std.mem.eql(u8, subcmd, "pop")) {
        var index: u32 = 0;
        if (args.len > 1) index = std.fmt.parseInt(u32, args[1], 10) catch 0;
        try stashApply(allocator, git_dir, index, true, io);
    } else if (std.mem.eql(u8, subcmd, "apply")) {
        var index: u32 = 0;
        if (args.len > 1) index = std.fmt.parseInt(u32, args[1], 10) catch 0;
        try stashApply(allocator, git_dir, index, false, io);
    } else if (std.mem.eql(u8, subcmd, "drop")) {
        var index: u32 = 0;
        if (args.len > 1) index = std.fmt.parseInt(u32, args[1], 10) catch 0;
        try stashDrop(allocator, git_dir, index, io);
    } else if (std.mem.eql(u8, subcmd, "show")) {
        var show_patch = false;
        var index: u32 = 0;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-p") or std.mem.eql(u8, args[i], "--patch")) {
                show_patch = true;
            } else if (!std.mem.startsWith(u8, args[i], "-")) {
                index = std.fmt.parseInt(u32, args[i], 10) catch 0;
            }
        }
        try stashShow(allocator, git_dir, index, show_patch, io);
    } else if (std.mem.eql(u8, subcmd, "clear")) {
        try stashClear(allocator, git_dir, io);
    } else {
        try io.eprint("usage: gitz stash [push|save|list|pop|apply|drop|show|clear]\n", .{});
    }
}

/// Save working tree state as a commit object
fn stashSave(allocator: std.mem.Allocator, git_dir: []const u8, message: ?[]const u8, io: Io) !void {
    const store = loose.LooseStore.init(git_dir);
    const refs_manager = refs_mod.Refs.init(git_dir);

    // Collect all working tree files
    var tree_entries = std.ArrayList(object.TreeEntry){ .items = &.{}, .capacity = 0 };
    defer tree_entries.deinit(allocator);

    try collectWorkingFiles(allocator, git_dir, io.io, &tree_entries);

    if (tree_entries.items.len == 0) {
        try io.print("No local changes to save\n", .{});
        return;
    }

    // Create tree object from working files
    const tree = object.Tree{ .entries = try tree_entries.toOwnedSlice(allocator) };
    const tree_sha = try store.write(allocator, io.io, object.GitObject{ .tree = tree });

    // Get current HEAD as parent
    var parents: [][20]u8 = &.{};
    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch null;
    if (head_sha) |sha| {
        var all_zero = true;
        for (sha) |b| {
            if (b != 0) { all_zero = false; break; }
        }
        if (!all_zero) {
            parents = try allocator.alloc([20]u8, 1);
            parents[0] = sha;
        }
    }

    // Create stash commit
    const now_ts = std.Io.Timestamp.now(io.io, .real);
    const now: i64 = @intCast(@divTrunc(now_ts.nanoseconds, std.time.ns_per_s));

    const stash_msg = message orelse "WIP on (no branch)";
    const commit = object.Commit{
        .tree = tree_sha,
        .parents = parents,
        .author = .{ .name = "GitZ User", .email = "user@gitz.dev", .timestamp = now, .timezone = "+0000" },
        .committer = .{ .name = "GitZ User", .email = "user@gitz.dev", .timestamp = now, .timezone = "+0000" },
        .message = stash_msg,
    };

    const stash_sha = try store.write(allocator, io.io, object.GitObject{ .commit = commit });

    // Append to refs/stash chain
    const stash_path = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_dir});
    defer allocator.free(stash_path);

    // Read existing stash chain
    const existing = std.Io.Dir.cwd().readFileAlloc(io.io, stash_path, allocator, .unlimited) catch null;
    defer if (existing) |e| allocator.free(e);

    var file = try std.Io.Dir.cwd().createFile(io.io, stash_path, .{});
    defer file.close(io.io);

    // Write new stash SHA + message
    var line_buf: [256]u8 = undefined;
    const hex = Sha1.hex(stash_sha);
    const line = try std.fmt.bufPrint(&line_buf, "{s} {s}\n", .{ &hex, stash_msg });
    try std.Io.File.writeStreamingAll(file, io.io, line);

    // Append old chain if any
    if (existing) |content| {
        try std.Io.File.writeStreamingAll(file, io.io, content);
    }

    if (parents.len > 0) allocator.free(parents);
    const hex_short = Sha1.hex(stash_sha);
    try io.print("Saved working directory state on HEAD ({s})\n", .{hex_short[0..7]});
}

/// List stash entries
fn stashList(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) !void {
    const stash_path = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_dir});
    defer allocator.free(stash_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io.io, stash_path, allocator, .unlimited) catch {
        try io.print("No stash entries.\n", .{});
        return;
    };
    defer allocator.free(content);

    var index: u32 = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, content, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len < 41) continue;
        const hex = line[0..40];
        const msg = if (line.len > 41) line[41..] else "(no message)";
        try io.print("stash@{{{d}}}: {s} ({s})\n", .{ index, msg, hex[0..7] });
        index += 1;
    }
}

/// Apply stash to working tree
fn stashApply(allocator: std.mem.Allocator, git_dir: []const u8, index: u32, remove_after: bool, io: Io) !void {
    const stash_path = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_dir});
    defer allocator.free(stash_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io.io, stash_path, allocator, .unlimited) catch {
        try io.eprint("No stash entries found.\n", .{});
        return;
    };
    defer allocator.free(content);

    // Parse stash entries
    var entries = std.ArrayList(StashInfo){ .items = &.{}, .capacity = 0 };
    defer {
        for (entries.items) |e| allocator.free(e.message);
        entries.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, content, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len < 41) continue;
        const sha = Sha1.fromHex(line[0..40]) catch continue;
        const msg = try allocator.dupe(u8, if (line.len > 41) line[41..] else "");
        try entries.append(allocator, .{ .sha = sha, .message = msg });
    }

    if (index >= entries.items.len) {
        try io.eprint("stash@{{{d}}}: entry not found\n", .{index});
        return;
    }

    // Read the stash commit
    const store = loose.LooseStore.init(git_dir);
    const stash_sha = entries.items[index].sha;

    const obj = store.read(allocator, io.io, stash_sha) catch {
        try io.eprint("fatal: stash object not found\n", .{});
        return;
    };
    const commit = switch (obj) {
        .commit => |c| c,
        else => {
            try io.eprint("fatal: stash object is not a commit\n", .{});
            return;
        },
    };

    // Read the tree
    const tree_obj = store.read(allocator, io.io, commit.tree) catch {
        try io.eprint("fatal: stash tree not found\n", .{});
        return;
    };
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => {
            try io.eprint("fatal: stash object is not a tree\n", .{});
            return;
        },
    };

    // Write each file from the stash tree to working directory
    for (tree.entries) |entry| {
        const blob_obj = store.read(allocator, io.io, entry.sha) catch continue;
        const content_data = switch (blob_obj) {
            .blob => |b| b.content,
            else => continue,
        };

        // Ensure parent directories exist
        if (std.fs.path.dirname(entry.name)) |dir| {
            std.Io.Dir.cwd().createDirPath(io.io, dir) catch {};
        }

        // Write file
        var file = std.Io.Dir.cwd().createFile(io.io, entry.name, .{}) catch continue;
        defer file.close(io.io);
        try std.Io.File.writeStreamingAll(file, io.io, content_data);
        try io.print("Applied: {s}\n", .{entry.name});
    }

    // Remove from stash if pop
    if (remove_after) {
        try stashDrop(allocator, git_dir, index, io);
    }
}

/// Drop a stash entry
fn stashDrop(allocator: std.mem.Allocator, git_dir: []const u8, index: u32, io: Io) !void {
    const stash_path = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_dir});
    defer allocator.free(stash_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io.io, stash_path, allocator, .unlimited) catch {
        try io.eprint("No stash entries found.\n", .{});
        return;
    };
    defer allocator.free(content);

    // Collect entries, skip the one at index
    var file = try std.Io.Dir.cwd().createFile(io.io, stash_path, .{});
    defer file.close(io.io);

    var current: u32 = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, content, "\n"), '\n');
    while (lines.next()) |line| {
        if (current != index) {
            var wbuf: [256]u8 = undefined;
            const wline = try std.fmt.bufPrint(&wbuf, "{s}\n", .{line});
            try std.Io.File.writeStreamingAll(file, io.io, wline);
        }
        current += 1;
    }

    try io.print("Dropped stash@{{{d}}}\n", .{index});
}

/// Show stash info or diff
fn stashShow(allocator: std.mem.Allocator, git_dir: []const u8, index: u32, show_patch: bool, io: Io) !void {
    const stash_path = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_dir});
    defer allocator.free(stash_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io.io, stash_path, allocator, .unlimited) catch {
        try io.print("No stash entries.\n", .{});
        return;
    };
    defer allocator.free(content);

    var current: u32 = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, content, "\n"), '\n');
    while (lines.next()) |line| {
        if (current == index and line.len >= 41) {
            if (show_patch) {
                try io.print("stash@{{{d}}}:\n", .{index});
                try io.print("diff --git a/file b/file\n", .{});
                try io.print("(patch display not yet implemented)\n", .{});
            } else {
                const hex = line[0..40];
                const msg = if (line.len > 41) line[41..] else "";
                try io.print("stash@{{{d}}}: {s} ({s})\n", .{ index, msg, hex[0..7] });
            }
            return;
        }
        current += 1;
    }
    try io.eprint("stash@{{{d}}}: entry not found\n", .{index});
}

/// Clear all stash entries
fn stashClear(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) !void {
    const stash_path = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_dir});
    defer allocator.free(stash_path);
    std.Io.Dir.cwd().deleteFile(io.io, stash_path) catch {};
    try io.print("Stash cleared.\n", .{});
}

/// Collect working tree files as tree entries
fn collectWorkingFiles(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: std.Io,
    entries: *std.ArrayList(object.TreeEntry),
) !void {

    var dirs_to_visit: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
    defer {
        for (dirs_to_visit.items) |d| allocator.free(d);
        dirs_to_visit.deinit(allocator);
    }

    try dirs_to_visit.append(allocator, try allocator.dupe(u8, "."));

    while (dirs_to_visit.items.len > 0) {
        const current = dirs_to_visit.pop() orelse break;
        defer allocator.free(current);

        const current_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{current}, 0);
        defer allocator.free(current_z);

        const fd = std.posix.openat(std.posix.AT.FDCWD, current_z, std.posix.O{ .ACCMODE = .RDONLY }, 0) catch continue;
        defer { _ = std.os.linux.close(@intCast(fd)); }

        var buf: [4096]u8 align(@alignOf(usize)) = undefined;
        while (true) {
            const rc = std.os.linux.getdents64(@intCast(fd), &buf, buf.len);
            const n: usize = if (rc > 0) @intCast(rc) else break;
            if (n == 0) break;

            var pos: usize = 0;
            while (pos < n) {
                const direntry: *align(1) const std.os.linux.dirent64 = @ptrCast(&buf[pos]);
                const name: []const u8 = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&direntry.name)), 0);

                const skip = (name.len == 1 and name[0] == '.') or
                    (name.len == 2 and name[0] == '.' and name[1] == '.') or
                    (name.len == 5 and std.mem.eql(u8, name, ".gitz"));
                if (!skip) {
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current, name });
                    const is_dir = blk: {
                        const fp_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{full_path}, 0);
                        defer allocator.free(fp_z);
                        const sub_fd = std.posix.openat(std.posix.AT.FDCWD, fp_z, std.posix.O{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch break :blk false;
                        _ = std.os.linux.close(@intCast(sub_fd));
                        break :blk true;
                    };

                    if (is_dir) {
                        try dirs_to_visit.append(allocator, full_path);
                    } else {
                        // Read file and create blob
                        const file_content = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .unlimited) catch {
                            allocator.free(full_path);
                            pos += direntry.reclen;
                            continue;
                        };
                        defer allocator.free(file_content);

                        // Store as loose blob object
                        const store = loose.LooseStore.init(git_dir);
                        const blob = object.GitObject{ .blob = .{ .content = file_content } };
                        const sha = try store.write(allocator, io, blob);

                        try entries.append(allocator, .{
                            .mode = 0o100644,
                            .name = full_path,
                            .sha = sha,
                        });
                    }
                }
                pos += direntry.reclen;
            }
        }
    }
}
