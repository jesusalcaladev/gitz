const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const storage_mod = @import("storage.zig");
const object = @import("object.zig");
const diff_mod = @import("diff.zig");
const checkout = @import("checkout.zig");

// ============================================================================
// 3-way text merge (diff3-style)
// ============================================================================

pub const TextMerge = struct {
    content: []u8,
    conflict: bool,
    pub fn deinit(self: TextMerge, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

/// One side of the merge, expressed in base coordinates: which base lines are
/// still present (context) and which lines were inserted before each position.
const SideInfo = struct {
    ctx: []bool,
    inserts: std.AutoHashMap(usize, [][]const u8),

    fn deinit(self: *SideInfo, allocator: std.mem.Allocator) void {
        var it = self.inserts.valueIterator();
        while (it.next()) |lines| allocator.free(lines.*);
        self.inserts.deinit();
        allocator.free(self.ctx);
    }
};

fn splitLines(allocator: std.mem.Allocator, content: []const u8) !struct { lines: []const []const u8, trailing_newline: bool } {
    if (content.len == 0) {
        return .{ .lines = try allocator.alloc([]const u8, 0), .trailing_newline = false };
    }
    const trailing = content[content.len - 1] == '\n';
    const body = if (trailing) content[0 .. content.len - 1] else content;

    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);

    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        try list.append(allocator, line);
    }
    return .{ .lines = try list.toOwnedSlice(allocator), .trailing_newline = trailing };
}

fn buildSide(allocator: std.mem.Allocator, base_lines: []const []const u8, side_lines: []const []const u8) !SideInfo {
    const edits = try diff_mod.lineEdits(allocator, base_lines, side_lines);
    defer allocator.free(edits);

    const ctx = try allocator.alloc(bool, base_lines.len);
    @memset(ctx, false);

    var inserts: std.AutoHashMap(usize, [][]const u8) = .init(allocator);
    errdefer inserts.deinit();

    var pos: usize = 0;
    for (edits) |e| {
        switch (e.type) {
            .context => {
                if (pos < ctx.len) ctx[pos] = true;
                pos += 1;
            },
            .deleted => pos += 1,
            .added => {
                const gop = try inserts.getOrPut(pos);
                if (!gop.found_existing) gop.value_ptr.* = &.{};
                var lines = try allocator.alloc([]const u8, gop.value_ptr.*.len + 1);
                @memcpy(lines[0..gop.value_ptr.*.len], gop.value_ptr.*);
                lines[gop.value_ptr.*.len] = e.content;
                allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = lines;
            },
        }
    }

    return .{ .ctx = ctx, .inserts = inserts };
}

