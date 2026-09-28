const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const refs = @import("../../core/refs.zig");
const index_mod = @import("../../core/index.zig");
const diff_mod = @import("../../core/diff.zig");
const checkout_mod = @import("../../core/checkout.zig");

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

/// Flatten a commit's tree into path -> blob SHA.
///
/// The previous implementation iterated `tree.entries` of the root tree only,
/// so every file under a subdirectory was invisible: `gitz diff` printed
/// nothing for a change in `src/main.zig`, and `diff --staged` reported every
/// nested file as brand new.
fn flattenCommitTree(
    allocator: std.mem.Allocator,
    io: Io,
    store: storage_mod.StorageBackend,
    head_sha: [20]u8,
) !checkout_mod.FileMap {
    var map = checkout_mod.FileMap.init(allocator);

    const commit_obj = store.read(allocator, io.io, head_sha) catch return map;
    defer commit_obj.deinit(allocator);
    const commit = switch (commit_obj) {
        .commit => |c| c,
        else => return map,
    };

    checkout_mod.flattenTree(allocator, io.io, store, commit.tree, "", &map) catch {};
    return map;
}

fn freeFileMap(allocator: std.mem.Allocator, map: *checkout_mod.FileMap) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    map.deinit();
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

    var head_entries = try flattenCommitTree(allocator, io, store, head_sha);
    defer freeFileMap(allocator, &head_entries);

    var has_diff = false;
    for (idx.entries.items) |index_entry| {
        const clean_name = if (std.mem.startsWith(u8, index_entry.name, "./"))
            index_entry.name[2..]
        else
            index_entry.name;

        if (head_entries.get(clean_name)) |old_entry| {
            // Modified file - compare old vs new
            if (std.mem.eql(u8, &old_entry.sha, &index_entry.sha)) continue;

            const old_content = checkout_mod.readBlob(allocator, io.io, store, old_entry.sha) orelse continue;
            defer allocator.free(old_content);
            const new_content = checkout_mod.readBlob(allocator, io.io, store, index_entry.sha) orelse continue;
            defer allocator.free(new_content);

            has_diff = true;
            try printDiff(allocator, io, clean_name, old_content, new_content, no_color);
        } else {
            // New file
            const content = checkout_mod.readBlob(allocator, io.io, store, index_entry.sha) orelse continue;
            defer allocator.free(content);

            has_diff = true;
            try printWholeFile(allocator, io, clean_name, content, .added, no_color);
        }
    }

    // Check for deleted files (in HEAD but not in index)
    var ht_iter = head_entries.iterator();
    while (ht_iter.next()) |entry| {
        if (idx.get(entry.key_ptr.*) == null) {
            has_diff = true;
            const old_content = checkout_mod.readBlob(allocator, io.io, store, entry.value_ptr.sha) orelse continue;
            defer allocator.free(old_content);
            try printWholeFile(allocator, io, entry.key_ptr.*, old_content, .deleted, no_color);
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

    var head_entries = try flattenCommitTree(allocator, io, store, head_sha);
    defer freeFileMap(allocator, &head_entries);

    var has_diff = false;
    var ht_iter = head_entries.iterator();
    while (ht_iter.next()) |entry| {
        const file_name = entry.key_ptr.*;
        const blob_sha = entry.value_ptr.sha;

        // Read current working tree version
        const new_content = std.Io.Dir.cwd().readFileAlloc(io.io, file_name, allocator, .unlimited) catch {
            // File deleted
            has_diff = true;
            const old_content = checkout_mod.readBlob(allocator, io.io, store, blob_sha) orelse continue;
            defer allocator.free(old_content);
            try printWholeFile(allocator, io, file_name, old_content, .deleted, no_color);
            continue;
        };
        defer allocator.free(new_content);

        // Get old content
        const old_content = checkout_mod.readBlob(allocator, io.io, store, blob_sha) orelse continue;
        defer allocator.free(old_content);

        if (!std.mem.eql(u8, old_content, new_content)) {
            has_diff = true;
            try printDiff(allocator, io, file_name, old_content, new_content, no_color);
        }
    }

    if (!has_diff) {
        try io.print("No changes\n", .{});
    }
}

/// Emit a whole file as a single hunk, for added and deleted files.
fn printWholeFile(
    allocator: std.mem.Allocator,
    io: Io,
    file_name: []const u8,
    content: []const u8,
    line_type: diff_mod.LineType,
    no_color: bool,
) !void {
    const split = try diff_mod.splitLines(allocator, content);
    defer split.deinit(allocator);

    try io.print("diff --git a/{s} b/{s}\n", .{ file_name, file_name });
    if (line_type == .added) {
        try io.print("new file mode 100644\n", .{});
        try io.print("--- /dev/null\n", .{});
        try io.print("+++ b/{s}\n", .{file_name});
    } else {
        try io.print("deleted file mode 100644\n", .{});
        try io.print("--- a/{s}\n", .{file_name});
        try io.print("+++ /dev/null\n", .{});
    }

    const count: u32 = @intCast(split.lines.len);
    var header_buf: [64]u8 = undefined;
    const header = try diff_mod.formatHunkHeader(
        &header_buf,
        if (line_type == .added) 0 else 1,
        if (line_type == .added) 0 else count,
        if (line_type == .added) 1 else 0,
        if (line_type == .added) count else 0,
    );
    try io.print("{s}", .{header});

    for (split.lines) |line| {
        switch (line_type) {
            .added => try printLine(io, '+', line, .added, no_color),
            else => try printLine(io, '-', line, .deleted, no_color),
        }
    }

    if (split.missing_final_newline) {
        try io.print("\\ No newline at end of file\n", .{});
    }
}

fn printDiff(allocator: std.mem.Allocator, io: Io, file_name: []const u8, old_content: []const u8, new_content: []const u8, no_color: bool) !void {
    const old_split = try diff_mod.splitLines(allocator, old_content);
    defer old_split.deinit(allocator);
    const new_split = try diff_mod.splitLines(allocator, new_content);
    defer new_split.deinit(allocator);

    // Run Myers diff
    const diff_result = diff_mod.myersDiff(allocator, old_split.lines, new_split.lines) catch return;
    defer diff_result.deinit(allocator);

    if (diff_result.isEmpty()) return;

    try io.print("diff --git a/{s} b/{s}\n", .{ file_name, file_name });
    try io.print("--- a/{s}\n", .{file_name});
    try io.print("+++ b/{s}\n", .{file_name});

    for (diff_result.hunks) |hunk| {
        var header_buf: [64]u8 = undefined;
        const header = try diff_mod.formatHunkHeader(
            &header_buf,
            hunk.old_start,
            hunk.old_count,
            hunk.new_start,
            hunk.new_count,
        );
        try io.print("{s}", .{header});

        for (hunk.lines) |line| {
            switch (line.type) {
                .context => try io.print(" {s}\n", .{line.content}),
                .added => try printLine(io, '+', line.content, .added, no_color),
                .deleted => try printLine(io, '-', line.content, .deleted, no_color),
            }
        }
    }

    if (old_split.missing_final_newline and new_split.missing_final_newline) {
        try io.print("\\ No newline at end of file\n", .{});
    }
}

fn printLine(io: Io, prefix: u8, content: []const u8, line_type: diff_mod.LineType, no_color: bool) !void {
    _ = line_type;
    if (no_color) {
        try io.print("{c}{s}\n", .{ prefix, content });
    } else if (prefix == '+') {
        try io.print("\x1b[32m+{s}\x1b[0m\n", .{content});
    } else {
        try io.print("\x1b[31m-{s}\x1b[0m\n", .{content});
    }
}
