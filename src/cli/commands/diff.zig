const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const refs = @import("../../core/refs.zig");
const index_mod = @import("../../core/index.zig");
const diff_mod = @import("../../core/diff.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var staged = false;
    var no_color = false;
    var branch_a: ?[]const u8 = null;
    var branch_b: ?[]const u8 = null;
    var range_sep = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--staged") or std.mem.eql(u8, arg, "--cached")) {
            staged = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            no_color = true;
        } else if (std.mem.eql(u8, arg, "..")) {
            range_sep = true;
        } else if (std.mem.eql(u8, arg, "...")) {
            range_sep = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (range_sep) {
                branch_b = arg;
                range_sep = false;
            } else if (branch_a == null) {
                // Check if it contains .. (e.g., "main..feature")
                if (std.mem.indexOf(u8, arg, "..")) |dotdot_pos| {
                    branch_a = arg[0..dotdot_pos];
                    branch_b = arg[dotdot_pos + 2 ..];
                } else {
                    branch_a = arg;
                }
            }
        }
    }

    // Branch diff mode
    if (branch_a != null or branch_b != null) {
        try diffBranches(allocator, git_dir, io, no_color, branch_a, branch_b);
        return;
    }

    if (staged) {
        try diffStaged(allocator, git_dir, io, no_color);
        return;
    }

    try diffWorking(allocator, git_dir, io, no_color);
}

fn diffStaged(allocator: std.mem.Allocator, git_dir: []const u8, io: Io, no_color: bool) !void {
    var idx = index_mod.Index.readFromFile(allocator, git_dir, io.io) catch {
        try io.print("No changes\n", .{});
        return;
    };
    defer idx.deinit(allocator);

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const refs_manager = refs.Refs.init(git_dir);

    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
        try io.print("No changes (no commits yet)\n", .{});
        return;
    };

    // Get HEAD tree
    var head_entries = std.StringHashMap([20]u8).init(allocator);
    defer {
        var iter = head_entries.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        head_entries.deinit();
    }

    const commit_obj = store.read(allocator, io.io, head_sha) catch return;
    const commit = switch (commit_obj) {
        .commit => |c| c,
        else => return,
    };
    const tree_obj = store.read(allocator, io.io, commit.tree) catch return;
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        const owned_name = try allocator.dupe(u8, entry.name);
        try head_entries.put(owned_name, entry.sha);
    }

    var has_diff = false;
    for (idx.entries.items) |index_entry| {
        const clean_name = if (std.mem.startsWith(u8, index_entry.name, "./"))
            index_entry.name[2..]
        else
            index_entry.name;

        if (head_entries.get(clean_name)) |old_sha| {
            // Modified file - compare old vs new
            if (std.mem.eql(u8, &old_sha, &index_entry.sha)) continue;

            const old_obj = store.read(allocator, io.io, old_sha) catch continue;
            const old_content = switch (old_obj) {
                .blob => |b| b.content,
                else => continue,
            };

            const new_obj = store.read(allocator, io.io, index_entry.sha) catch continue;
            const new_content = switch (new_obj) {
                .blob => |b| b.content,
                else => continue,
            };

            has_diff = true;
            try printDiff(allocator, io, clean_name, old_content, new_content, no_color);
        } else {
            // New file
            const obj = store.read(allocator, io.io, index_entry.sha) catch continue;
            const content = switch (obj) {
                .blob => |b| b.content,
                else => continue,
            };

            has_diff = true;
            try io.print("diff --git a/{s} b/{s}\n", .{ clean_name, clean_name });
            try io.print("new file mode 100644\n", .{});
            try io.print("--- /dev/null\n", .{});
            try io.print("+++ b/{s}\n", .{clean_name});

            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                if (no_color) {
                    try io.print("+{s}\n", .{line});
                } else {
                    try io.print("\x1b[32m+{s}\x1b[0m\n", .{line});
                }
            }
        }
    }

    // Check for deleted files (in HEAD but not in index)
    var ht_iter = head_entries.iterator();
    while (ht_iter.next()) |entry| {
        if (idx.get(entry.key_ptr.*) == null) {
            has_diff = true;
            const old_obj = store.read(allocator, io.io, entry.value_ptr.*) catch continue;
            const old_content = switch (old_obj) {
                .blob => |b| b.content,
                else => continue,
            };
            try io.print("diff --git a/{s} b/{s}\n", .{ entry.key_ptr.*, entry.key_ptr.* });
            try io.print("deleted file mode 100644\n", .{});
            try io.print("--- a/{s}\n", .{entry.key_ptr.*});
            try io.print("+++ /dev/null\n", .{});

            var lines = std.mem.splitScalar(u8, old_content, '\n');
            while (lines.next()) |line| {
                if (no_color) {
                    try io.print("-{s}\n", .{line});
                } else {
                    try io.print("\x1b[31m-{s}\x1b[0m\n", .{line});
                }
            }
        }
    }

    if (!has_diff) {
        try io.print("No staged changes\n", .{});
    }
}

