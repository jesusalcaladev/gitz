const std = @import("std");
const testing = std.testing;

const Allocator = std.mem.Allocator;

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
    ) MergeFileResult {
        _ = self;
        // If no base, it's a new file from both sides
        if (base == null) {
            if (std.mem.eql(u8, ours, theirs)) {
                return .{ .merged = ours, .conflicts = &.{} };
            }
            return .{
                .merged = null,
                .conflicts = &.{
                    Conflict{
                        .path = "",
                        .ours = ours,
                        .theirs = theirs,
                        .base = null,
                    },
                },
            };
        }

        const base_content = base.?;

        // If ours equals base, take theirs (theirs changed)
        if (std.mem.eql(u8, ours, base_content)) {
            return .{ .merged = theirs, .conflicts = &.{} };
        }

        // If theirs equals base, take ours (we changed)
        if (std.mem.eql(u8, theirs, base_content)) {
            return .{ .merged = ours, .conflicts = &.{} };
        }

        // If both changed but to the same content
        if (std.mem.eql(u8, ours, theirs)) {
            return .{ .merged = ours, .conflicts = &.{} };
        }

        // Both changed differently → conflict
        return .{
            .merged = null,
            .conflicts = &.{
                Conflict{
                    .path = "",
                    .ours = ours,
                    .theirs = theirs,
                    .base = base_content,
                },
            },
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
};

// ============================================================================
// Tests
// ============================================================================

test "merge base found" {
    const engine = MergeEngine.init(testing.allocator);
    const history_a = [_][20]u8{
        (@as([20]u8, @splat(0x03))),
        (@as([20]u8, @splat(0x02))),
        (@as([20]u8, @splat(0x01))),
    };
    const history_b = [_][20]u8{
        (@as([20]u8, @splat(0x05))),
        (@as([20]u8, @splat(0x04))),
        (@as([20]u8, @splat(0x02))),
        (@as([20]u8, @splat(0x01))),
    };

    const base = engine.findMergeBase(&history_a, &history_b);
    try testing.expect(base != null);
    const expected: [20]u8 = @splat(0x02);
    try testing.expectEqual(expected, base.?);
}

test "merge base not found" {
    const engine = MergeEngine.init(testing.allocator);
    const history_a = [_][20]u8{ (@as([20]u8, @splat(0x01))), (@as([20]u8, @splat(0x02))) };
    const history_b = [_][20]u8{ (@as([20]u8, @splat(0x03))), (@as([20]u8, @splat(0x04))) };

    const base = engine.findMergeBase(&history_a, &history_b);
    try testing.expectEqual(@as(?[20]u8, null), base);
}

test "merge file - ours changed" {
    const engine = MergeEngine.init(testing.allocator);
    const result = engine.mergeFileContents("base", "ours", "base");
    try testing.expect(result.conflicts.len == 0);
    try testing.expect(result.merged != null);
    try testing.expectEqualStrings("ours", result.merged.?);
}

test "merge file - theirs changed" {
    const engine = MergeEngine.init(testing.allocator);
    const result = engine.mergeFileContents("base", "base", "theirs");
    try testing.expect(result.conflicts.len == 0);
    try testing.expect(result.merged != null);
    try testing.expectEqualStrings("theirs", result.merged.?);
}

test "merge file - same change" {
    const engine = MergeEngine.init(testing.allocator);
    const result = engine.mergeFileContents("base", "same", "same");
    try testing.expect(result.conflicts.len == 0);
    try testing.expect(result.merged != null);
    try testing.expectEqualStrings("same", result.merged.?);
}

test "merge file - conflict" {
    const engine = MergeEngine.init(testing.allocator);
    const result = engine.mergeFileContents("base", "ours", "theirs");
    try testing.expect(result.conflicts.len == 1);
    try testing.expect(result.merged == null);
    try testing.expectEqualStrings("ours", result.conflicts[0].ours.?);
    try testing.expectEqualStrings("theirs", result.conflicts[0].theirs.?);
}

test "merge file - no base" {
    const engine = MergeEngine.init(testing.allocator);
    const result = engine.mergeFileContents(null, "content", "content");
    try testing.expect(result.conflicts.len == 0);
    try testing.expectEqualStrings("content", result.merged.?);
}

test "merge file - no base conflict" {
    const engine = MergeEngine.init(testing.allocator);
    const result = engine.mergeFileContents(null, "ours", "theirs");
    try testing.expect(result.conflicts.len == 1);
    try testing.expect(result.merged == null);
}

test "is fast forward" {
    const engine = MergeEngine.init(testing.allocator);
    const history = [_][20]u8{
        (@as([20]u8, @splat(0x03))),
        (@as([20]u8, @splat(0x02))),
        (@as([20]u8, @splat(0x01))),
    };

    try testing.expect(engine.isFastForward(&history, (@as([20]u8, @splat(0x02)))));
    try testing.expect(engine.isFastForward(&history, (@as([20]u8, @splat(0x01)))));
    try testing.expect(!engine.isFastForward(&history, (@as([20]u8, @splat(0x04)))));
}
