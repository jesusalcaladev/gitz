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

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--staged") or std.mem.eql(u8, arg, "--cached")) {
            staged = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            no_color = true;
        }
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