/// Render one side's version of base[lo..hi).
fn renderSide(
    allocator: std.mem.Allocator,
    base_lines: []const []const u8,
    side: *const SideInfo,
    lo: usize,
    hi: usize,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);

    var p = lo;
    while (p < hi) : (p += 1) {
        if (side.inserts.get(p)) |lines| {
            try out.appendSlice(allocator, lines);
        }
        if (p < side.ctx.len and side.ctx[p]) {
            try out.append(allocator, base_lines[p]);
        }
    }
    // Insertion at end-of-file belongs to the final chunk.
    if (hi == base_lines.len) {
        if (side.inserts.get(hi)) |lines| {
            try out.appendSlice(allocator, lines);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn linesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// 3-way merge of file contents. Returns the merged text; `conflict` is true
/// when markers were emitted.
pub fn mergeLines(
    allocator: std.mem.Allocator,
    base_content: []const u8,
    ours_content: []const u8,
    theirs_content: []const u8,
    theirs_label: []const u8,
) !TextMerge {
    const base = try splitLines(allocator, base_content);
    defer allocator.free(base.lines);
    const ours = try splitLines(allocator, ours_content);
    defer allocator.free(ours.lines);
    const theirs = try splitLines(allocator, theirs_content);
    defer allocator.free(theirs.lines);

    // No common base: the chunk walk below has no anchors to iterate over, so
    // decide directly — one-sided additions merge cleanly, identical additions
    // agree, and different additions conflict (like git's add/add merge).
    if (base.lines.len == 0) {
        if (ours_content.len == 0 and theirs_content.len == 0) {
            return .{ .content = try allocator.dupe(u8, ""), .conflict = false };
        }
        if (theirs_content.len == 0) {
            return .{ .content = try allocator.dupe(u8, ours_content), .conflict = false };
        }
        if (ours_content.len == 0) {
            return .{ .content = try allocator.dupe(u8, theirs_content), .conflict = false };
        }
        if (std.mem.eql(u8, ours_content, theirs_content)) {
            return .{ .content = try allocator.dupe(u8, ours_content), .conflict = false };
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "<<<<<<< HEAD\n");
        try out.appendSlice(allocator, ours_content);
        if (ours_content[ours_content.len - 1] != '\n') try out.append(allocator, '\n');
        try out.appendSlice(allocator, "=======\n");
        try out.appendSlice(allocator, theirs_content);
        if (theirs_content[theirs_content.len - 1] != '\n') try out.append(allocator, '\n');
        try out.appendSlice(allocator, ">>>>>>> ");
        try out.appendSlice(allocator, theirs_label);
        try out.append(allocator, '\n');
        return .{ .content = try out.toOwnedSlice(allocator), .conflict = true };
    }

    var ours_info = try buildSide(allocator, base.lines, ours.lines);
    defer ours_info.deinit(allocator);
    var theirs_info = try buildSide(allocator, base.lines, theirs.lines);
    defer theirs_info.deinit(allocator);

    // Chunk boundaries: positions that are clean anchors on BOTH sides.
    var edges: std.ArrayList(usize) = .empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, 0);
    for (0..base.lines.len + 1) |p| {
        const no_insert_o = ours_info.inserts.get(p) == null;
        const no_insert_t = theirs_info.inserts.get(p) == null;
        const before_ok = (p == 0) or (p > 0 and p - 1 < ours_info.ctx.len and ours_info.ctx[p - 1] and theirs_info.ctx[p - 1]);
        const at_ok = (p == base.lines.len) or (p < ours_info.ctx.len and ours_info.ctx[p] and theirs_info.ctx[p]);
        if (no_insert_o and no_insert_t and before_ok and at_ok) {
            try edges.append(allocator, p);
        }
    }
    try edges.append(allocator, base.lines.len);

    // Dedupe (edges are non-decreasing).
    var uniq: std.ArrayList(usize) = .empty;
    defer uniq.deinit(allocator);
    var last: ?usize = null;
    for (edges.items) |p| {
        if (last) |l| {
            if (l == p) continue;
        }
        try uniq.append(allocator, p);
        last = p;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var conflict = false;

    var i: usize = 0;
    while (i + 1 < uniq.items.len) : (i += 1) {
        const lo = uniq.items[i];
        const hi = uniq.items[i + 1];

        const base_view = base.lines[lo..hi];
        const ours_view = try renderSide(allocator, base.lines, &ours_info, lo, hi);
        defer allocator.free(ours_view);
        const theirs_view = try renderSide(allocator, base.lines, &theirs_info, lo, hi);
        defer allocator.free(theirs_view);

        var chosen: []const []const u8 = undefined;
        if (linesEqual(ours_view, base_view) and linesEqual(theirs_view, base_view)) {
            chosen = base_view;
        } else if (linesEqual(ours_view, base_view)) {
            chosen = theirs_view; // only theirs changed
        } else if (linesEqual(theirs_view, base_view)) {
            chosen = ours_view; // only ours changed
        } else if (linesEqual(ours_view, theirs_view)) {
            chosen = ours_view; // identical change on both sides
        } else {
            // Real conflict: emit markers.
            conflict = true;
            try out.appendSlice(allocator, "<<<<<<< HEAD\n");
            try appendLines(&out, allocator, ours_view);
            try out.appendSlice(allocator, "=======\n");
            try appendLines(&out, allocator, theirs_view);
            try out.appendSlice(allocator, ">>>>>>> ");
            try out.appendSlice(allocator, theirs_label);
            try out.append(allocator, '\n');
            continue;
        }

        try appendLines(&out, allocator, chosen);
    }

    // Preserve a trailing newline when the inputs had one.
    if (ours.trailing_newline or theirs.trailing_newline or base.trailing_newline) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
    }

    return .{ .content = try out.toOwnedSlice(allocator), .conflict = conflict };
}

fn appendLines(out: *std.ArrayList(u8), allocator: std.mem.Allocator, lines: []const []const u8) !void {
    for (lines) |line| {
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
}

// ============================================================================
// Merge base
// ============================================================================

/// Nearest common ancestor of two commits (BFS from `theirs` through the
/// ancestors of `ours`). Returns null for unrelated histories.
pub fn findMergeBase(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage_mod.StorageBackend,
    ours: [20]u8,
    theirs: [20]u8,
) ?[20]u8 {
    var ancestors: std.AutoHashMap([20]u8, void) = .init(allocator);
    defer ancestors.deinit();

    var queue: std.ArrayList([20]u8) = .empty;
    defer queue.deinit(allocator);
    queue.append(allocator, ours) catch return null;

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const sha = queue.items[qi];
        if (ancestors.contains(sha)) continue;
        ancestors.put(sha, {}) catch continue;
        const obj = store.read(allocator, io, sha) catch continue;
        defer obj.deinit(allocator);
        const commit = switch (obj) {
            .commit => |c| c,
            else => continue,
        };
        for (commit.parents) |p| queue.append(allocator, p) catch {};
    }

    var seen: std.AutoHashMap([20]u8, void) = .init(allocator);
    defer seen.deinit();
    queue.clearRetainingCapacity();
    queue.append(allocator, theirs) catch return null;

    qi = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const sha = queue.items[qi];
        if (ancestors.contains(sha)) return sha;
        if (seen.contains(sha)) continue;
        seen.put(sha, {}) catch continue;
        const obj = store.read(allocator, io, sha) catch continue;
        defer obj.deinit(allocator);
        const commit = switch (obj) {
            .commit => |c| c,
            else => continue,
        };
        for (commit.parents) |p| queue.append(allocator, p) catch {};
    }
    return null;
}