fn diffWorking(allocator: std.mem.Allocator, git_dir: []const u8, io: Io, no_color: bool) !void {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const refs_manager = refs.Refs.init(git_dir);

    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
        try io.print("No commits yet\n", .{});
        return;
    };

    // Get HEAD tree entries
    var head_entries = std.StringHashMap([20]u8).init(allocator);
    defer {
        var iter = head_entries.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        head_entries.deinit();
    }

    const commit_obj = store.read(allocator, io.io, head_sha) catch return;
    const commit = switch (commit_obj) {
        .commit => |c| c,
        else => return,
    };
    const tree_obj = store.read(allocator, io.io, commit.tree) catch return;
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        const owned_name = try allocator.dupe(u8, entry.name);
        try head_entries.put(owned_name, entry.sha);
    }

    var has_diff = false;
    var ht_iter = head_entries.iterator();
    while (ht_iter.next()) |entry| {
        const file_name = entry.key_ptr.*;
        const blob_sha = entry.value_ptr.*;

        // Read current working tree version
        const new_content = std.Io.Dir.cwd().readFileAlloc(io.io, file_name, allocator, .unlimited) catch {
            // File deleted
            has_diff = true;
            const old_obj = store.read(allocator, io.io, blob_sha) catch continue;
            const old_content = switch (old_obj) {
                .blob => |b| b.content,
                else => continue,
            };
            try io.print("diff --git a/{s} b/{s}\n", .{ file_name, file_name });
            try io.print("deleted file mode 100644\n", .{});
            try io.print("--- a/{s}\n", .{file_name});
            try io.print("+++ /dev/null\n", .{});

            var lines = std.mem.splitScalar(u8, old_content, '\n');
            while (lines.next()) |line| {
                if (no_color) {
                    try io.print("-{s}\n", .{line});
                } else {
                    try io.print("\x1b[31m-{s}\x1b[0m\n", .{line});
                }
            }
            continue;
        };
        defer allocator.free(new_content);

        // Get old content
        const old_obj = store.read(allocator, io.io, blob_sha) catch continue;
        const old_content = switch (old_obj) {
            .blob => |b| b.content,
            else => continue,
        };

        if (!std.mem.eql(u8, old_content, new_content)) {
            has_diff = true;
            try printDiff(allocator, io, file_name, old_content, new_content, no_color);
        }
    }

    if (!has_diff) {
        try io.print("No changes\n", .{});
    }
}

fn printDiff(allocator: std.mem.Allocator, io: Io, file_name: []const u8, old_content: []const u8, new_content: []const u8, no_color: bool) !void {
    // Split into lines
    var old_lines = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer old_lines.deinit(allocator);
    var new_lines = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer new_lines.deinit(allocator);

    var old_iter = std.mem.splitScalar(u8, old_content, '\n');
    while (old_iter.next()) |line| {
        try old_lines.append(allocator, line);
    }
    var new_iter = std.mem.splitScalar(u8, new_content, '\n');
    while (new_iter.next()) |line| {
        try new_lines.append(allocator, line);
    }

    // Run Myers diff
    const diff_result = diff_mod.myersDiff(allocator, old_lines.items, new_lines.items) catch return;
    defer diff_result.deinit(allocator);

    if (diff_result.isEmpty()) return;

    try io.print("diff --git a/{s} b/{s}\n", .{ file_name, file_name });
    try io.print("--- a/{s}\n", .{file_name});
    try io.print("+++ b/{s}\n", .{file_name});

    for (diff_result.hunks) |hunk| {
        try io.print("@@ -{d},{d} +{d},{d} @@\n", .{ hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count });

        for (hunk.lines) |line| {
            switch (line.type) {
                .context => {
                    try io.print(" {s}\n", .{line.content});
                },
                .added => {
                    if (no_color) {
                        try io.print("+{s}\n", .{line.content});
                    } else {
                        try io.print("\x1b[32m+{s}\x1b[0m\n", .{line.content});
                    }
                },
                .deleted => {
                    if (no_color) {
                        try io.print("-{s}\n", .{line.content});
                    } else {
                        try io.print("\x1b[31m-{s}\x1b[0m\n", .{line.content});
                    }
                },
            }
        }
    }
}

