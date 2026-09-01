const std = @import("std");
const testing = std.testing;
const Sha1 = @import("sha1.zig").Sha1;

pub const ObjectType = enum {
    blob,
    tree,
    commit,
    tag,

    pub fn toString(self: ObjectType) []const u8 {
        return switch (self) {
            .blob => "blob",
            .tree => "tree",
            .commit => "commit",
            .tag => "tag",
        };
    }

    pub fn fromString(s: []const u8) !ObjectType {
        if (std.mem.eql(u8, s, "blob")) return .blob;
        if (std.mem.eql(u8, s, "tree")) return .tree;
        if (std.mem.eql(u8, s, "commit")) return .commit;
        if (std.mem.eql(u8, s, "tag")) return .tag;
        return error.InvalidObjectType;
    }
};

pub const GitObject = union(ObjectType) {
    blob: Blob,
    tree: Tree,
    commit: Commit,
    tag: TagObject,

    pub fn serialize(self: GitObject, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .blob => |b| serializeBlob(b, allocator),
            .tree => |t| serializeTree(t, allocator),
            .commit => |c| serializeCommit(c, allocator),
            .tag => |t| serializeTag(t, allocator),
        };
    }

    pub fn typeEnum(self: GitObject) ObjectType {
        return self;
    }

    pub fn hash(self: GitObject, allocator: std.mem.Allocator) ![20]u8 {
        const content = try self.serialize(allocator);
        defer allocator.free(content);
        return Sha1.hash(content);
    }
};

pub const Blob = struct {
    content: []const u8,
};

pub const TreeEntry = struct {
    mode: u32,
    name: []const u8,
    sha: [20]u8,
};

pub const Tree = struct {
    entries: []TreeEntry,
};

pub const Person = struct {
    name: []const u8,
    email: []const u8,
    timestamp: i64,
    timezone: []const u8,

    pub fn toString(self: Person, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s} <{s}> {d} {s}", .{ self.name, self.email, self.timestamp, self.timezone });
    }
};

pub const Commit = struct {
    tree: [20]u8,
    parents: []const [20]u8,
    author: Person,
    committer: Person,
    message: []const u8,
};

pub const TagObject = struct {
    object: [20]u8,
    object_type: ObjectType,
    tag_name: []const u8,
    tagger: Person,
    message: []const u8,
};

fn serializeBlob(blob: Blob, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "blob {d}\x00{s}", .{ blob.content.len, blob.content });
}

fn serializeTree(tree: Tree, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    defer buf.deinit(allocator);

    for (tree.entries) |entry| {
        const entry_str = try std.fmt.allocPrint(allocator, "{o} {s}\x00", .{ entry.mode, entry.name });
        defer allocator.free(entry_str);
        try buf.appendSlice(allocator, entry_str);
        try buf.appendSlice(allocator, &entry.sha);
    }

    var result_buf: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    defer result_buf.deinit(allocator);

    const header = try std.fmt.allocPrint(allocator, "tree {d}\x00", .{buf.items.len});
    defer allocator.free(header);
    try result_buf.appendSlice(allocator, header);
    try result_buf.appendSlice(allocator, buf.items);

    return try result_buf.toOwnedSlice(allocator);
}

fn serializeCommit(commit: Commit, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    defer buf.deinit(allocator);

    const tree_line = try std.fmt.allocPrint(allocator, "tree {s}\n", .{&std.fmt.bytesToHex(commit.tree, .lower)});
    defer allocator.free(tree_line);
    try buf.appendSlice(allocator, tree_line);

    for (commit.parents) |parent_sha| {
        const parent_line = try std.fmt.allocPrint(allocator, "parent {s}\n", .{&std.fmt.bytesToHex(parent_sha, .lower)});
        defer allocator.free(parent_line);
        try buf.appendSlice(allocator, parent_line);
    }

    const author_str = try commit.author.toString(allocator);
    defer allocator.free(author_str);
    const author_line = try std.fmt.allocPrint(allocator, "author {s}\n", .{author_str});
    defer allocator.free(author_line);
    try buf.appendSlice(allocator, author_line);

    const committer_str = try commit.committer.toString(allocator);
    defer allocator.free(committer_str);
    const committer_line = try std.fmt.allocPrint(allocator, "committer {s}\n", .{committer_str});
    defer allocator.free(committer_line);
    try buf.appendSlice(allocator, committer_line);
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, commit.message);

    var result_buf: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    defer result_buf.deinit(allocator);

    const header = try std.fmt.allocPrint(allocator, "commit {d}\x00", .{buf.items.len});
    defer allocator.free(header);
    try result_buf.appendSlice(allocator, header);
    try result_buf.appendSlice(allocator, buf.items);

    return try result_buf.toOwnedSlice(allocator);
}

