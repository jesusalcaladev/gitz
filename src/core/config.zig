const std = @import("std");

const Allocator = std.mem.Allocator;

const testing = std.testing;

/// Simple INI-style config parser for Git config files
pub const Config = struct {
    sections: std.StringHashMap(std.StringHashMap([]const u8)),
    /// Section names in first-seen order. `sections` is a hash map, so without
    /// this the serialized file would come out in a different order on every
    /// write and `gitz config` would produce a noisy diff of the repo config.
    order: std.ArrayList([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Config {
        return .{
            .sections = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .order = .empty,
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
        }
        self.sections.deinit();
        // `order` holds the owned section names; `sections` only borrows them.
        for (self.order.items) |name| self.allocator.free(name);
        self.order.deinit(self.allocator);
    }

    /// Get the key map stored under `name`, creating the section if needed.
    /// The returned map is only valid until the next `sections` mutation.
    ///
    /// The section name is copied, not borrowed: `parse` is handed a buffer it
    /// does not own, and callers routinely free it as soon as `parse` returns.
    /// A borrowed key would leave every later lookup reading freed memory.
    fn sectionMap(self: *Config, name: []const u8) !*std.StringHashMap([]const u8) {
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);

        const gop = try self.sections.getOrPut(owned);
        if (gop.found_existing) {
            self.allocator.free(owned);
            return gop.value_ptr;
        }
        gop.value_ptr.* = std.StringHashMap([]const u8).init(self.allocator);
        errdefer gop.value_ptr.deinit();
        try self.order.append(self.allocator, owned);
        return gop.value_ptr;
    }

    /// Parse a config file
    pub fn parse(self: *Config, content: []const u8) !void {
        var current_name: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Section header: [section "subsection"]
            if (trimmed[0] == '[') {
                const end = std.mem.indexOf(u8, trimmed, "]") orelse continue;
                if (self.sectionMap(trimmed[1..end])) |_| {
                    current_name = self.order.items[self.order.items.len - 1];
                } else |_| {
                    current_name = null;
                }
                continue;
            }

            // Key = value
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");

                if (current_name) |name| {
                    const section_map = self.sectionMap(name) catch continue;
                    const owned_key = try self.allocator.dupe(u8, key);
                    errdefer self.allocator.free(owned_key);
                    const owned_val = try self.allocator.dupe(u8, value);
                    const gop = section_map.getOrPut(owned_key) catch {
                        self.allocator.free(owned_key);
                        self.allocator.free(owned_val);
                        continue;
                    };
                    if (gop.found_existing) {
                        self.allocator.free(owned_key);
                        self.allocator.free(gop.value_ptr.*);
                    }
                    gop.value_ptr.* = owned_val;
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
    pub fn set(self: *Config, section_name: []const u8, key: []const u8, value: []const u8) !void {
        const section_map = try self.sectionMap(section_name);
        // Check if key already exists — if so, free old value before overwriting
        const new_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(new_key);
        const gop = try section_map.getOrPut(new_key);
        if (gop.found_existing) {
            // Old key stays, new_key is lost — free it
            self.allocator.free(new_key);
            // Free old value
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = try self.allocator.dupe(u8, value);
    }

    /// Serialize config to string, in the order sections were first seen.
    pub fn serialize(self: Config, allocator: Allocator) ![]u8 {
        var result = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        errdefer result.deinit(allocator);

        for (self.order.items) |name| {
            const section_map = self.sections.get(name) orelse continue;
            try result.print(allocator, "[{s}]\n", .{name});
            var val_iter = section_map.iterator();
            while (val_iter.next()) |entry| {
                try result.print(allocator, "\t{s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
            try result.append(allocator, '\n');
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


// =============================================================================
// TDD Bug-Hunt Tests — Config Edge Cases
// =============================================================================

test "BUG: config owns section names, not the parsed buffer" {
    // `parse` receives a buffer it does not own; callers free it as soon as
    // `parse` returns. If the section names were borrowed from it, every
    // `get` after that point would read freed memory and find nothing.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const content = try gpa.dupe(u8, "[remote \"origin\"]\n\turl = https://example.com/x.git\n");
    const name = try gpa.dupe(u8, content);

    var config = Config.init(gpa);
    defer config.deinit();
    try config.parse(name);

    try testing.expectEqualStrings("https://example.com/x.git", config.get("remote \"origin\"", "url").?);
}

test "BUG: config roundtrip preserves section order" {
    var config = Config.init(testing.allocator);
    defer config.deinit();

    try config.set("core", "repositoryformatversion", "0");
    try config.set("user", "name", "Alice");
    try config.set("core", "bare", "false");

    const serialized = try config.serialize(testing.allocator);
    defer testing.allocator.free(serialized);

    // Sections must come out in first-set order, not hash order, so that
    // rewriting the config does not reorder it.
    const core_at = std.mem.indexOf(u8, serialized, "[core]").?;
    const user_at = std.mem.indexOf(u8, serialized, "[user]").?;
    try testing.expect(core_at < user_at);

    var reparsed = Config.init(testing.allocator);
    defer reparsed.deinit();
    try reparsed.parse(serialized);
    try testing.expectEqualStrings("Alice", reparsed.get("user", "name").?);
    try testing.expectEqualStrings("0", reparsed.get("core", "repositoryformatversion").?);
}

test "BUG: config serialize roundtrip" {
    var config = Config.init(testing.allocator);
    defer config.deinit();

    try config.set("user", "name", "Test User");
    try config.set("user", "email", "test@example.com");

    const serialized = try config.serialize(testing.allocator);
    defer testing.allocator.free(serialized);

    // Re-parse the serialized output
    var config2 = Config.init(testing.allocator);
    defer config2.deinit();
    try config2.parse(serialized);

    try testing.expectEqualStrings("Test User", config2.get("user", "name").?);
    try testing.expectEqualStrings("test@example.com", config2.get("user", "email").?);
}

test "BUG: config set overwrites existing" {
    var config = Config.init(testing.allocator);
    defer config.deinit();

    try config.set("user", "name", "Old Name");
    try testing.expectEqualStrings("Old Name", config.get("user", "name").?);

    try config.set("user", "name", "New Name");
    try testing.expectEqualStrings("New Name", config.get("user", "name").?);
}

test "BUG: config multiple sections" {
    var config = Config.init(testing.allocator);
    defer config.deinit();

    try config.set("user", "name", "Alice");
    try config.set("storage", "backend", "shard");
    try config.set("storage", "shards", "8");

    try testing.expectEqualStrings("Alice", config.get("user", "name").?);
    try testing.expectEqualStrings("shard", config.get("storage", "backend").?);
    try testing.expectEqualStrings("8", config.get("storage", "shards").?);
    try testing.expectEqual(@as(?[]const u8, null), config.get("user", "backend"));
}

test "BUG: config parse with equals in value" {
    var config = Config.init(testing.allocator);
    defer config.deinit();

    try config.parse("[test]\nkey = value=with=equals\n");
    try testing.expectEqualStrings("value=with=equals", config.get("test", "key").?);
}

test "BUG: config parse with quotes in value" {
    var config = Config.init(testing.allocator);
    defer config.deinit();

    try config.parse("[test]\nkey = \"quoted value\"\n");
    try testing.expectEqualStrings("quoted value", config.get("test", "key").?);
}
