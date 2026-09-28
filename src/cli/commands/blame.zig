const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const diff_mod = @import("../../core/diff.zig");
const Repo = @import("../../core/repo.zig").Repo;

/// Blame info for a single line
const LineBlame = struct {
    sha: [20]u8,
    author: []const u8,
    timestamp: i64,
    content: []const u8,
    /// Whether these slices are owned (need freeing)
    owned: bool = false,
};

pub fn execute(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    // For a repository with no worktrees the three directories coincide, so
    // the existing path building below is unchanged. A linked worktree gets
    // the right directory per role from `repo`.
    if (args.len == 0) {
        try io.eprint("usage: gitz blame <file>\n", .{});
        std.process.exit(1);
    }

    const file_path = args[0];
    const refs_manager = refs_mod.Refs.init(repo);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);

    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
        try io.eprint("fatal: no commits yet\n", .{});
        return;
    };

    // Read current file content
    const file_content = std.Io.Dir.cwd().readFileAlloc(io.io, file_path, allocator, .unlimited) catch {
        try io.eprint("fatal: pathspec '{s}' did not match any files\n", .{file_path});
        return;
    };
    defer allocator.free(file_content);

    // Split current file into lines
    const head_split = diff_mod.splitLines(allocator, file_content) catch return;
    defer head_split.deinit(allocator);

    const line_count = head_split.lines.len;
    const blame_result = try allocator.alloc(LineBlame, line_count);
    defer {
        // Every entry owns exactly one author copy and one content copy, and
        // each is freed exactly once. The previous code shared a single
        // `author_name` allocation across every line a commit touched and
        // freed it as soon as one unchanged line appeared, so the cleanup loop
        // freed the same pointer several times and printed freed memory
        // (mojibake author names) in the process.
        for (blame_result) |b| {
            allocator.free(b.author);
            allocator.free(b.content);
        }
        allocator.free(blame_result);
    }

    const store2 = store;
    try attributeLines(allocator, io, store2, head_sha, file_path, head_split.lines, blame_result);

    // Print blame output
    for (blame_result) |blame| {
        const hex = Sha1.hex(blame.sha);
        const year = calendarYear(blame.timestamp);
        try io.print("{s} ({s} {d:4}) {s}\n", .{
            hex[0..7],
            blame.author,
            year,
            blame.content,
        });
    }
}

/// Sentinel for "this line of the commit is not part of the walk".
const not_in_play = std.math.maxInt(u32);

/// One step of the blame walk.
///
/// `lines` is indexed by *line number - 1* of `commit`'s version of the file
/// and holds the output line each one belongs to, or `not_in_play`. It has to
/// be sparse: an earlier version appended only the carried lines, which
/// compacted the array and made the index stop matching the line number, so
/// lines were attributed to the wrong commit.
const Frontier = struct {
    commit: [20]u8,
    lines: []u32,

    fn deinit(self: Frontier, allocator: std.mem.Allocator) void {
        allocator.free(self.lines);
    }

    fn forOutput(self: Frontier, one_based: u32) ?usize {
        if (one_based == 0 or one_based > self.lines.len) return null;
        const out = self.lines[one_based - 1];
        if (out == not_in_play) return null;
        return out;
    }
};

fn newFrontier(allocator: std.mem.Allocator, commit: [20]u8, line_count: usize) !Frontier {
    const lines = try allocator.alloc(u32, line_count);
    @memset(lines, not_in_play);
    return .{ .commit = commit, .lines = lines };
}