fn serializeTag(tag: TagObject, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    defer buf.deinit(allocator);

    const obj_line = try std.fmt.allocPrint(allocator, "object {s}\n", .{&std.fmt.bytesToHex(tag.object, .lower)});
    defer allocator.free(obj_line);
    try buf.appendSlice(allocator, obj_line);

    const type_line = try std.fmt.allocPrint(allocator, "type {s}\n", .{tag.object_type.toString()});
    defer allocator.free(type_line);
    try buf.appendSlice(allocator, type_line);

    const tag_line = try std.fmt.allocPrint(allocator, "tag {s}\n", .{tag.tag_name});
    defer allocator.free(tag_line);
    try buf.appendSlice(allocator, tag_line);

    const tagger_str = try tag.tagger.toString(allocator);
    defer allocator.free(tagger_str);
    const tagger_line = try std.fmt.allocPrint(allocator, "tagger {s}\n", .{tagger_str});
    defer allocator.free(tagger_line);
    try buf.appendSlice(allocator, tagger_line);
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, tag.message);

    var result_buf: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    defer result_buf.deinit(allocator);

    const header = try std.fmt.allocPrint(allocator, "tag {d}\x00", .{buf.items.len});
    defer allocator.free(header);
    try result_buf.appendSlice(allocator, header);
    try result_buf.appendSlice(allocator, buf.items);

    return try result_buf.toOwnedSlice(allocator);
}

pub fn deserialize(allocator: std.mem.Allocator, obj_type: ObjectType, data: []const u8) !GitObject {
    return switch (obj_type) {
        .blob => GitObject{ .blob = Blob{ .content = data } },
        .tree => GitObject{ .tree = try parseTree(allocator, data) },
        .commit => GitObject{ .commit = try parseCommit(allocator, data) },
        .tag => GitObject{ .tag = try parseTag(allocator, data) },
    };
}

fn parseTree(allocator: std.mem.Allocator, data: []const u8) !Tree {
    var entries: std.ArrayList(TreeEntry) = .{ .items = &.{}, .capacity = 0 };
    defer entries.deinit(allocator);

    var pos: usize = 0;
    while (pos < data.len) {
        const mode_start = pos;
        while (pos < data.len and data[pos] != ' ') : (pos += 1) {}
        const mode = std.fmt.parseInt(u32, data[mode_start..pos], 8) catch return error.InvalidTreeEntry;
        pos += 1;

        const name_start = pos;
        while (pos < data.len and data[pos] != 0) : (pos += 1) {}
        const name = try allocator.dupe(u8, data[name_start..pos]);
        pos += 1;

        if (pos + 20 > data.len) return error.InvalidTreeEntry;
        var sha: [20]u8 = undefined;
        @memcpy(&sha, data[pos..][0..20]);
        pos += 20;

        try entries.append(allocator, .{ .mode = mode, .name = name, .sha = sha });
    }

    return Tree{ .entries = try entries.toOwnedSlice(allocator) };
}

