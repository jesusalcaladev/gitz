const std = @import("std");
const testing = std.testing;

const Allocator = std.mem.Allocator;

/// Simple INI-style config parser for Git config files
pub const Config = struct {
    sections: std.StringHashMap(std.StringHashMap([]const u8)),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Config {
        return .{
            .sections = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        var iter = self.sections.iterator();
        while (iter.next()) |entry| {
            var val_iter = entry.value_ptr.iterator();
            while (val_iter.next()) |val| {
                self.allocator.free(val.key_ptr.*);
                self.allocator.free(val.value_ptr.*);
            }
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.sections.deinit();
    }

    /// Parse a config file
    pub fn parse(self: *Config, content: []const u8) !void {
        var current_section: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Section header: [section "subsection"]
            if (trimmed[0] == '[') {
                const end = std.mem.indexOf(u8, trimmed, "]") orelse continue;
                current_section = try self.allocator.dupe(u8, trimmed[1..end]);
                if (!self.sections.contains(current_section.?)) {
                    try self.sections.put(current_section.?, std.StringHashMap([]const u8).init(self.allocator));
                }
                continue;
            }

            // Key = value
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");

                if (current_section) |section| {
                    if (self.sections.getPtr(section)) |section_map| {
                        try section_map.put(
                            try self.allocator.dupe(u8, key),
                            try self.allocator.dupe(u8, value),
                        );
                    }
                }
            }
        }
    }

    /// Get a config value
    pub fn get(self: Config, section: []const u8, key: []const u8) ?[]const u8 {
        if (self.sections.get(section)) |section_map| {
            return section_map.get(key);
        }
        return null;
    }

    /// Set a config value
    pub fn set(self: *Config, section: []const u8, key: []const u8, value: []const u8) !void {
        const owned_section = try self.allocator.dupe(u8, section);
        const entry = try self.sections.getOrPut(owned_section);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.StringHashMap([]const u8).init(self.allocator);
        }
        try entry.value_ptr.put(
            try self.allocator.dupe(u8, key),
            try self.allocator.dupe(u8, value),
        );
    }

    /// Serialize config to string
    pub fn serialize(self: Config, allocator: Allocator) ![]u8 {
        var result = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        errdefer result.deinit(allocator);
        const writer = result.writer(allocator);

        var section_iter = self.sections.iterator();
        while (section_iter.next()) |section| {
            try writer.print("[{s}]\n", .{section.key_ptr.*});
            var val_iter = section.value_ptr.iterator();
            while (val_iter.next()) |entry| {
                try writer.print("\t{s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
            try writer.writeByte('\n');
        }

        return try result.toOwnedSlice(allocator);
    }

    /// Get user name from config or environment
    pub fn getUserName(self: Config) ?[]const u8 {
        // Check environment first
        return std.process.getEnvVarOwned(self.allocator, "GIT_AUTHOR_NAME") catch |e| {
            _ = e;
            // Fall back to config
            return self.get("user", "name");
        } catch null;
    }

    /// Get user email from config or environment
    pub fn getUserEmail(self: Config) ?[]const u8 {
        return std.process.getEnvVarOwned(self.allocator, "GIT_AUTHOR_EMAIL") catch |e| {
            _ = e;
            return self.get("user", "email");
        } catch null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "config parse basic" {
    var config = Config.init(testing.allocator);
    defer config.deinit();

    try config.parse("[user]\n\tname = Test User\n\temail = test@example.com\n");

    try testing.expectEqualStrings("Test User", config.get("user", "name").?);
    try testing.expectEqualStrings("test@example.com", config.get("user", "email").?);
}

test "config parse with subsections" {
    var config = Config.init(testing.allocator);
    defer config.deinit();

    try config.parse("[remote \"origin\"]\n\turl = https://github.com/user/repo.git\n");

    try testing.expectEqualStrings(
        "https://github.com/user/repo.git",
        config.get("remote \"origin\"", "url").?,
    );
}

test "config get nonexistent" {
    var config = Config.init(testing.allocator);
    defer config.deinit();

    try testing.expectEqual(@as(?[]const u8, null), config.get("user", "name"));
}

test "config set and get" {
    var config = Config.init(testing.allocator);
    defer config.deinit();

    try config.set("user", "name", "New Name");
    try testing.expectEqualStrings("New Name", config.get("user", "name").?);
}

test "config parse comments" {
    var config = Config.init(testing.allocator);
    defer config.deinit();

    try config.parse("# This is a comment\n[user]\n# Another comment\nname = Test\n");

    try testing.expectEqualStrings("Test", config.get("user", "name").?);
}

test "config parse empty" {
    var config = Config.init(testing.allocator);
    defer config.deinit();

    try config.parse("");
    try testing.expectEqual(@as(?[]const u8, null), config.get("user", "name"));
}
