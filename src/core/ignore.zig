const std = @import("std");
const testing = std.testing;

const Allocator = std.mem.Allocator;

/// A single ignore rule parsed from .gitignore
pub const IgnoreRule = struct {
    pattern: []const u8,
    negated: bool = false,
    directory_only: bool = false,
    anchored: bool = false,
};

/// Set of ignore rules
pub const IgnoreRuleSet = struct {
    rules: std.ArrayList(IgnoreRule),
    allocator: Allocator,

    pub fn init(allocator: Allocator) IgnoreRuleSet {
        return .{
            .rules = .{ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IgnoreRuleSet) void {
        for (self.rules.items) |rule| {
            self.allocator.free(rule.pattern);
        }
        self.rules.deinit(self.allocator);
    }

    /// Parse a .gitignore file content
    pub fn parse(allocator: Allocator, content: []const u8) IgnoreRuleSet {
        var ruleset = IgnoreRuleSet.init(allocator);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &[_]u8{ '\r', ' ' });
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            var pattern = trimmed;
            var negated = false;
            var directory_only = false;

            if (pattern[0] == '!') {
                negated = true;
                pattern = pattern[1..];
            }

            if (pattern.len > 0 and pattern[pattern.len - 1] == '/') {
                directory_only = true;
                pattern = pattern[0 .. pattern.len - 1];
            }

            const anchored = pattern[0] == '/' or std.mem.indexOf(u8, pattern, "/") != null;

            if (anchored and pattern.len > 0 and pattern[0] == '/') {
                pattern = pattern[1..];
            }

            ruleset.rules.append(ruleset.allocator, .{
                .pattern = allocator.dupe(u8, pattern) catch continue,
                .negated = negated,
                .directory_only = directory_only,
                .anchored = anchored,
            }) catch continue;
        }

        return ruleset;
    }

    /// Check if a path should be ignored. Last matching rule wins.
    pub fn isIgnored(self: IgnoreRuleSet, path: []const u8, is_dir: bool) bool {
        var result = false;

        for (self.rules.items) |rule| {
            if (rule.directory_only and !is_dir) continue;
            if (matchIgnorePattern(rule.pattern, path, rule.anchored)) {
                result = !rule.negated;
            }
        }

        return result;
    }
};

/// Manages .gitignore files at multiple directory levels
pub const IgnoreStack = struct {
    rulesets: std.ArrayList(IgnoreRuleSet),
    allocator: Allocator,

    pub fn init(allocator: Allocator) IgnoreStack {
        return .{
            .rulesets = .{ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IgnoreStack) void {
        for (self.rulesets.items) |*ruleset| {
            ruleset.deinit();
        }
        self.rulesets.deinit(self.allocator);
    }

    /// Load ignore rules from a .gitignore file using io
    pub fn loadFile(self: *IgnoreStack, io: std.Io, path: []const u8) !void {
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .unlimited) catch return;
        defer self.allocator.free(content);

        const ruleset = IgnoreRuleSet.parse(self.allocator, content);
        try self.rulesets.append(self.allocator, ruleset);
    }

    /// Check if a path should be ignored
    pub fn isIgnored(self: IgnoreStack, path: []const u8, is_dir: bool) bool {
        for (self.rulesets.items) |ruleset| {
            if (ruleset.isIgnored(path, is_dir)) {
                return true;
            }
        }
        return false;
    }
};

/// Match a gitignore pattern against a path
fn matchIgnorePattern(pattern: []const u8, path: []const u8, anchored: bool) bool {
    if (anchored) {
        return matchGlob(pattern, path);
    }

    if (matchGlob(pattern, path)) return true;

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, path, pos, "/")) |slash_pos| {
        pos = slash_pos + 1;
        if (matchGlob(pattern, path[pos..])) return true;
    }

    return false;
}

/// Simple glob matching for gitignore patterns (supports * and ?)
fn matchGlob(pattern: []const u8, text: []const u8) bool {
    if (std.mem.indexOf(u8, pattern, "**")) |ds_pos| {
        const before = pattern[0..ds_pos];
        // Skip leading slash after **
        var after = pattern[ds_pos + 2 ..];
        if (after.len > 0 and after[0] == '/') {
            after = after[1..];
        }

        if (before.len == 0 or matchGlobSimple(before, text[0..@min(before.len, text.len)])) {
            if (after.len == 0) return true;
            // Try matching after at every position in text
            if (matchGlobSimple(after, text)) return true;
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                if (text[i] == '/') {
                    if (matchGlobSimple(after, text[i + 1 ..])) return true;
                }
            }
        }
        return false;
    }

    return matchGlobSimple(pattern, text);
}