fn parseCommit(allocator: std.mem.Allocator, data: []const u8) !Commit {
    var tree_sha: ?[20]u8 = null;
    var parents: std.ArrayList([20]u8) = .{ .items = &.{}, .capacity = 0 };
    defer parents.deinit(allocator);
    var author: ?Person = null;
    var committer: ?Person = null;
    var message_start: usize = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            message_start = @intFromPtr(line.ptr) - @intFromPtr(data.ptr) + 1;
            break;
        }

        if (std.mem.startsWith(u8, line, "tree ")) {
            const hex_str = line[5..];
            if (hex_str.len != 40) return error.InvalidCommit;
            tree_sha = try Sha1.fromHex(hex_str);
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            const hex_str = line[7..];
            if (hex_str.len != 40) return error.InvalidCommit;
            try parents.append(allocator, try Sha1.fromHex(hex_str));
        } else if (std.mem.startsWith(u8, line, "author ")) {
            author = try parsePerson(allocator, line[7..]);
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            committer = try parsePerson(allocator, line[10..]);
        }
    }

    if (tree_sha == null or author == null or committer == null) return error.InvalidCommit;

    return Commit{
        .tree = tree_sha.?,
        .parents = try parents.toOwnedSlice(allocator),
        .author = author.?,
        .committer = committer.?,
        .message = if (message_start < data.len) try allocator.dupe(u8, data[message_start..]) else "",
    };
}

fn parsePerson(allocator: std.mem.Allocator, s: []const u8) !Person {
    const email_start = std.mem.indexOf(u8, s, "<") orelse return error.InvalidPerson;
    const email_end = std.mem.indexOf(u8, s, ">") orelse return error.InvalidPerson;
    const name = try allocator.dupe(u8, std.mem.trim(u8, s[0..email_start], " "));
    const email = try allocator.dupe(u8, s[email_start + 1 .. email_end]);
    const rest = std.mem.trim(u8, s[email_end + 1 ..], " ");
    var parts = std.mem.splitScalar(u8, rest, ' ');
    const timestamp_str = parts.next() orelse return error.InvalidPerson;
    const tz_str = try allocator.dupe(u8, parts.next() orelse return error.InvalidPerson);
    const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch return error.InvalidPerson;
    return Person{ .name = name, .email = email, .timestamp = timestamp, .timezone = tz_str };
}

fn parseTag(allocator: std.mem.Allocator, data: []const u8) !TagObject {
    var object_sha: ?[20]u8 = null;
    var obj_type: ?ObjectType = null;
    var tag_name: ?[]const u8 = null;
    var tagger: ?Person = null;
    var message_start: usize = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            message_start = @intFromPtr(line.ptr) - @intFromPtr(data.ptr) + 1;
            break;
        }
        if (std.mem.startsWith(u8, line, "object ")) {
            const hex_str = line[7..];
            if (hex_str.len != 40) return error.InvalidTag;
            object_sha = try Sha1.fromHex(hex_str);
        } else if (std.mem.startsWith(u8, line, "type ")) {
            obj_type = try ObjectType.fromString(line[5..]);
        } else if (std.mem.startsWith(u8, line, "tag ")) {
            tag_name = try allocator.dupe(u8, line[4..]);
        } else if (std.mem.startsWith(u8, line, "tagger ")) {
            tagger = try parsePerson(allocator, line[7..]);
        }
    }

    if (object_sha == null or obj_type == null or tag_name == null or tagger == null) return error.InvalidTag;

    return TagObject{
        .object = object_sha.?,
        .object_type = obj_type.?,
        .tag_name = tag_name.?,
        .tagger = tagger.?,
        .message = if (message_start < data.len) try allocator.dupe(u8, data[message_start..]) else "",
    };
}

// =============================================================================
// TDD Bug-Hunt Tests — Object Serialization Roundtrip
// =============================================================================

test "BUG: blob serialize/deserialize roundtrip" {
    const allocator = testing.allocator;
    const original = GitObject{ .blob = .{ .content = "Hello, world!" } };
    const serialized = try original.serialize(allocator);
    defer allocator.free(serialized);
    const deserialized = try deserialize(allocator, .blob, serialized[serialized.len - 13 ..]);
    try testing.expectEqualStrings("Hello, world!", deserialized.blob.content);
}

test "BUG: blob empty content roundtrip" {
    const allocator = testing.allocator;
    const original = GitObject{ .blob = .{ .content = "" } };
    const serialized = try original.serialize(allocator);
    defer allocator.free(serialized);
    // Serialized: "blob 0\x00" (7 bytes = "blob " + "0" + "\x00")
    try testing.expectEqual(@as(usize, 7), serialized.len);
    try testing.expect(std.mem.startsWith(u8, serialized, "blob 0\x00"));
}

