const std = @import("std");
const testing = std.testing;

const Allocator = std.mem.Allocator;

pub const LineType = enum {
    context,
    added,
    deleted,
};

pub const DiffLine = struct {
    content: []const u8,
    old_line: ?u32 = null,
    new_line: ?u32 = null,
    type: LineType = .context,
};

pub const Hunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    lines: []DiffLine,
};

pub const Diff = struct {
    hunks: []Hunk,

    pub fn deinit(self: Diff, allocator: Allocator) void {
        for (self.hunks) |hunk| {
            allocator.free(hunk.lines);
        }
        allocator.free(self.hunks);
    }

    pub fn isEmpty(self: Diff) bool {
        return self.hunks.len == 0;
    }
};

/// Myers diff algorithm - simplified LCS-based implementation
pub fn myersDiff(allocator: Allocator, old_lines: []const []const u8, new_lines: []const []const u8) !Diff {
    const n = old_lines.len;
    const m = new_lines.len;

    if (n == 0 and m == 0) {
        return Diff{ .hunks = &.{} };
    }

    if (n == 0) {
        var lines = try allocator.alloc(DiffLine, m);
        for (new_lines, 0..) |line, i| {
            lines[i] = .{
                .content = line,
                .new_line = @intCast(i + 1),
                .type = .added,
            };
        }
        return Diff{
            .hunks = try allocator.dupe(Hunk, &.{Hunk{
                .old_start = 0,
                .old_count = 0,
                .new_start = 1,
                .new_count = @intCast(m),
                .lines = lines,
            }}),
        };
    }

    if (m == 0) {
        var lines = try allocator.alloc(DiffLine, n);
        for (old_lines, 0..) |line, i| {
            lines[i] = .{
                .content = line,
                .old_line = @intCast(i + 1),
                .type = .deleted,
            };
        }
        return Diff{
            .hunks = try allocator.dupe(Hunk, &.{Hunk{
                .old_start = 1,
                .old_count = @intCast(n),
                .new_start = 0,
                .new_count = 0,
                .lines = lines,
            }}),
        };
    }

    // Compute LCS using DP table
    var dp = try allocator.alloc([]u32, n + 1);
    defer allocator.free(dp);
    for (dp) |*row| {
        row.* = try allocator.alloc(u32, m + 1);
    }
    defer for (dp) |row| allocator.free(row);

    for (0..n + 1) |i| {
        @memset(dp[i], 0);
    }

    for (1..n + 1) |i| {
        for (1..m + 1) |j| {
            if (std.mem.eql(u8, old_lines[i - 1], new_lines[j - 1])) {
                dp[i][j] = dp[i - 1][j - 1] + 1;
            } else {
                dp[i][j] = @max(dp[i - 1][j], dp[i][j - 1]);
            }
        }
    }

    // If all lines match, no diff needed
    if (dp[n][m] == n and n == m) {
        return Diff{ .hunks = &.{} };
    }

    // Backtrack to build edit script
    var result_lines = std.ArrayList(DiffLine){ .items = &.{}, .capacity = 0 };
    defer result_lines.deinit(allocator);

    var i = n;
    var j = m;
    while (i > 0 or j > 0) {
        if (i > 0 and j > 0 and std.mem.eql(u8, old_lines[i - 1], new_lines[j - 1])) {
            try result_lines.append(allocator, .{
                .content = old_lines[i - 1],
                .old_line = @intCast(i),
                .new_line = @intCast(j),
                .type = .context,
            });
            i -= 1;
            j -= 1;
        } else if (j > 0 and (i == 0 or dp[i][j - 1] >= dp[i - 1][j])) {
            try result_lines.append(allocator, .{
                .content = new_lines[j - 1],
                .old_line = null,
                .new_line = @intCast(j),
                .type = .added,
            });
            j -= 1;
        } else {
            try result_lines.append(allocator, .{
                .content = old_lines[i - 1],
                .old_line = @intCast(i),
                .new_line = null,
                .type = .deleted,
            });
            i -= 1;
        }
    }

    // Reverse (we built it backwards)
    std.mem.reverse(DiffLine, result_lines.items);

    if (result_lines.items.len == 0) {
        return Diff{ .hunks = &.{} };
    }

    return Diff{
        .hunks = try allocator.dupe(Hunk, &.{Hunk{
            .old_start = 1,
            .old_count = @intCast(n),
            .new_start = 1,
            .new_count = @intCast(m),
            .lines = try result_lines.toOwnedSlice(allocator),
        }}),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "diff no changes" {
    const old = [_][]const u8{ "line1", "line2", "line3" };
    const new = [_][]const u8{ "line1", "line2", "line3" };
    const result = try myersDiff(testing.allocator, &old, &new);
    defer result.deinit(testing.allocator);
    try testing.expect(result.isEmpty());
}

test "diff add line" {
    const old = [_][]const u8{"line1"};
    const new = [_][]const u8{ "line1", "line2" };
    const result = try myersDiff(testing.allocator, &old, &new);
    defer result.deinit(testing.allocator);
    try testing.expect(result.hunks.len > 0);
}

test "diff remove line" {
    const old = [_][]const u8{ "line1", "line2" };
    const new = [_][]const u8{"line1"};
    const result = try myersDiff(testing.allocator, &old, &new);
    defer result.deinit(testing.allocator);
    try testing.expect(result.hunks.len > 0);
}

test "diff both empty" {
    const old = [_][]const u8{};
    const new = [_][]const u8{};
    const result = try myersDiff(testing.allocator, &old, &new);
    defer result.deinit(testing.allocator);
    try testing.expect(result.isEmpty());
}

test "diff empty to content" {
    const old = [_][]const u8{};
    const new = [_][]const u8{ "a", "b", "c" };
    const result = try myersDiff(testing.allocator, &old, &new);
    defer result.deinit(testing.allocator);
    try testing.expect(result.hunks.len > 0);
}

test "diff content to empty" {
    const old = [_][]const u8{ "a", "b", "c" };
    const new = [_][]const u8{};
    const result = try myersDiff(testing.allocator, &old, &new);
    defer result.deinit(testing.allocator);
    try testing.expect(result.hunks.len > 0);
}

test "diff replace middle" {
    const old = [_][]const u8{ "a", "b", "c" };
    const new = [_][]const u8{ "a", "x", "c" };
    const result = try myersDiff(testing.allocator, &old, &new);
    defer result.deinit(testing.allocator);
    try testing.expect(result.hunks.len > 0);
}
