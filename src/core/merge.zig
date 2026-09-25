const std = @import("std");

const Allocator = std.mem.Allocator;

const testing = std.testing;

/// Result of a merge operation
pub const MergeResult = struct {
    status: MergeStatus,
    conflicts: ?[]const Conflict = null,
    merged_tree_sha: ?[20]u8 = null,
};

pub const MergeStatus = enum {
    fast_forward,
    normal,
    conflicted,
    already_up_to_date,
};

/// A merge conflict
pub const Conflict = struct {
    path: []const u8,
    ours: ?[]const u8,
    theirs: ?[]const u8,
    base: ?[]const u8,
};

/// 3-way merge engine
pub const MergeEngine = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) MergeEngine {
        return .{ .allocator = allocator };
    }

    /// Find the common ancestor of two commits
    /// Simplified: walks parent chain of both to find intersection
    pub fn findMergeBase(
        self: MergeEngine,
        history_a: []const [20]u8,
        history_b: []const [20]u8,
    ) ?[20]u8 {
        _ = self;
        for (history_a) |sha_a| {
            for (history_b) |sha_b| {
                if (std.mem.eql(u8, &sha_a, &sha_b)) {
                    return sha_a;
                }
            }
        }
        return null;
    }

    /// Merge two file contents using 3-way merge algorithm
    /// Returns the merged content or conflicts
    pub fn mergeFileContents(
        self: MergeEngine,
        base: ?[]const u8,
        ours: []const u8,
        theirs: []const u8,
    ) !MergeFileResult {
        // If no base, it's a new file from both sides
        if (base == null) {
            if (std.mem.eql(u8, ours, theirs)) {
                return .{
                    .merged = ours,
                    .conflicts = &.{},
                    .allocator = self.allocator,
                };
            }
            return .{
                .merged = null,
                .conflicts = try self.allocator.dupe(Conflict, &.{.{
                    .path = "",
                    .ours = ours,
                    .theirs = theirs,
                    .base = null,
                }}),
                .allocator = self.allocator,
            };
        }

        const base_content = base.?;

        // If ours equals base, take theirs (theirs changed)
        if (std.mem.eql(u8, ours, base_content)) {
            return .{
                .merged = theirs,
                .conflicts = &.{},
                .allocator = self.allocator,
            };
        }

        // If theirs equals base, take ours (we changed)
        if (std.mem.eql(u8, theirs, base_content)) {
            return .{
                .merged = ours,
                .conflicts = &.{},
                .allocator = self.allocator,
            };
        }

        // If both changed but to the same content
        if (std.mem.eql(u8, ours, theirs)) {
            return .{
                .merged = ours,
                .conflicts = &.{},
                .allocator = self.allocator,
            };
        }

        // Both changed differently → conflict. The conflict must be owned: a
        // pointer to an array literal containing runtime values may point at
        // this function's stack frame after it returns (and fails in
        // ReleaseFast builds).
        return .{
            .merged = null,
            .conflicts = try self.allocator.dupe(Conflict, &.{.{
                .path = "",
                .ours = ours,
                .theirs = theirs,
                .base = base_content,
            }}),
            .allocator = self.allocator,
        };
    }

    /// Check if a merge is fast-forwardable
    /// (current is ancestor of other)
    pub fn isFastForward(
        self: MergeEngine,
        current_history: []const [20]u8,
        target: [20]u8,
    ) bool {
        _ = self;
        for (current_history) |sha| {
            if (std.mem.eql(u8, &sha, &target)) {
                return true;
            }
        }
        return false;
    }
};

pub const MergeFileResult = struct {
    merged: ?[]const u8,
    conflicts: []const Conflict,
    allocator: Allocator,

    pub fn deinit(self: MergeFileResult) void {
        if (self.conflicts.len != 0) {
            self.allocator.free(@constCast(self.conflicts));
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "merge base found" {
    const engine = MergeEngine.init(testing.allocator);
    const history_a = [_][20]u8{
        [_]u8{0x03} ** 20,
        [_]u8{0x02} ** 20,
        [_]u8{0x01} ** 20,
    };
    const history_b = [_][20]u8{
        [_]u8{0x05} ** 20,
        [_]u8{0x04} ** 20,
        [_]u8{0x02} ** 20,
        [_]u8{0x01} ** 20,
    };

    const base = engine.findMergeBase(&history_a, &history_b);
    try testing.expect(base != null);
    const expected: [20]u8 = .{0x02} ** 20;
    try testing.expectEqual(expected, base.?);
}

test "merge base not found" {
    const engine = MergeEngine.init(testing.allocator);
    const history_a = [_][20]u8{ [_]u8{0x01} ** 20, [_]u8{0x02} ** 20 };
    const history_b = [_][20]u8{ [_]u8{0x03} ** 20, [_]u8{0x04} ** 20 };

    const base = engine.findMergeBase(&history_a, &history_b);
    try testing.expectEqual(@as(?[20]u8, null), base);
}

test "merge file - ours changed" {
    const engine = MergeEngine.init(testing.allocator);
    const result = try engine.mergeFileContents("base", "ours", "base");
    defer result.deinit();
    try testing.expect(result.conflicts.len == 0);
    try testing.expect(result.merged != null);
    try testing.expectEqualStrings("ours", result.merged.?);
}

test "merge file - theirs changed" {
    const engine = MergeEngine.init(testing.allocator);
    const result = try engine.mergeFileContents("base", "base", "theirs");
    defer result.deinit();
    try testing.expect(result.conflicts.len == 0);
    try testing.expect(result.merged != null);
    try testing.expectEqualStrings("theirs", result.merged.?);
}

test "merge file - same change" {
    const engine = MergeEngine.init(testing.allocator);
    const result = try engine.mergeFileContents("base", "same", "same");
    defer result.deinit();
    try testing.expect(result.conflicts.len == 0);
    try testing.expect(result.merged != null);
    try testing.expectEqualStrings("same", result.merged.?);
}

test "merge file - conflict" {
    const engine = MergeEngine.init(testing.allocator);
    const result = try engine.mergeFileContents("base", "ours", "theirs");
    defer result.deinit();
    try testing.expect(result.conflicts.len == 1);
    try testing.expect(result.merged == null);
    try testing.expectEqualStrings("ours", result.conflicts[0].ours.?);
    try testing.expectEqualStrings("theirs", result.conflicts[0].theirs.?);
}

test "merge file - no base" {
    const engine = MergeEngine.init(testing.allocator);
    const result = try engine.mergeFileContents(null, "content", "content");
    defer result.deinit();
    try testing.expect(result.conflicts.len == 0);
    try testing.expectEqualStrings("content", result.merged.?);
}

test "merge file - no base conflict" {
    const engine = MergeEngine.init(testing.allocator);
    const result = try engine.mergeFileContents(null, "ours", "theirs");
    defer result.deinit();
    try testing.expect(result.conflicts.len == 1);
    try testing.expect(result.merged == null);
}

test "is fast forward" {
    const engine = MergeEngine.init(testing.allocator);
    const history = [_][20]u8{
        [_]u8{0x03} ** 20,
        [_]u8{0x02} ** 20,
        [_]u8{0x01} ** 20,
    };

    try testing.expect(engine.isFastForward(&history, [_]u8{0x02} ** 20));
    try testing.expect(engine.isFastForward(&history, [_]u8{0x01} ** 20));
    try testing.expect(!engine.isFastForward(&history, [_]u8{0x04} ** 20));
}