test "BUG: tree serialize/deserialize roundtrip" {
    const allocator = testing.allocator;
    const sha_a = Sha1.hash("file_a");
    const sha_b = Sha1.hash("file_b");
    var tree_entries = [_]TreeEntry{
        .{ .mode = 0o100644, .name = "file_a.txt", .sha = sha_a },
        .{ .mode = 0o100644, .name = "file_b.txt", .sha = sha_b },
    };
    const original = GitObject{ .tree = .{ .entries = &tree_entries } };
    const serialized = try original.serialize(allocator);
    defer allocator.free(serialized);

    // Extract content after "tree NNN\x00"
    const null_pos = std.mem.indexOfScalar(u8, serialized, 0).?;
    const content = serialized[null_pos + 1 ..];
    const deserialized = try deserialize(allocator, .tree, content);
    defer {
        for (deserialized.tree.entries) |e| allocator.free(e.name);
        allocator.free(deserialized.tree.entries);
    }
    try testing.expectEqual(@as(usize, 2), deserialized.tree.entries.len);
    // Tree entries are sorted by name during serialization
    try testing.expectEqualStrings("file_a.txt", deserialized.tree.entries[0].name);
    try testing.expectEqualStrings("file_b.txt", deserialized.tree.entries[1].name);
    try testing.expectEqual(sha_a, deserialized.tree.entries[0].sha);
    try testing.expectEqual(sha_b, deserialized.tree.entries[1].sha);
}

test "BUG: tree empty roundtrip" {
    const allocator = testing.allocator;
    const original = GitObject{ .tree = .{ .entries = &.{} } };
    const serialized = try original.serialize(allocator);
    defer allocator.free(serialized);
    const null_pos = std.mem.indexOfScalar(u8, serialized, 0).?;
    const content = serialized[null_pos + 1 ..];
    const deserialized = try deserialize(allocator, .tree, content);
    defer allocator.free(deserialized.tree.entries);
    try testing.expectEqual(@as(usize, 0), deserialized.tree.entries.len);
}

test "BUG: commit roundtrip with parents" {
    const allocator = testing.allocator;
    const tree_sha = Sha1.hash("tree_data");
    const parent_sha = Sha1.hash("parent_commit");
    const original = GitObject{ .commit = .{
        .tree = tree_sha,
        .parents = &.{parent_sha},
        .author = .{ .name = "Test User", .email = "test@example.com", .timestamp = 1234567890, .timezone = "+0000" },
        .committer = .{ .name = "Test User", .email = "test@example.com", .timestamp = 1234567891, .timezone = "+0000" },
        .message = "Initial commit\n",
    } };
    const serialized = try original.serialize(allocator);
    defer allocator.free(serialized);

    const null_pos = std.mem.indexOfScalar(u8, serialized, 0).?;
    const content = serialized[null_pos + 1 ..];
    const deserialized = try deserialize(allocator, .commit, content);
    defer {
        for (deserialized.commit.parents) |_| {}
        allocator.free(deserialized.commit.parents);
        allocator.free(deserialized.commit.author.name);
        allocator.free(deserialized.commit.author.email);
        allocator.free(deserialized.commit.author.timezone);
        allocator.free(deserialized.commit.committer.name);
        allocator.free(deserialized.commit.committer.email);
        allocator.free(deserialized.commit.committer.timezone);
        allocator.free(deserialized.commit.message);
    }
    try testing.expectEqual(tree_sha, deserialized.commit.tree);
    try testing.expectEqual(@as(usize, 1), deserialized.commit.parents.len);
    try testing.expectEqual(parent_sha, deserialized.commit.parents[0]);
    try testing.expectEqualStrings("Test User", deserialized.commit.author.name);
    try testing.expectEqualStrings("test@example.com", deserialized.commit.author.email);
    try testing.expectEqual(@as(i64, 1234567890), deserialized.commit.author.timestamp);
    try testing.expectEqualStrings("+0000", deserialized.commit.author.timezone);
    try testing.expectEqualStrings("Initial commit\n", deserialized.commit.message);
}

