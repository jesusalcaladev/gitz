const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const refs = @import("../../core/refs.zig");
const index_mod = @import("../../core/index.zig");
const diff_mod = @import("../../core/diff.zig");
const checkout_mod = @import("../../core/checkout.zig");
const errors = @import("../errors.zig");

/// What the two sides of the diff are.
const Mode = enum {
    /// index vs HEAD
    staged,
    /// worktree vs HEAD
    working,
    /// commit vs commit, or commit vs worktree
    revs,
};

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var mode: Mode = .working;
    var no_color = false;
    var quiet = false;
    var revs = std.ArrayList([]const u8).empty;
    defer revs.deinit(allocator);
    var pathspecs = std.ArrayList([]const u8).empty;
    defer {
        for (pathspecs.items) |p| allocator.free(p);
        pathspecs.deinit(allocator);
    }

    var after_separator = false;
    for (args) |arg| {
        if (after_separator) {
            try pathspecs.append(allocator, try io.rebasePath(arg));
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            after_separator = true;
        } else if (std.mem.eql(u8, arg, "--staged") or std.mem.eql(u8, arg, "--cached")) {
            mode = .staged;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            no_color = true;
        } else if (std.mem.eql(u8, arg, "--color") or std.mem.startsWith(u8, arg, "--color=")) {
            no_color = false;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--exit-code")) {
            quiet = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            errors.errorf(io, "unknown option '{s}'", .{arg});
        } else {
            try revs.append(allocator, try io.rebasePath(arg));
        }
    }

    // Revision arguments used to be dropped, so `gitz diff HEAD~1`,
    // `gitz diff v1.0 v2.0` and `gitz diff main..feature` all printed the
    // working-tree diff.
    if (revs.items.len > 0) {
        try diffRevs(allocator, git_dir, io, revs.items, pathspecs.items, no_color, quiet);
        return;
    }

    if (mode == .staged) {
        try diffStaged(allocator, git_dir, io, no_color, pathspecs.items);
        return;
    }

    try diffWorking(allocator, git_dir, io, no_color, pathspecs.items, quiet);
}

