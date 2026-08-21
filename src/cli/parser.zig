const std = @import("std");

/// Simple argument parser for CLI commands
pub const ArgParser = struct {
    args: []const []const u8,
    position: usize,

    pub fn init(args: []const []const u8) ArgParser {
        return .{
            .args = args,
            .position = 0,
        };
    }

    /// Get next argument (advances position)
    pub fn next(self: *ArgParser) ?[]const u8 {
        if (self.position >= self.args.len) return null;
        const arg = self.args[self.position];
        self.position += 1;
        return arg;
    }

    /// Peek at next argument without advancing
    pub fn peek(self: *ArgParser) ?[]const u8 {
        if (self.position >= self.args.len) return null;
        return self.args[self.position];
    }

    /// Check if a flag exists and consume it
    pub fn flag(self: *ArgParser, name: []const u8) bool {
        if (self.peek()) |arg| {
            if (std.mem.eql(u8, arg, name)) {
                self.position += 1;
                return true;
            }
        }
        return false;
    }

    /// Get option value (--key value)
    pub fn option(self: *ArgParser, key: []const u8) ?[]const u8 {
        if (self.peek()) |arg| {
            if (std.mem.eql(u8, arg, key)) {
                self.position += 1;
                return self.next();
            }
        }
        return null;
    }

    /// Get next positional argument
    pub fn positional(self: *ArgParser) ?[]const u8 {
        return self.next();
    }

    /// Get all remaining arguments
    pub fn rest(self: *ArgParser) []const []const u8 {
        return self.args[self.position..];
    }

    /// Check if there are more arguments
    pub fn hasMore(self: ArgParser) bool {
        return self.position < self.args.len;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "parser next" {
    const args = [_][]const u8{ "add", "file.txt", "other.txt" };
    var parser = ArgParser.init(&args);

    try testing.expectEqualStrings("add", parser.next().?);
    try testing.expectEqualStrings("file.txt", parser.next().?);
    try testing.expectEqualStrings("other.txt", parser.next().?);
    try testing.expectEqual(@as(?[]const u8, null), parser.next());
}

test "parser peek" {
    const args = [_][]const u8{"status"};
    var parser = ArgParser.init(&args);

    try testing.expectEqualStrings("status", parser.peek().?);
    try testing.expectEqualStrings("status", parser.peek().?); // peek doesn't advance
    try testing.expectEqualStrings("status", parser.next().?); // next does
}

test "parser flag" {
    const args = [_][]const u8{ "-m", "message", "file.txt" };
    var parser = ArgParser.init(&args);

    try testing.expect(parser.flag("-m"));
    try testing.expectEqualStrings("message", parser.next().?);
    try testing.expect(!parser.flag("--other"));
}

test "parser option" {
    const args = [_][]const u8{ "--depth", "1", "origin" };
    var parser = ArgParser.init(&args);

    try testing.expectEqualStrings("1", parser.option("--depth").?);
    try testing.expectEqualStrings("origin", parser.next().?);
}

test "parser positional" {
    const args = [_][]const u8{ "init", "mydir" };
    var parser = ArgParser.init(&args);

    try testing.expectEqualStrings("init", parser.positional().?);
    try testing.expectEqualStrings("mydir", parser.positional().?);
}

test "parser rest" {
    const args = [_][]const u8{ "a", "b", "c", "d" };
    var parser = ArgParser.init(&args);

    _ = parser.next(); // consume "a"
    const remaining = parser.rest();
    try testing.expectEqual(@as(usize, 3), remaining.len);
    try testing.expectEqualStrings("b", remaining[0]);
}

const testing = std.testing;