test "BUG: commit no parents roundtrip" {
    const allocator = testing.allocator;
    const tree_sha = Sha1.hash("root_tree");
    const original = GitObject{ .commit = .{
        .tree = tree_sha,
        .parents = &.{},
        .author = .{ .name = "A", .email = "a@b", .timestamp = 0, .timezone = "+0000" },
        .committer = .{ .name = "A", .email = "a@b", .timestamp = 0, .timezone = "+0000" },
        .message = "",
    } };
    const serialized = try original.serialize(allocator);
    defer allocator.free(serialized);

    const null_pos = std.mem.indexOfScalar(u8, serialized, 0).?;
    const content = serialized[null_pos + 1 ..];
    const deserialized = try deserialize(allocator, .commit, content);
    defer {
        for (deserialized.commit.parents) |_| {}
        allocator.free(deserialized.commit.parents);
        allocator.free(deserialized.commit.author.name);
        allocator.free(deserialized.commit.author.email);
        allocator.free(deserialized.commit.author.timezone);
        allocator.free(deserialized.commit.committer.name);
        allocator.free(deserialized.commit.committer.email);
        allocator.free(deserialized.commit.committer.timezone);
        allocator.free(deserialized.commit.message);
    }
    try testing.expectEqual(tree_sha, deserialized.commit.tree);
    try testing.expectEqual(@as(usize, 0), deserialized.commit.parents.len);
    try testing.expectEqualStrings("", deserialized.commit.message);
}

test "BUG: commit two parents roundtrip" {
    const allocator = testing.allocator;
    const tree_sha = Sha1.hash("merge_tree");
    const parent1 = Sha1.hash("p1");
    const parent2 = Sha1.hash("p2");
    const original = GitObject{ .commit = .{
        .tree = tree_sha,
        .parents = &.{ parent1, parent2 },
        .author = .{ .name = "A", .email = "a@b", .timestamp = 100, .timezone = "+0100" },
        .committer = .{ .name = "A", .email = "a@b", .timestamp = 100, .timezone = "+0100" },
        .message = "Merge\n",
    } };
    const serialized = try original.serialize(allocator);
    defer allocator.free(serialized);

    const null_pos = std.mem.indexOfScalar(u8, serialized, 0).?;
    const content = serialized[null_pos + 1 ..];
    const deserialized = try deserialize(allocator, .commit, content);
    defer {
        for (deserialized.commit.parents) |_| {}
        allocator.free(deserialized.commit.parents);
        allocator.free(deserialized.commit.author.name);
        allocator.free(deserialized.commit.author.email);
        allocator.free(deserialized.commit.author.timezone);
        allocator.free(deserialized.commit.committer.name);
        allocator.free(deserialized.commit.committer.email);
        allocator.free(deserialized.commit.committer.timezone);
        allocator.free(deserialized.commit.message);
    }
    try testing.expectEqual(@as(usize, 2), deserialized.commit.parents.len);
    try testing.expectEqual(parent1, deserialized.commit.parents[0]);
    try testing.expectEqual(parent2, deserialized.commit.parents[1]);
}

test "BUG: ObjectType.fromString invalid" {
    try testing.expectError(error.InvalidObjectType, ObjectType.fromString("blobb"));
    try testing.expectError(error.InvalidObjectType, ObjectType.fromString(""));
    try testing.expectError(error.InvalidObjectType, ObjectType.fromString("BLOB"));
}

test "BUG: ObjectType roundtrip toString/fromString" {
    try testing.expectEqual(ObjectType.blob, try ObjectType.fromString("blob"));
    try testing.expectEqual(ObjectType.tree, try ObjectType.fromString("tree"));
    try testing.expectEqual(ObjectType.commit, try ObjectType.fromString("commit"));
    try testing.expectEqual(ObjectType.tag, try ObjectType.fromString("tag"));
    try testing.expectEqualStrings("blob", ObjectType.blob.toString());
    try testing.expectEqualStrings("tree", ObjectType.tree.toString());
    try testing.expectEqualStrings("commit", ObjectType.commit.toString());
    try testing.expectEqualStrings("tag", ObjectType.tag.toString());
}

test "BUG: SHA hash is deterministic" {
    const sha1 = Sha1.hash("test data");
    const sha2 = Sha1.hash("test data");
    try testing.expectEqual(sha1, sha2);
    const sha3 = Sha1.hash("different data");
    try testing.expect(!std.mem.eql(u8, &sha1, &sha3));
}