/// Simple single-segment glob match (no **)
fn matchGlobSimple(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: usize = 0;
    var star_ti: usize = 0;
    var matched = false;

    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == text[ti])) {
            pi += 1;
            ti += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
            matched = true;
        } else if (matched) {
            pi = star_pi + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}

    return pi == pattern.len;
}

// ============================================================================
// Tests
// ============================================================================

test "ignore simple pattern" {
    var ruleset = IgnoreRuleSet.parse(testing.allocator, "*.o\n");
    defer ruleset.deinit();

    try testing.expect(ruleset.isIgnored("foo.o", false));
    try testing.expect(!ruleset.isIgnored("foo.c", false));
}

test "ignore directory pattern" {
    var ruleset = IgnoreRuleSet.parse(testing.allocator, "build/\n");
    defer ruleset.deinit();

    try testing.expect(ruleset.isIgnored("build", true));
    try testing.expect(!ruleset.isIgnored("build", false));
    try testing.expect(!ruleset.isIgnored("build.txt", false));
}

test "ignore negation" {
    var ruleset = IgnoreRuleSet.parse(testing.allocator, "*.log\n!important.log\n");
    defer ruleset.deinit();

    try testing.expect(ruleset.isIgnored("debug.log", false));
    try testing.expect(!ruleset.isIgnored("important.log", false));
}

test "ignore anchored pattern" {
    var ruleset = IgnoreRuleSet.parse(testing.allocator, "/foo\n");
    defer ruleset.deinit();

    try testing.expect(ruleset.isIgnored("foo", false));
    try testing.expect(!ruleset.isIgnored("bar/foo", false));
}

test "ignore unanchored matches subdirectories" {
    var ruleset = IgnoreRuleSet.parse(testing.allocator, "*.o\n");
    defer ruleset.deinit();

    try testing.expect(ruleset.isIgnored("dir/foo.o", false));
}

test "ignore double star" {
    var ruleset = IgnoreRuleSet.parse(testing.allocator, "**/temp\n");
    defer ruleset.deinit();

    try testing.expect(ruleset.isIgnored("temp", false));
    try testing.expect(ruleset.isIgnored("a/temp", false));
    try testing.expect(ruleset.isIgnored("a/b/temp", false));
}

test "ignore comments and blank lines" {
    var ruleset = IgnoreRuleSet.parse(testing.allocator, "# comment\n\n*.o\n");
    defer ruleset.deinit();

    try testing.expectEqual(@as(usize, 1), ruleset.rules.items.len);
}

test "ignore last rule wins" {
    var ruleset = IgnoreRuleSet.parse(testing.allocator, "*.log\n!important.log\n*.log\n");
    defer ruleset.deinit();

    try testing.expect(ruleset.isIgnored("important.log", false));
}

test "ignore wildcard" {
    var ruleset = IgnoreRuleSet.parse(testing.allocator, "*.log\n");
    defer ruleset.deinit();

    try testing.expect(ruleset.isIgnored("a.log", false));
    try testing.expect(ruleset.isIgnored("b/c.log", false));
    try testing.expect(!ruleset.isIgnored("log.txt", false));
}

test "ignore nested path" {
    var ruleset = IgnoreRuleSet.parse(testing.allocator, "docs/*.pdf\n");
    defer ruleset.deinit();

    try testing.expect(ruleset.isIgnored("docs/file.pdf", false));
    try testing.expect(!ruleset.isIgnored("src/file.pdf", false));
}

test "ignore complex pattern" {
    var ruleset = IgnoreRuleSet.parse(testing.allocator, "*.o\n*.a\n*.so\n*.dylib\n.DS_Store\nnode_modules/\n");
    defer ruleset.deinit();

    try testing.expect(ruleset.isIgnored("foo.o", false));
    try testing.expect(ruleset.isIgnored("libfoo.a", false));
    try testing.expect(ruleset.isIgnored("libfoo.so", false));
    try testing.expect(ruleset.isIgnored("libfoo.dylib", false));
    try testing.expect(ruleset.isIgnored(".DS_Store", false));
    try testing.expect(ruleset.isIgnored("node_modules", true));
    try testing.expect(!ruleset.isIgnored("node_modules/file.js", false));
}