// ============================================================================
// Tree-level 3-way merge
// ============================================================================

pub const MergedEntry = struct {
    path: []const u8, // owned by the result
    mode: u32,
    sha: [20]u8, // blob already written to the store
    conflict: bool,
    /// Conflict-marker text to place in the working tree (owned), if any.
    marker_content: ?[]const u8,
};

pub const TreeMergeResult = struct {
    entries: []MergedEntry,

    pub fn deinit(self: TreeMergeResult, allocator: std.mem.Allocator) void {
        for (self.entries) |e| {
            allocator.free(e.path);
            if (e.marker_content) |m| allocator.free(m);
        }
        allocator.free(self.entries);
    }
};

/// 3-way merge of two commit trees. Every path of the union is resolved with
/// the standard add/delete/modify rules; files changed on both sides go
/// through the line-level diff3 merge.
pub fn mergeCommits(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage_mod.StorageBackend,
    ours_sha: [20]u8,
    theirs_sha: [20]u8,
    theirs_label: []const u8,
) !TreeMergeResult {
    const ours_commit = switch (try readCommit(allocator, io, store, ours_sha)) {
        .commit => |c| c,
        else => return error.NotACommit,
    };
    const theirs_commit = switch (try readCommit(allocator, io, store, theirs_sha)) {
        .commit => |c| c,
        else => return error.NotACommit,
    };

    const base_sha = findMergeBase(allocator, io, store, ours_sha, theirs_sha);

    var base_map: checkout.FileMap = .init(allocator);
    defer checkout.freeMap(allocator, &base_map);
    if (base_sha) |bsha| {
        const bcommit = switch (try readCommit(allocator, io, store, bsha)) {
            .commit => |c| c,
            else => return error.NotACommit,
        };
        try checkout.flattenTree(allocator, io, store, bcommit.tree, "", &base_map);
    }

    var ours_map: checkout.FileMap = .init(allocator);
    defer checkout.freeMap(allocator, &ours_map);
    try checkout.flattenTree(allocator, io, store, ours_commit.tree, "", &ours_map);

    var theirs_map: checkout.FileMap = .init(allocator);
    defer checkout.freeMap(allocator, &theirs_map);
    try checkout.flattenTree(allocator, io, store, theirs_commit.tree, "", &theirs_map);

    // Union of paths (deterministic order: ours first, then theirs-only).
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    {
        var seen: std.StringHashMap(void) = .init(allocator);
        defer seen.deinit();
        var it = ours_map.keyIterator();
        while (it.next()) |k| {
            try seen.put(k.*, {});
            try paths.append(allocator, k.*);
        }
        it = theirs_map.keyIterator();
        while (it.next()) |k| {
            if (seen.contains(k.*)) continue;
            try paths.append(allocator, k.*);
        }
    }

    var results: std.ArrayList(MergedEntry) = .empty;
    errdefer {
        for (results.items) |e| {
            allocator.free(e.path);
            if (e.marker_content) |m| allocator.free(m);
        }
        results.deinit(allocator);
    }

    for (paths.items) |path| {
        const o = ours_map.get(path);
        const t = theirs_map.get(path);
        const b = base_map.get(path);

        var final_sha: ?[20]u8 = null;
        var conflict = false;
        var markers: ?[]const u8 = null;
        var mode: u32 = 0o100644;
        if (o) |e| mode = e.mode else if (t) |e| mode = e.mode;

        if (t == null) {
            // Theirs does not have this file.
            if (b == null) {
                // Added by ours only (or base unknown) -> keep ours.
                final_sha = if (o) |e| e.sha else null;
            } else if (o == null or std.mem.eql(u8, &o.?.sha, &b.?.sha)) {
                // Ours unchanged (or also deleted) -> accept deletion.
                final_sha = null;
            } else {
                // Ours modified, theirs deleted -> conflict, keep ours.
                conflict = true;
                final_sha = o.?.sha;
            }
        } else if (o == null) {
            // Ours does not have this file.
            if (b == null) {
                final_sha = t.?.sha; // added by theirs only
            } else if (std.mem.eql(u8, &t.?.sha, &b.?.sha)) {
                final_sha = null; // theirs unchanged -> deletion stands
            } else {
                // Ours deleted, theirs modified -> conflict, keep theirs.
                conflict = true;
                final_sha = t.?.sha;
            }
        } else {
            // Present on both sides.
            if (std.mem.eql(u8, &o.?.sha, &t.?.sha)) {
                final_sha = o.?.sha;
            } else if (b == null) {
                // Both added, different content -> 3-way with empty base.
                const merged = try mergeText(allocator, io, store, null, o.?.sha, t.?.sha, theirs_label);
                defer if (merged.content) |c| allocator.free(c);
                if (merged.conflict or true) {
                    conflict = merged.conflict;
                    if (merged.conflict) markers = try allocator.dupe(u8, merged.content orelse "");
                }
                final_sha = if (merged.content) |c|
                    try store.write(allocator, io, .{ .blob = .{ .content = c } })
                else
                    o.?.sha;
            } else if (std.mem.eql(u8, &o.?.sha, &b.?.sha)) {
                final_sha = t.?.sha; // only theirs changed
            } else if (std.mem.eql(u8, &t.?.sha, &b.?.sha)) {
                final_sha = o.?.sha; // only ours changed
            } else {
                // Both changed -> content-level merge.
                const merged = try mergeText(allocator, io, store, b.?.sha, o.?.sha, t.?.sha, theirs_label);
                defer if (merged.content) |c| allocator.free(c);
                conflict = merged.conflict;
                if (merged.conflict) {
                    markers = try allocator.dupe(u8, merged.content orelse "");
                    final_sha = o.?.sha; // index keeps ours until resolved
                } else {
                    final_sha = if (merged.content) |c|
                        try store.write(allocator, io, .{ .blob = .{ .content = c } })
                    else
                        o.?.sha;
                }
            }
        }

        if (final_sha) |sha| {
            try results.append(allocator, .{
                .path = try allocator.dupe(u8, path),
                .mode = mode,
                .sha = sha,
                .conflict = conflict,
                .marker_content = markers,
            });
        } else if (markers) |m| {
            allocator.free(m); // deleted + markers shouldn't happen; be safe
        }
    }

    return .{ .entries = try results.toOwnedSlice(allocator) };
}