/// Walk history newest-first, attributing each line to the most recent commit
/// that introduced it.
///
/// The old implementation compared line *i* of a commit with line *i* of its
/// parent and overwrote earlier results while walking backwards, so one
/// insertion shifted every later line's attribution and the final answer
/// credited the oldest commit that differed. Here a line is assigned once, by
/// the newest commit that introduced it, and unchanged lines are handed to the
/// parent by line number rather than by position.
fn attributeLines(
    allocator: std.mem.Allocator,
    io: Io,
    store: storage_mod.StorageBackend,
    head_sha: [20]u8,
    file_path: []const u8,
    head_lines: []const []const u8,
    blame_result: []LineBlame,
) !void {
    const assigned = try allocator.alloc(bool, blame_result.len);
    defer allocator.free(assigned);
    @memset(assigned, false);

    var frontier = std.ArrayList(Frontier).empty;
    defer {
        for (frontier.items) |f| f.deinit(allocator);
        frontier.deinit(allocator);
    }

    var first = try newFrontier(allocator, head_sha, head_lines.len);
    for (head_lines, 0..) |line, i| {
        blame_result[i] = .{
            .sha = head_sha,
            .author = try allocator.dupe(u8, ""),
            .timestamp = 0,
            .content = try allocator.dupe(u8, line),
        };
        first.lines[i] = @intCast(i);
    }
    try frontier.append(allocator, first);

    // Bounds the walk so a corrupt graph containing a cycle cannot hang.
    var steps: usize = 0;
    const max_steps: usize = 100_000;

    while (frontier.items.len > 0) {
        steps += 1;
        if (steps > max_steps) break;

        const item = frontier.pop().?;
        defer item.deinit(allocator);

        const author = authorOf(allocator, io, store, item.commit) orelse continue;

        const commit_tree = treeOf(allocator, io, store, item.commit) orelse {
            // Cannot inspect this commit: anything still unassigned belongs to
            // it, which is better than leaving the line unattributed.
            assignRest(allocator, blame_result, assigned, author);
            continue;
        };
        const parent_sha = firstParentOf(allocator, io, store, item.commit) orelse {
            assignRest(allocator, blame_result, assigned, author);
            continue;
        };
        const parent_tree = treeOf(allocator, io, store, parent_sha) orelse {
            assignRest(allocator, blame_result, assigned, author);
            continue;
        };

        const cur_content = readFileFromTree(allocator, io.io, store, commit_tree, file_path) orelse {
            assignRest(allocator, blame_result, assigned, author);
            continue;
        };
        defer allocator.free(cur_content);
        const parent_content = readFileFromTree(allocator, io.io, store, parent_tree, file_path) orelse {
            assignRest(allocator, blame_result, assigned, author);
            continue;
        };
        defer allocator.free(parent_content);

        const cur_split = diff_mod.splitLines(allocator, cur_content) catch continue;
        defer cur_split.deinit(allocator);
        const parent_split = diff_mod.splitLines(allocator, parent_content) catch continue;
        defer parent_split.deinit(allocator);

        const edits = diff_mod.lineEdits(allocator, parent_split.lines, cur_split.lines) catch continue;
        defer allocator.free(edits);

        var carried = try newFrontier(allocator, parent_sha, parent_split.lines.len);
        var carried_any = false;

        for (edits) |edit| {
            switch (edit.type) {
                // The line exists in both versions: the parent gets to explain
                // it, so it is recorded in the *parent's* numbering.
                .context => {
                    const parent_line = edit.old_line orelse continue;
                    const new_line = edit.new_line orelse continue;
                    const out_idx = item.forOutput(new_line) orelse continue;
                    if (parent_line == 0 or parent_line > carried.lines.len) continue;
                    carried.lines[parent_line - 1] = @intCast(out_idx);
                    carried_any = true;
                },
                .added => {
                    const new_line = edit.new_line orelse continue;
                    const out_idx = item.forOutput(new_line) orelse continue;
                    assignLine(allocator, blame_result, assigned, out_idx, author) catch {};
                },
                .deleted => {},
            }
        }

        if (carried_any) try frontier.append(allocator, carried);
    }
}

/// Author identity of a commit, duplicated so each blamed line owns its copy.
const Author = struct {
    sha: [20]u8,
    name: []const u8,
    timestamp: i64,
};

fn authorOf(allocator: std.mem.Allocator, io: Io, store: storage_mod.StorageBackend, sha: [20]u8) ?Author {
    const obj = store.read(allocator, io.io, sha) catch return null;
    defer obj.deinit(allocator);
    const commit = switch (obj) {
        .commit => |c| c,
        else => return null,
    };
    const name = allocator.dupe(u8, commit.author.name) catch return null;
    return .{ .sha = sha, .name = name, .timestamp = commit.author.timestamp };
}