/// Diff between two branches (or branch and HEAD)
fn diffBranches(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: Io,
    no_color: bool,
    branch_a: ?[]const u8,
    branch_b: ?[]const u8,
) !void {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const refs_manager = refs.Refs.init(git_dir);

    // Resolve branch A (base)
    const sha_a = blk: {
        if (branch_a) |a| {
            break :blk resolveRef(allocator, &refs_manager, io.io, git_dir, a) catch {
                try io.eprint("fatal: bad revision '{s}'\n", .{a});
                return;
            };
        } else {
            break :blk refs_manager.read(allocator, io.io, "HEAD") catch {
                try io.eprint("fatal: no commits yet\n", .{});
                return;
            };
        }
    };

    // Resolve branch B (target)
    const sha_b = blk: {
        if (branch_b) |b| {
            break :blk resolveRef(allocator, &refs_manager, io.io, git_dir, b) catch {
                try io.eprint("fatal: bad revision '{s}'\n", .{b});
                return;
            };
        } else {
            break :blk refs_manager.read(allocator, io.io, "HEAD") catch {
                try io.eprint("fatal: no commits yet\n", .{});
                return;
            };
        }
    };

    // Get trees from both commits
    var tree_a_entries = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = tree_a_entries.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        tree_a_entries.deinit();
    }

    var tree_b_entries = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = tree_b_entries.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        tree_b_entries.deinit();
    }

    // Collect files from commit A
    collectFileContents(allocator, store, io.io, sha_a, "", &tree_a_entries);

    // Collect files from commit B
    collectFileContents(allocator, store, io.io, sha_b, "", &tree_b_entries);

    // Header
    const hex_a = Sha1.hex(sha_a);
    const hex_b = Sha1.hex(sha_b);
    try io.print("\x1b[33mdiff --git a/... b/...\x1b[0m\n", .{});
    try io.print("\x1b[33mindex {s}..{s}\x1b[0m\n", .{ hex_a[0..7], hex_b[0..7] });

    // Diff each file
    var has_diff = false;

    var b_iter = tree_b_entries.iterator();
    while (b_iter.next()) |entry| {
        const path = entry.key_ptr.*;
        const content_b = entry.value_ptr.*;

        if (tree_a_entries.get(path)) |content_a| {
            if (std.mem.eql(u8, content_a, content_b)) continue;

            has_diff = true;
            try io.print("\x1b[36mdiff --git a/{s} b/{s}\x1b[0m\n", .{ path, path });
            try io.print("\x1b[31m--- a/{s}\x1b[0m\n", .{path});
            try io.print("\x1b[32m+++ b/{s}\x1b[0m\n", .{path});

            // Split and diff
            var old_lines = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
            defer old_lines.deinit(allocator);
            var old_iter = std.mem.splitScalar(u8, content_a, '\n');
            while (old_iter.next()) |l| try old_lines.append(allocator, l);

            var new_lines = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
            defer new_lines.deinit(allocator);
            var new_iter = std.mem.splitScalar(u8, content_b, '\n');
            while (new_iter.next()) |l| try new_lines.append(allocator, l);

            const diff_result = try diff_mod.myersDiff(allocator, old_lines.items, new_lines.items);
            defer diff_result.deinit(allocator);

            for (diff_result.hunks) |hunk| {
                try io.print("\x1b[36m@@ -{d},{d} +{d},{d} @@\x1b[0m\n", .{ hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count });
                for (hunk.lines) |line| {
                    switch (line.type) {
                        .context => {
                            if (no_color) {
                                try io.print(" {s}\n", .{line.content});
                            } else {
                                try io.print("\x1b[2m {s}\x1b[0m\n", .{line.content});
                            }
                        },
                        .added => {
                            if (no_color) {
                                try io.print("+{s}\n", .{line.content});
                            } else {
                                try io.print("\x1b[32m+{s}\x1b[0m\n", .{line.content});
                            }
                        },
                        .deleted => {
                            if (no_color) {
                                try io.print("-{s}\n", .{line.content});
                            } else {
                                try io.print("\x1b[31m-{s}\x1b[0m\n", .{line.content});
                            }
                        },
                    }
                }
            }
        } else {
            // New file in B
            has_diff = true;
            try io.print("\x1b[36mdiff --git a/{s} b/{s}\x1b[0m\n", .{ path, path });
            try io.print("\x1b[32mnew file mode 100644\x1b[0m\n", .{});
            try io.print("\x1b[31m--- /dev/null\x1b[0m\n", .{});
            try io.print("\x1b[32m+++ b/{s}\x1b[0m\n", .{path});

            var lines = std.mem.splitScalar(u8, content_b, '\n');
            while (lines.next()) |line| {
                try io.print("\x1b[32m+{s}\x1b[0m\n", .{line});
            }
        }
    }

    // Deleted files (in A but not in B)
    var a_iter = tree_a_entries.iterator();
    while (a_iter.next()) |entry| {
        const path = entry.key_ptr.*;
        if (!tree_b_entries.contains(path)) {
            has_diff = true;
            try io.print("\x1b[36mdiff --git a/{s} b/{s}\x1b[0m\n", .{ path, path });
            try io.print("\x1b[31mdeleted file mode 100644\x1b[0m\n", .{});
            try io.print("\x1b[31m--- a/{s}\x1b[0m\n", .{path});
            try io.print("\x1b[32m+++ /dev/null\x1b[0m\n", .{});

            var lines = std.mem.splitScalar(u8, entry.value_ptr.*, '\n');
            while (lines.next()) |line| {
                try io.print("\x1b[31m-{s}\x1b[0m\n", .{line});
            }
        }
    }

    if (!has_diff) {
        try io.print("No changes between branches\n", .{});
    }
}