/// Diff two revisions, a revision against the working tree, or a range.
fn diffRevs(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: Io,
    revs: []const []const u8,
    pathspecs: []const []const u8,
    no_color: bool,
    quiet: bool,
) !void {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const refs_manager = refs.Refs.init(git_dir);

    var old_files = checkout_mod.FileMap.init(allocator);
    defer {
        var it = old_files.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        old_files.deinit();
    }
    var new_files = checkout_mod.FileMap.init(allocator);
    defer {
        var it = new_files.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        new_files.deinit();
    }

    // `a..b` is shorthand for `a b`.
    var old_spec: []const u8 = "HEAD";
    var new_spec: []const u8 = "HEAD";
    if (revs.len == 1) {
        if (std.mem.indexOf(u8, revs[0], "..")) |dots| {
            old_spec = revs[0][0..dots];
            new_spec = revs[0][dots + 2 ..];
        } else {
            new_spec = revs[0];
        }
    } else if (revs.len >= 2) {
        old_spec = revs[0];
        new_spec = revs[1];
    } else {
        return errors.errorf(io, "too few arguments", .{});
    }

    if (resolveCommit(allocator, io, refs_manager, store, old_spec)) |sha| {
        if (flattenCommitTree(allocator, io, store, sha)) |map| {
            old_files = map;
        } else |err| {
            errors.errorf(io, "bad revision '{s}': {s}", .{ old_spec, @errorName(err) });
        }
    } else |err| {
        errors.errorf(io, "bad revision '{s}': {s}", .{ old_spec, @errorName(err) });
    }

    // A revision named with `:` or a path, or a plain worktree comparison.
    const new_is_worktree = std.mem.endsWith(u8, new_spec, "/") or
        std.fs.path.isAbsolute(new_spec) or
        std.mem.indexOfScalar(u8, new_spec, '/') != null or
        std.mem.indexOf(u8, new_spec, "..") != null or
        !hasRevision(allocator, io, refs_manager, store, new_spec);

    if (new_is_worktree) {
        try collectWorktree(allocator, git_dir, io, store, &new_files, pathspecs);
    } else if (resolveCommit(allocator, io, refs_manager, store, new_spec)) |sha| {
        if (flattenCommitTree(allocator, io, store, sha)) |map| {
            new_files = map;
        } else |err| {
            errors.errorf(io, "bad revision '{s}': {s}", .{ new_spec, @errorName(err) });
        }
    } else |err| {
        errors.errorf(io, "bad revision '{s}': {s}", .{ new_spec, @errorName(err) });
    }

    var has_diff = false;
    var it = new_files.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        if (!matchesPathspec(pathspecs, path)) continue;

        const new_content = checkout_mod.readBlob(allocator, io.io, store, entry.value_ptr.sha) orelse continue;
        defer allocator.free(new_content);

        if (old_files.get(path)) |old_entry| {
            const old_content = checkout_mod.readBlob(allocator, io.io, store, old_entry.sha) orelse continue;
            defer allocator.free(old_content);
            if (!std.mem.eql(u8, old_content, new_content)) {
                has_diff = true;
                try printDiff(allocator, io, path, old_content, new_content, no_color);
            }
        } else {
            has_diff = true;
            try printWholeFile(allocator, io, path, new_content, .added, no_color);
        }
    }

    var oit = old_files.iterator();
    while (oit.next()) |entry| {
        const path = entry.key_ptr.*;
        if (new_files.contains(path)) continue;
        if (!matchesPathspec(pathspecs, path)) continue;
        const old_content = checkout_mod.readBlob(allocator, io.io, store, entry.value_ptr.sha) orelse continue;
        defer allocator.free(old_content);
        has_diff = true;
        try printWholeFile(allocator, io, path, old_content, .deleted, no_color);
    }

    // `--exit-code` reports through the exit status; `--quiet` says nothing.
    if (has_diff and quiet) std.process.exit(1);
    if (has_diff) {
        const code: u8 = 1;
        std.process.exit(code);
    }
}

fn hasRevision(
    allocator: std.mem.Allocator,
    io: Io,
    refs_manager: refs.Refs,
    store: storage_mod.StorageBackend,
    spec: []const u8,
) bool {
    _ = resolveCommit(allocator, io, refs_manager, store, spec) catch return false;
    return true;
}

/// Whether `path` is selected by any pathspec (directory prefixes count).
fn matchesPathspec(pathspecs: []const []const u8, path: []const u8) bool {
    if (pathspecs.len == 0) return true;
    for (pathspecs) |spec| {
        if (std.mem.eql(u8, spec, path)) return true;
        if (spec.len < path.len and std.mem.startsWith(u8, path, spec) and path[spec.len] == '/') return true;
    }
    return false;
}

/// Read the working tree into a FileMap, for `git diff <rev>`.
fn collectWorktree(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: Io,
    store: storage_mod.StorageBackend,
    out: *checkout_mod.FileMap,
    pathspecs: []const []const u8,
) !void {
    var idx = index_mod.Index.readFromFile(allocator, git_dir, io.io) catch return;
    defer idx.deinit(allocator);

    for (idx.entries.items) |entry| {
        const name = if (std.mem.startsWith(u8, entry.name, "./")) entry.name[2..] else entry.name;
        if (!matchesPathspec(pathspecs, name)) continue;
        const content = std.Io.Dir.cwd().readFileAlloc(io.io, name, allocator, .unlimited) catch continue;
        const sha = checkout_mod.blobSha(allocator, content) catch {
            allocator.free(content);
            continue;
        };
        allocator.free(content);

        const key = try allocator.dupe(u8, name);
        if (out.getPtr(key)) |old| {
            allocator.free(key);
            old.* = .{ .sha = sha, .mode = entry.mode };
        } else {
            try out.put(key, .{ .sha = sha, .mode = entry.mode });
        }
    }
    _ = store;
}

