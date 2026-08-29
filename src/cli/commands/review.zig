const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");
const diff_mod = @import("../../core/diff.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var base_ref: ?[]const u8 = null;
    var head_ref: ?[]const u8 = null;
    var show_stats = true;
    var show_diff = true;
    var summary_only = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--stat")) {
            show_stats = true;
            show_diff = false;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary_only = true;
        } else if (std.mem.eql(u8, arg, "--no-stat")) {
            show_stats = false;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (base_ref == null) {
                base_ref = arg;
            } else if (head_ref == null) {
                head_ref = arg;
            }
        }
    }

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const refs_manager = refs_mod.Refs.init(git_dir);

    // Resolve base (default: main/master)
    const base_sha = if (base_ref) |br|
        resolveRef(allocator, io.io, refs_manager, store, br) catch {
            try io.eprint("fatal: reference not found: {s}\n", .{br});
            return;
        }
    else
        resolveDefaultBranch(allocator, io.io, refs_manager) catch {
            try io.eprint("fatal: no default branch found (specify base explicitly)\n", .{});
            return;
        };

    // Resolve head (default: HEAD)
    const head_sha = if (head_ref) |hr|
        resolveRef(allocator, io.io, refs_manager, store, hr) catch {
            try io.eprint("fatal: reference not found: {s}\n", .{hr});
            return;
        }
    else
        refs_manager.read(allocator, io.io, "HEAD") catch {
            try io.eprint("fatal: no commits yet\n", .{});
            return;
        };

    if (std.mem.eql(u8, &base_sha, &head_sha)) {
        try io.print("Already up to date.\n", .{});
        return;
    }

    // Get base and head objects
    const base_obj = store.read(allocator, io.io, base_sha) catch {
        try io.eprint("fatal: bad object {s}\n", .{Sha1.hex(base_sha)[0..7]});
        return;
    };
    const base_commit = switch (base_obj) {
        .commit => |c| c,
        else => {
            try io.eprint("fatal: object is not a commit\n", .{});
            return;
        },
    };

    const head_obj = store.read(allocator, io.io, head_sha) catch {
        try io.eprint("fatal: bad object {s}\n", .{Sha1.hex(head_sha)[0..7]});
        return;
    };
    const head_commit = switch (head_obj) {
        .commit => |c| c,
        else => {
            try io.eprint("fatal: object is not a commit\n", .{});
            return;
        },
    };

    // Count commits between base and head
    var commit_count: usize = 0;
    var authors = std.StringHashMap(u32).init(allocator);
    defer authors.deinit();

    var cur = head_sha;
    while (!std.mem.eql(u8, &cur, &base_sha)) {
        const obj = store.read(allocator, io.io, cur) catch break;
        const c = switch (obj) {
            .commit => |cc| cc,
            else => break,
        };
        commit_count += 1;

        // Track unique authors
        const gop = try authors.getOrPut(c.author.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;

        if (c.parents.len > 0) {
            cur = c.parents[0];
        } else break;
    }

    // Header
    const base_hex = Sha1.hex(base_sha);
    const head_hex = Sha1.hex(head_sha);
    try io.print("\x1b[1;36m═══════════════════════════════════════════════\x1b[0m\n", .{});
    try io.print("\x1b[1;36m  Code Review: {s}..{s}\x1b[0m\n", .{ base_hex[0..7], head_hex[0..7] });
    try io.print("\x1b[1;36m═══════════════════════════════════════════════\x1b[0m\n\n", .{});

    // Summary
    try io.print("\x1b[1mSummary:\x1b[0m\n", .{});
    try io.print("  Commits:  \x1b[1;33m{d}\x1b[0m\n", .{commit_count});

    var auth_iter = authors.iterator();
    var first = true;
    while (auth_iter.next()) |entry| {
        if (first) {
            try io.print("  Authors:  ", .{});
            first = false;
        } else {
            try io.print("            ", .{});
        }
        try io.print("{s} ({d})\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    // Get tree objects for diff
    const base_tree = getTree(allocator, io.io, store, base_commit);
    const head_tree = getTree(allocator, io.io, store, head_commit);

    if (base_tree == null or head_tree == null) {
        try io.print("\n  \x1b[31mCannot compute diff (missing tree objects)\x1b[0m\n", .{});
        return;
    }

    // Compare trees to find changed files
    var added_files: u32 = 0;
    var modified_files: u32 = 0;
    var deleted_files: u32 = 0;
    var total_additions: u32 = 0;
    var total_deletions: u32 = 0;

    var files_changed = std.ArrayList(ChangedFile){ .items = &.{}, .capacity = 0 };
    defer {
        for (files_changed.items) |f| allocator.free(f.name);
        files_changed.deinit(allocator);
    }

    // Find files in head not in base (added or modified)
    for (head_tree.?.entries) |entry| {
        if (entry.mode == 0o040000) continue;

        var found_in_base = false;
        for (base_tree.?.entries) |base_entry| {
            if (std.mem.eql(u8, entry.name, base_entry.name)) {
                found_in_base = true;
                if (!std.mem.eql(u8, &entry.sha, &base_entry.sha)) {
                    modified_files += 1;
                    const stats = diffFileStats(allocator, io.io, store, base_entry.sha, entry.sha);
                    total_additions += stats.added;
                    total_deletions += stats.deleted;
                    try files_changed.append(allocator, .{
                        .name = try allocator.dupe(u8, entry.name),
                        .status = .modified,
                        .added = stats.added,
                        .deleted = stats.deleted,
                    });
                }
                break;
            }
        }
        if (!found_in_base) {
            added_files += 1;
            const blob_obj = store.read(allocator, io.io, entry.sha) catch continue;
            const line_count = switch (blob_obj) {
                .blob => |b| countLines(b.content),
                else => 0,
            };
            total_additions += line_count;
            try files_changed.append(allocator, .{
                .name = try allocator.dupe(u8, entry.name),
                .status = .added,
                .added = line_count,
                .deleted = 0,
            });
        }
    }

    // Find files in base not in head (deleted)
    for (base_tree.?.entries) |entry| {
        if (entry.mode == 0o040000) continue;
        var found_in_head = false;
        for (head_tree.?.entries) |head_entry| {
            if (std.mem.eql(u8, entry.name, head_entry.name)) {
                found_in_head = true;
                break;
            }
        }
        if (!found_in_head) {
            deleted_files += 1;
            const blob_obj = store.read(allocator, io.io, entry.sha) catch continue;
            const line_count = switch (blob_obj) {
                .blob => |b| countLines(b.content),
                else => 0,
            };
            total_deletions += line_count;
            try files_changed.append(allocator, .{
                .name = try allocator.dupe(u8, entry.name),
                .status = .deleted,
                .added = 0,
                .deleted = line_count,
            });
        }
    }

    // File stats
    try io.print("\n\x1b[1mFiles Changed:\x1b[0m\n", .{});
    try io.print("  \x1b[32m+{d}\x1b[0m added  \x1b[33m~{d}\x1b[0m modified  \x1b[31m-{d}\x1b[0m deleted\n\n", .{
        added_files,
        modified_files,
        deleted_files,
    });

    if (show_stats) {
        try io.print("\x1b[1mFile Summary:\x1b[0m\n", .{});
        for (files_changed.items) |f| {
            const icon: []const u8 = switch (f.status) {
                .added => "+",
                .modified => "~",
                .deleted => "-",
            };
            const color: []const u8 = switch (f.status) {
                .added => "\x1b[32m",
                .modified => "\x1b[33m",
                .deleted => "\x1b[31m",
            };
            if (f.added + f.deleted > 0) {
                try io.print("  {s}{s} {s}\x1b[0m \x1b[2m(+{d} -{d})\x1b[0m\n", .{
                    color,
                    icon,
                    f.name,
                    f.added,
                    f.deleted,
                });
            } else {
                try io.print("  {s}{s} {s}\x1b[0m\n", .{ color, icon, f.name });
            }
        }
        try io.print("\n", .{});
    }

    // Show detailed diff if requested
    if (show_diff and !summary_only) {
        try io.print("\x1b[1mDiff:\x1b[0m\n\n", .{});
        for (files_changed.items) |f| {
            try printFileDiff(allocator, io, store, f, base_tree.?, head_tree.?, base_sha, head_sha);
        }
    }

    // Line count summary
    try io.print("\x1b[1mTotal:\x1b[0m \x1b[32m+{d}\x1b[0m \x1b[31m-{d}\x1b[0m lines\n", .{ total_additions, total_deletions });
    try io.print("\x1b[1;36m═══════════════════════════════════════════════\x1b[0m\n", .{});
}

const FileStatus = enum { added, modified, deleted };

const ChangedFile = struct {
    name: []const u8,
    status: FileStatus,
    added: u32,
    deleted: u32,
};

fn getTree(allocator: std.mem.Allocator, io: std.Io, store: storage_mod.StorageBackend, commit: object.Commit) ?object.Tree {
    const tree_obj = store.read(allocator, io, commit.tree) catch return null;
    return switch (tree_obj) {
        .tree => |t| t,
        else => null,
    };
}

fn countLines(content: []const u8) u32 {
    if (content.len == 0) return 0;
    var count: u32 = 1;
    for (content) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

fn diffFileStats(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage_mod.StorageBackend,
    old_sha: [20]u8,
    new_sha: [20]u8,
) struct { added: u32, deleted: u32 } {
    const old_obj = store.read(allocator, io, old_sha) catch return .{ .added = 0, .deleted = 0 };
    const new_obj = store.read(allocator, io, new_sha) catch return .{ .added = 0, .deleted = 0 };

    const old_blob = switch (old_obj) {
        .blob => |b| b,
        else => return .{ .added = 0, .deleted = 0 },
    };
    const new_blob = switch (new_obj) {
        .blob => |b| b,
        else => return .{ .added = 0, .deleted = 0 },
    };

    // Split into lines
    var old_lines = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer old_lines.deinit(allocator);
    var old_iter = std.mem.splitScalar(u8, old_blob.content, '\n');
    while (old_iter.next()) |line| {
        old_lines.append(allocator, line) catch return .{ .added = 0, .deleted = 0 };
    }

    var new_lines = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer new_lines.deinit(allocator);
    var new_iter = std.mem.splitScalar(u8, new_blob.content, '\n');
    while (new_iter.next()) |line| {
        new_lines.append(allocator, line) catch return .{ .added = 0, .deleted = 0 };
    }

    const d = diff_mod.myersDiff(allocator, old_lines.items, new_lines.items) catch return .{ .added = 0, .deleted = 0 };
    defer d.deinit(allocator);

    var added: u32 = 0;
    var deleted: u32 = 0;
    for (d.hunks) |hunk| {
        for (hunk.lines) |line| {
            switch (line.type) {
                .added => added += 1,
                .deleted => deleted += 1,
                else => {},
            }
        }
    }
    return .{ .added = added, .deleted = deleted };
}

fn printFileDiff(
    allocator: std.mem.Allocator,
    io: Io,
    store: storage_mod.StorageBackend,
    file: ChangedFile,
    base_tree: object.Tree,
    head_tree: object.Tree,
    base_sha: [20]u8,
    head_sha: [20]u8,
) !void {
    _ = base_sha;
    _ = head_sha;

    const old_sha_opt: ?[20]u8 = switch (file.status) {
        .added => null,
        .modified => findEntrySha(base_tree, file.name),
        .deleted => findEntrySha(base_tree, file.name),
    };
    const new_sha_opt: ?[20]u8 = switch (file.status) {
        .added => findEntrySha(head_tree, file.name),
        .modified => findEntrySha(head_tree, file.name),
        .deleted => null,
    };

    const old_name = if (old_sha_opt) |_|
        try std.fmt.allocPrint(allocator, "a/{s}", .{file.name})
    else
        try std.fmt.allocPrint(allocator, "/dev/null", .{});
    defer if (old_sha_opt != null) allocator.free(old_name);

    const new_name = if (new_sha_opt) |_|
        try std.fmt.allocPrint(allocator, "b/{s}", .{file.name})
    else
        try std.fmt.allocPrint(allocator, "/dev/null", .{});
    defer if (new_sha_opt != null) allocator.free(new_name);

    try io.print("\x1b[1mdiff --git {s} {s}\x1b[0m\n", .{ old_name, new_name });

    if (old_sha_opt == null) {
        try io.print("\x1b[32mnew file mode 100644\x1b[0m\n", .{});
    } else if (new_sha_opt == null) {
        try io.print("\x1b[31mdeleted file mode 100644\x1b[0m\n", .{});
    }

    if (old_sha_opt != null and new_sha_opt != null) {
        // Get blobs and diff them
        const old_obj = store.read(allocator, io.io, old_sha_opt.?) catch return;
        const new_obj = store.read(allocator, io.io, new_sha_opt.?) catch return;

        const old_blob = switch (old_obj) {
            .blob => |b| b,
            else => return,
        };
        const new_blob = switch (new_obj) {
            .blob => |b| b,
            else => return,
        };

        var old_lines = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
        defer old_lines.deinit(allocator);
        var old_iter = std.mem.splitScalar(u8, old_blob.content, '\n');
        while (old_iter.next()) |line| try old_lines.append(allocator, line);

        var new_lines = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
        defer new_lines.deinit(allocator);
        var new_iter = std.mem.splitScalar(u8, new_blob.content, '\n');
        while (new_iter.next()) |line| try new_lines.append(allocator, line);

        const d = diff_mod.myersDiff(allocator, old_lines.items, new_lines.items) catch return;
        defer d.deinit(allocator);

        for (d.hunks) |hunk| {
            try io.print("\x1b[36m@@ -{d},+{d} @@\x1b[0m\n", .{ hunk.old_start, hunk.new_start });
            for (hunk.lines) |line| {
                switch (line.type) {
                    .added => try io.print("\x1b[32m+{s}\x1b[0m\n", .{line.content}),
                    .deleted => try io.print("\x1b[31m-{s}\x1b[0m\n", .{line.content}),
                    .context => try io.print(" {s}\n", .{line.content}),
                }
            }
        }
    } else if (new_sha_opt) |ns| {
        // New file - show all lines as added
        const obj = store.read(allocator, io.io, ns) catch return;
        const blob = switch (obj) {
            .blob => |b| b,
            else => return,
        };
        var lines = std.mem.splitScalar(u8, blob.content, '\n');
        while (lines.next()) |line| {
            try io.print("\x1b[32m+{s}\x1b[0m\n", .{line});
        }
    } else if (old_sha_opt) |os| {
        // Deleted file - show all lines as deleted
        const obj = store.read(allocator, io.io, os) catch return;
        const blob = switch (obj) {
            .blob => |b| b,
            else => return,
        };
        var lines = std.mem.splitScalar(u8, blob.content, '\n');
        while (lines.next()) |line| {
            try io.print("\x1b[31m-{s}\x1b[0m\n", .{line});
        }
    }
    try io.print("\n", .{});
}

fn findEntrySha(tree: object.Tree, name: []const u8) ?[20]u8 {
    for (tree.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.sha;
    }
    return null;
}

fn resolveRef(
    allocator: std.mem.Allocator,
    io: std.Io,
    refs_manager: refs_mod.Refs,
    store: storage_mod.StorageBackend,
    ref: []const u8,
) ![20]u8 {
    // Try as branch
    const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{ref});
    defer allocator.free(branch_ref);
    if (refs_manager.read(allocator, io, branch_ref)) |sha| return sha else |_| {}

    // Try as tag
    const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{ref});
    defer allocator.free(tag_ref);
    if (refs_manager.read(allocator, io, tag_ref)) |sha| return sha else |_| {}

    // Try as direct ref
    if (refs_manager.read(allocator, io, ref)) |sha| return sha else |_| {}

    // Try as SHA
    if (Sha1.fromHex(ref)) |sha| return sha else |_| {}

    // Try HEAD~N
    if (std.mem.startsWith(u8, ref, "HEAD~")) {
        const count = std.fmt.parseInt(usize, ref[5..], 10) catch 1;
        var cur = try refs_manager.read(allocator, io, "HEAD");
        for (0..count) |_| {
            const obj = store.read(allocator, io, cur) catch break;
            const c = switch (obj) {
                .commit => |cc| cc,
                else => break,
            };
            if (c.parents.len == 0) break;
            cur = c.parents[0];
        }
        return cur;
    }

    return error.InvalidRef;
}

fn resolveDefaultBranch(
    allocator: std.mem.Allocator,
    io: std.Io,
    refs_manager: refs_mod.Refs,
) ![20]u8 {
    // Try main, then master
    for ([2][]const u8{ "main", "master" }) |branch| {
        const ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
        defer allocator.free(ref);
        if (refs_manager.read(allocator, io, ref)) |sha| return sha else |_| {}
    }
    return error.InvalidRef;
}