fn collectFileContents(
    allocator: std.mem.Allocator,
    store: storage_mod.StorageBackend,
    io: std.Io,
    sha: [20]u8,
    prefix: []const u8,
    files: *std.StringHashMap([]const u8),
) void {
    // Read commit to get tree
    const obj = store.read(allocator, io, sha) catch return;
    const commit = switch (obj) {
        .commit => |c| c,
        else => return,
    };

    collectTreeContents(allocator, store, io, commit.tree, prefix, files);
}

fn collectTreeContents(
    allocator: std.mem.Allocator,
    store: storage_mod.StorageBackend,
    io: std.Io,
    tree_sha: [20]u8,
    prefix: []const u8,
    files: *std.StringHashMap([]const u8),
) void {
    const obj = store.read(allocator, io, tree_sha) catch return;
    const tree = switch (obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        const full_path = if (prefix.len > 0)
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name }) catch continue
        else
            allocator.dupe(u8, entry.name) catch continue;

        if (entry.mode == 0o040000) {
            collectTreeContents(allocator, store, io, entry.sha, full_path, files);
            allocator.free(full_path);
        } else {
            const blob_obj = store.read(allocator, io, entry.sha) catch {
                allocator.free(full_path);
                continue;
            };
            const content = switch (blob_obj) {
                .blob => |b| b.content,
                else => {
                    allocator.free(full_path);
                    continue;
                },
            };
            const owned = allocator.dupe(u8, content) catch {
                allocator.free(full_path);
                continue;
            };
            files.put(full_path, owned) catch {
                allocator.free(full_path);
                allocator.free(owned);
            };
        }
    }
}

fn resolveRef(
    allocator: std.mem.Allocator,
    refs_manager: *const refs.Refs,
    io: std.Io,
    _: []const u8,
    name: []const u8,
) ![20]u8 {
    // Try as branch
    const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name});
    defer allocator.free(branch_ref);
    if (refs_manager.read(allocator, io, branch_ref)) |sha| return sha else |_| {}

    // Try as tag
    const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{name});
    defer allocator.free(tag_ref);
    if (refs_manager.read(allocator, io, tag_ref)) |sha| return sha else |_| {}

    // Try as HEAD
    if (std.mem.eql(u8, name, "HEAD")) {
        return refs_manager.read(allocator, io, "HEAD") catch return error.RefNotFound;
    }

    // Try as hex prefix
    if (name.len >= 4) {
        var padded: [40]u8 = undefined;
        @memcpy(&padded, name);
        @memset(padded[name.len..], '0');
        return Sha1.fromHex(&padded) catch return error.RefNotFound;
    }

    return error.RefNotFound;
}