/// Resolve `HEAD~2`, a branch name, `v1.0`, or a raw SHA.
fn resolveCommit(
    allocator: std.mem.Allocator,
    io: Io,
    refs_manager: refs.Refs,
    store: storage_mod.StorageBackend,
    spec: []const u8,
) ![20]u8 {
    if (refs_manager.read(allocator, io.io, spec)) |sha| return sha else |_| {}
    if (refs_manager.read(allocator, io.io, "HEAD")) |head| {
        if (try walkAncestors(allocator, io, store, head, spec)) |sha| return sha;
    } else |_| {}
    if (Sha1.fromHex(spec)) |sha| {
        if (store.exists(io.io, sha)) return sha;
        return error.BadRevision;
    } else |_| {}
    if (std.mem.endsWith(u8, spec, "^{}")) {
        return resolveCommit(allocator, io, refs_manager, store, spec[0 .. spec.len - 3]);
    }
    return error.BadRevision;
}

/// Handle `HEAD~N`, `HEAD^N`, `HEAD^2` and `name~N` style suffixes.
fn walkAncestors(
    allocator: std.mem.Allocator,
    io: Io,
    store: storage_mod.StorageBackend,
    start: [20]u8,
    spec: []const u8,
) !?[20]u8 {
    const tilde = std.mem.indexOfScalar(u8, spec, '~') orelse return null;
    var current = start;

    const suffix = spec[tilde + 1 ..];
    var count: usize = 1;
    if (suffix.len > 0) {
        count = std.fmt.parseInt(usize, suffix, 10) catch return null;
    }
    // The name before `~` is only a label; the walk starts at start.
    for (0..count) |_| {
        const obj = store.read(allocator, io.io, current) catch return null;
        const commit = switch (obj) {
            .commit => |c| c,
            else => return null,
        };
        if (commit.parents.len == 0) return null;
        current = commit.parents[0];
    }
    return current;
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

fn diffStaged(allocator: std.mem.Allocator, git_dir: []const u8, io: Io, no_color: bool, pathspecs: []const []const u8) !void {
    // A pathspec narrows the report; an empty one matches everything.
    const no_pathspec = pathspecs.len == 0;
    var idx = index_mod.Index.readFromFile(allocator, git_dir, io.io) catch {
        return;
    };
    defer idx.deinit(allocator);

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const refs_manager = refs.Refs.init(git_dir);

    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
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

        if (!no_pathspec and !matchesPathspec(pathspecs, clean_name)) continue;

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
            if (!no_pathspec and !matchesPathspec(pathspecs, entry.key_ptr.*)) continue;
            has_diff = true;
            const old_content = checkout_mod.readBlob(allocator, io.io, store, entry.value_ptr.sha) orelse continue;
            defer allocator.free(old_content);
            try printWholeFile(allocator, io, entry.key_ptr.*, old_content, .deleted, no_color);
        }
    }

    // Silence means silence, as in git: no "No staged changes" on stdout.
    if (!has_diff) try io.eprint("", .{});
}

fn diffWorking(allocator: std.mem.Allocator, git_dir: []const u8, io: Io, no_color: bool, pathspecs: []const []const u8, quiet: bool) !void {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const refs_manager = refs.Refs.init(git_dir);

    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
        return;
    };

    var head_entries = try flattenCommitTree(allocator, io, store, head_sha);
    defer freeFileMap(allocator, &head_entries);

    var has_diff = false;
    var ht_iter = head_entries.iterator();
    while (ht_iter.next()) |entry| {
        const file_name = entry.key_ptr.*;
        const blob_sha = entry.value_ptr.sha;

        if (!matchesPathspec(pathspecs, file_name)) continue;

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

    // `git diff` with no differences prints nothing at all. "No changes" went to
    // stdout, so `if [ -z "$(gitz diff)" ]` was never true.
    if (has_diff and quiet) std.process.exit(1);
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
