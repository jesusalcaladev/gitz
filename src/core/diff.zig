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
        return try buildHunksWithContext(allocator, lines);
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
        return try buildHunksWithContext(allocator, lines);
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

    return try buildHunksWithContext(allocator, try result_lines.toOwnedSlice(allocator));
}

/// Split a flat list of DiffLines into hunks with surrounding context lines,
/// mirroring `git diff` output. Consecutive changes within 2×context lines
/// of each other are merged into a single hunk.
pub const CONTEXT_LINES: usize = 3;

pub fn buildHunksWithContext(allocator: Allocator, lines: []DiffLine) !Diff {
    if (lines.len == 0) return Diff{ .hunks = &.{} };

    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(allocator);

    var i: usize = 0;
    while (i < lines.len) {
        // Skip context-only prefix lines
        if (lines[i].type == .context) {
            i += 1;
            continue;
        }

        // Found a change at index i. Expand left/right by CONTEXT_LINES.
        const start = if (i > CONTEXT_LINES) i - CONTEXT_LINES else 0;

        // Find the end of this change group (scan forward for consecutive changes
        // separated by no more than 2*CONTEXT_LINES context lines).
        var end = i;
        var j = i;
        while (j < lines.len) {
            if (lines[j].type != .context) {
                end = j;
            } else {
                // Count consecutive context lines
                var ctx_count: usize = 0;
                var k = j;
                while (k < lines.len and lines[k].type == .context) : (k += 1) {
                    ctx_count += 1;
                }
                if (ctx_count > 2 * CONTEXT_LINES) break;
                end = j + ctx_count; // extend past the context block
                j = j + ctx_count;
                continue;
            }
            j += 1;
        }

        // Expand right by CONTEXT_LINES
        end = @min(end + CONTEXT_LINES + 1, lines.len);

        const hunk_lines = try allocator.dupe(DiffLine, lines[start..end]);

        // Compute hunk header (old_start, old_count, new_start, new_count)
        var old_start: u32 = 0;
        var new_start: u32 = 0;
        var old_count: u32 = 0;
        var new_count: u32 = 0;
        var first_old = true;
        var first_new = true;
        for (hunk_lines) |line| {
            switch (line.type) {
                .context => {
                    if (first_old) {
                        old_start = line.old_line orelse 0;
                        first_old = false;
                    }
                    if (first_new) {
                        new_start = line.new_line orelse 0;
                        first_new = false;
                    }
                    old_count += 1;
                    new_count += 1;
                },
                .added => {
                    if (first_new) {
                        new_start = line.new_line orelse 0;
                        first_new = false;
                    }
                    new_count += 1;
                },
                .deleted => {
                    if (first_old) {
                        old_start = line.old_line orelse 0;
                        first_old = false;
                    }
                    old_count += 1;
                },
            }
        }

        try hunks.append(allocator, .{
            .old_start = old_start,
            .old_count = old_count,
            .new_start = new_start,
            .new_count = new_count,
            .lines = hunk_lines,
        });

        i = end;
    }

    const result = Diff{ .hunks = try hunks.toOwnedSlice(allocator) };
    allocator.free(lines);
    return result;
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

test "diff hunk header format" {
    // Change in the middle should produce a hunk with correct old/new start+count
    const old = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };
    const new = [_][]const u8{ "1", "2", "3", "4", "X", "6", "7", "8", "9", "10" };
    const result = try myersDiff(testing.allocator, &old, &new);
    defer result.deinit(testing.allocator);
    try testing.expect(result.hunks.len == 1);
    const h = result.hunks[0];
    // The changed line is at position 5 (1-based), with 3 context lines on each side
    try testing.expect(h.old_start >= 1 and h.old_start <= 2);
    try testing.expect(h.new_start >= 1 and h.new_start <= 2);
    // Hunk should contain context + 1 delete + 1 add
    try testing.expect(h.lines.len >= 5); // at least ctx + del + add + ctx
}

test "diff two separate hunks" {
    // Changes far apart should produce two separate hunks
    const old = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15" };
    const new = [_][]const u8{ "X", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "Y" };
    const result = try myersDiff(testing.allocator, &old, &new);
    defer result.deinit(testing.allocator);
    // With 3 context lines, changes at line 1 and line 15 are >6 lines apart
    try testing.expect(result.hunks.len >= 2);
}