fn readCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage_mod.StorageBackend,
    sha: [20]u8,
) !object.GitObject {
    return store.read(allocator, io, sha);
}

const Merged = struct {
    content: ?[]u8,
    conflict: bool,
};

fn mergeText(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage_mod.StorageBackend,
    base_sha: ?[20]u8,
    ours_sha: [20]u8,
    theirs_sha: [20]u8,
    theirs_label: []const u8,
) !Merged {
    const base_c: []const u8 = if (base_sha) |s| checkout.readBlob(allocator, io, store, s) orelse "" else "";
    defer allocator.free(base_c);
    const ours_c = checkout.readBlob(allocator, io, store, ours_sha) orelse return .{ .content = null, .conflict = false };
    defer allocator.free(ours_c);
    const theirs_c = checkout.readBlob(allocator, io, store, theirs_sha) orelse return .{ .content = null, .conflict = false };
    defer allocator.free(theirs_c);

    // mergeLines always returns freshly allocated content, so the inputs are
    // safe to release here.
    const merged = try mergeLines(allocator, base_c, ours_c, theirs_c, theirs_label);
    return .{ .content = merged.content, .conflict = merged.conflict };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "mergeLines: only ours changed" {
    const r = try mergeLines(testing.allocator, "a\nb\nc\n", "a\nB\nc\n", "a\nb\nc\n", "feat");
    defer r.deinit(testing.allocator);
    try testing.expect(!r.conflict);
    try testing.expectEqualStrings("a\nB\nc\n", r.content);
}

test "mergeLines: only theirs changed" {
    const r = try mergeLines(testing.allocator, "a\nb\nc\n", "a\nb\nc\n", "a\nX\nc\n", "feat");
    defer r.deinit(testing.allocator);
    try testing.expect(!r.conflict);
    try testing.expectEqualStrings("a\nX\nc\n", r.content);
}

test "mergeLines: changes on different lines auto-merge" {
    const r = try mergeLines(
        testing.allocator,
        "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n",
        "ONE\n2\n3\n4\n5\n6\n7\n8\n9\n10\n",
        "1\n2\n3\n4\n5\n6\n7\n8\n9\nTEN\n",
        "feat",
    );
    defer r.deinit(testing.allocator);
    try testing.expect(!r.conflict);
    try testing.expectEqualStrings("ONE\n2\n3\n4\n5\n6\n7\n8\n9\nTEN\n", r.content);
}

test "mergeLines: same change on both sides" {
    const r = try mergeLines(testing.allocator, "a\n", "a1\n", "a1\n", "feat");
    defer r.deinit(testing.allocator);
    try testing.expect(!r.conflict);
    try testing.expectEqualStrings("a1\n", r.content);
}

test "mergeLines: conflicting change emits markers" {
    const r = try mergeLines(testing.allocator, "a\n", "ours\n", "theirs\n", "feat");
    defer r.deinit(testing.allocator);
    try testing.expect(r.conflict);
    try testing.expect(std.mem.indexOf(u8, r.content, "<<<<<<< HEAD") != null);
    try testing.expect(std.mem.indexOf(u8, r.content, "ours") != null);
    try testing.expect(std.mem.indexOf(u8, r.content, "theirs") != null);
    try testing.expect(std.mem.indexOf(u8, r.content, ">>>>>>> feat") != null);
}

test "mergeLines: insertion by one side only" {
    const r = try mergeLines(testing.allocator, "a\n", "X\na\n", "a\n", "feat");
    defer r.deinit(testing.allocator);
    try testing.expect(!r.conflict);
    try testing.expectEqualStrings("X\na\n", r.content);
}

test "mergeLines: deletion by one side only" {
    const r = try mergeLines(testing.allocator, "a\nb\n", "a\nb\n", "a\n", "feat");
    defer r.deinit(testing.allocator);
    try testing.expect(!r.conflict);
    try testing.expectEqualStrings("a\n", r.content);
}

test "mergeLines: both added different files (no base)" {
    const r = try mergeLines(testing.allocator, "", "mine\n", "yours\n", "feat");
    defer r.deinit(testing.allocator);
    try testing.expect(r.conflict);
}

test "mergeLines: empty on both sides" {
    const r = try mergeLines(testing.allocator, "", "", "", "feat");
    defer r.deinit(testing.allocator);
    try testing.expect(!r.conflict);
    try testing.expectEqualStrings("", r.content);
}

test "findMergeBase: simple fork" {
    const io = testing.io;
    const allocator = testing.allocator;

    const root = "zig-cache/gitz_tree_merge_test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    const store = storage_mod.StorageBackend.looseBackend(root);

    const tree = try store.write(allocator, io, .{ .tree = .{ .entries = &.{} } });
    const person = object.Person{ .name = "T", .email = "t@t", .timestamp = 0, .timezone = "+0000" };

    const base = try store.write(allocator, io, .{ .commit = .{
        .tree = tree,
        .parents = &.{},
        .author = person,
        .committer = person,
        .message = "base",
    } });
    const ours = try store.write(allocator, io, .{ .commit = .{
        .tree = tree,
        .parents = &.{base},
        .author = person,
        .committer = person,
        .message = "ours",
    } });
    const theirs = try store.write(allocator, io, .{ .commit = .{
        .tree = tree,
        .parents = &.{base},
        .author = person,
        .committer = person,
        .message = "theirs",
    } });

    const mb = findMergeBase(allocator, io, store, ours, theirs);
    try testing.expect(mb != null);
    try testing.expect(std.mem.eql(u8, &mb.?, &base));
}
