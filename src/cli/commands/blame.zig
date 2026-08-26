const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");

/// Blame info for a single line
const LineBlame = struct {
    sha: [20]u8,
    author: []const u8,
    timestamp: i64,
    content: []const u8,
    /// Whether these slices are owned (need freeing)
    owned: bool = false,
};

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    if (args.len == 0) {
        try io.eprint("usage: gitz blame <file>\n", .{});
        std.process.exit(1);
    }

    const file_path = args[0];
    const refs_manager = refs_mod.Refs.init(git_dir);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);

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
    var current_lines = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer current_lines.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, file_content, '\n');
    while (line_iter.next()) |line| {
        try current_lines.append(allocator, line);
    }

    // For each line, walk back through history to find who last changed it
    var blame_result = try allocator.alloc(LineBlame, current_lines.items.len);
    defer {
        for (blame_result) |b| {
            if (b.owned) {
                allocator.free(b.author);
                allocator.free(b.content);
            }
        }
        allocator.free(blame_result);
    }

    // Initialize all lines with the latest commit
    const latest_obj = store.read(allocator, io.io, head_sha) catch return;
    const latest_commit = switch (latest_obj) {
        .commit => |c| c,
        else => return,
    };

    for (blame_result, 0..) |*blame, idx| {
        blame.sha = head_sha;
        blame.author = try allocator.dupe(u8, latest_commit.author.name);
        blame.timestamp = latest_commit.author.timestamp;
        blame.content = if (idx < current_lines.items.len)
            try allocator.dupe(u8, current_lines.items[idx])
        else
            "";
        blame.owned = true;
    }

    // Walk history: for each commit, check if any lines differ from its parent
    var current_sha = head_sha;
    while (true) {
        const obj = store.read(allocator, io.io, current_sha) catch break;
        const commit = switch (obj) {
            .commit => |c| c,
            else => break,
        };

        if (commit.parents.len == 0) break;
        const parent_sha = commit.parents[0];

        // Read current commit's file content from its tree
        const current_content = readFileFromTree(allocator, io.io, store, commit.tree, file_path);

        // Read parent's content
        const parent_obj = store.read(allocator, io.io, parent_sha) catch break;
        const parent_commit = switch (parent_obj) {
            .commit => |c| c,
            else => break,
        };
        const parent_content = readFileFromTree(allocator, io.io, store, parent_commit.tree, file_path);

        if (current_content == null or parent_content == null) break;

        const cur = current_content.?;
        const par = parent_content.?;
        defer allocator.free(cur);
        defer allocator.free(par);

        // Copy author metadata before it might get freed
        const author_ts = commit.author.timestamp;

        // Compare line by line
        var cur_lines = std.mem.splitScalar(u8, cur, '\n');
        var par_lines = std.mem.splitScalar(u8, par, '\n');

        var line_idx: usize = 0;
        while (cur_lines.next()) |cur_line| {
            const par_line = par_lines.next() orelse "";
            if (line_idx < blame_result.len) {
                if (!std.mem.eql(u8, cur_line, par_line)) {
                    // This line was changed in this commit.
                    // NOTE: each entry owns its own author copy — sharing one
                    // slice here caused double-frees and garbled blame output
                    // for commits touching several lines.
                    if (blame_result[line_idx].owned) {
                        allocator.free(blame_result[line_idx].author);
                        allocator.free(blame_result[line_idx].content);
                    }
                    blame_result[line_idx] = .{
                        .sha = current_sha,
                        .author = try allocator.dupe(u8, commit.author.name),
                        .timestamp = author_ts,
                        .content = try allocator.dupe(u8, cur_line),
                        .owned = true,
                    };
                }
            }
            line_idx += 1;
        }

        current_sha = parent_sha;
    }

    // Print blame output
    for (blame_result) |blame| {
        const hex = Sha1.hex(blame.sha);
        const ts = blame.timestamp;
        const year = yearOf(ts);
        // Sanitize author name — strip non-printable chars that can appear
        // in commits imported from git repos with unusual encodings.
        var sane_author_buf: [128]u8 = undefined;
        var sane_len: usize = 0;
        for (blame.author) |ch| {
            if (ch >= 0x20 and ch < 0x7f and sane_len < sane_author_buf.len) {
                sane_author_buf[sane_len] = ch;
                sane_len += 1;
            }
        }
        const sane_author: []const u8 = if (sane_len > 0) sane_author_buf[0..sane_len] else "unknown";
        try io.print("{s} ({s} {d:4}) {s}\n", .{
            hex[0..7],
            sane_author,
            year,
            blame.content,
        });
    }
}

// Convert a Unix timestamp to a calendar year (Howard Hinnant's civil_from_days).
fn yearOf(ts: i64) i64 {
    const days_i64 = @divFloor(ts, 86400);
    const z = days_i64 + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    return yoe + era * 400;
}

/// Read a file's content from a tree object
fn readFileFromTree(allocator: std.mem.Allocator, io: std.Io, store: storage_mod.StorageBackend, tree_sha: [20]u8, file_path: []const u8) ?[]const u8 {
    const tree_obj = store.read(allocator, io, tree_sha) catch return null;
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return null,
    };

    // Simple path matching (single-level only)
    for (tree.entries) |entry| {
        if (std.mem.eql(u8, entry.name, file_path)) {
            // Read the blob
            const blob_obj = store.read(allocator, io, entry.sha) catch return null;
            const blob = switch (blob_obj) {
                .blob => |b| b,
                else => return null,
            };
            return blob.content;
        }
    }

    // Try subdirectories
    for (tree.entries) |entry| {
        if (entry.mode == 0o040000) { // directory
            // Strip first path component
            if (std.mem.indexOf(u8, file_path, "/")) |slash_pos| {
                const remainder = file_path[slash_pos + 1 ..];
                if (readFileFromTree(allocator, io, store, entry.sha, remainder)) |content| {
                    return content;
                }
            }
        }
    }

    return null;
}
