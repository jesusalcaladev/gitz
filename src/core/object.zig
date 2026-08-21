const std = @import("std");
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