fn assignLine(
    allocator: std.mem.Allocator,
    blame_result: []LineBlame,
    assigned: []bool,
    out_idx: usize,
    author: Author,
) !void {
    if (out_idx >= blame_result.len) return;
    if (assigned[out_idx]) return;
    assigned[out_idx] = true;

    // One owned copy per line, freed exactly once by the caller. The previous
    // code stored a single shared `author_name` in every line a commit touched
    // and freed it on the first unchanged line, so the cleanup pass freed the
    // same pointer repeatedly and printed freed memory.
    allocator.free(blame_result[out_idx].author);
    blame_result[out_idx].author = try allocator.dupe(u8, author.name);
    blame_result[out_idx].sha = author.sha;
    blame_result[out_idx].timestamp = author.timestamp;
}

/// Attribute every still-unassigned line to `author` (root commit, or a commit
/// whose content could not be read).
fn assignRest(allocator: std.mem.Allocator, blame_result: []LineBlame, assigned: []bool, author: Author) void {
    for (blame_result, 0..) |*line, i| {
        if (assigned[i]) continue;
        assigned[i] = true;
        allocator.free(line.author);
        line.author = allocator.dupe(u8, author.name) catch "";
        line.sha = author.sha;
        line.timestamp = author.timestamp;
    }
    allocator.free(author.name);
}

fn treeOf(allocator: std.mem.Allocator, io: Io, store: storage_mod.StorageBackend, sha: [20]u8) ?[20]u8 {
    const obj = store.read(allocator, io.io, sha) catch return null;
    defer obj.deinit(allocator);
    const commit = switch (obj) {
        .commit => |c| c,
        else => return null,
    };
    return commit.tree;
}

fn firstParentOf(allocator: std.mem.Allocator, io: Io, store: storage_mod.StorageBackend, sha: [20]u8) ?[20]u8 {
    const obj = store.read(allocator, io.io, sha) catch return null;
    defer obj.deinit(allocator);
    const commit = switch (obj) {
        .commit => |c| c,
        else => return null,
    };
    if (commit.parents.len == 0) return null;
    return commit.parents[0];
}

fn calendarYear(timestamp: i64) i32 {
    if (timestamp <= 0) return 1970;
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    return @intCast(seconds.getEpochDay().calculateYearDay().year);
}

/// Read a file's content from a tree object
fn readFileFromTree(allocator: std.mem.Allocator, io: std.Io, store: storage_mod.StorageBackend, tree_sha: [20]u8, file_path: []const u8) ?[]const u8 {
    const tree_obj = store.read(allocator, io, tree_sha) catch return null;
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return null,
    };

    // Handle single-level paths
    if (std.mem.indexOf(u8, file_path, "/") == null) {
        for (tree.entries) |entry| {
            if (std.mem.eql(u8, entry.name, file_path)) {
                const blob_obj = store.read(allocator, io, entry.sha) catch return null;
                const blob = switch (blob_obj) {
                    .blob => |b| b,
                    else => return null,
                };
                // Return a copy to ensure proper encoding
                return allocator.dupe(u8, blob.content) catch null;
            }
        }
    }

    // Handle multi-level paths (subdirectories)
    for (tree.entries) |entry| {
        if (entry.mode == 0o040000) { // directory
            if (std.mem.startsWith(u8, file_path, entry.name)) {
                if (file_path.len > entry.name.len and file_path[entry.name.len] == '/') {
                    const remainder = file_path[entry.name.len + 1 ..];
                    if (readFileFromTree(allocator, io, store, entry.sha, remainder)) |content| {
                        return content;
                    }
                }
            }
        }
    }

    return null;
}

test "blame calendar year uses the Unix epoch" {
    try std.testing.expectEqual(@as(i32, 1970), calendarYear(0));
    try std.testing.expectEqual(@as(i32, 2021), calendarYear(1_622_924_906));
}
