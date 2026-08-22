const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const refs_mod = @import("../../core/refs.zig");
const object = @import("../../core/object.zig");
const storage_mod = @import("../../core/storage.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    const refs_manager = refs_mod.Refs.init(git_dir);

    if (args.len == 0) {
        // List tags
        const tags = try refs_manager.list(allocator, io.io, "tags");
        defer {
            for (tags) |t| allocator.free(t);
            allocator.free(tags);
        }

        for (tags) |tag| {
            const name = if (std.mem.startsWith(u8, tag, "refs/tags/")) tag[10..] else tag;
            try io.print("{s}\n", .{name});
        }
        return;
    }

    var tag_name: ?[]const u8 = null;
    var annotated = false;
    var message: ?[]const u8 = null;
    var delete = false;
    var show_info = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-a")) {
            annotated = true;
        } else if (std.mem.eql(u8, arg, "-m") and i + 1 < args.len) {
            i += 1;
            message = args[i];
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delete")) {
            delete = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--list")) {
            show_info = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            tag_name = arg;
        }
    }

    if (delete) {
        const name = tag_name orelse {
            try io.eprint("usage: gitz tag -d <tagname>\n", .{});
            return;
        };
        const ref_name = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{name});
        defer allocator.free(ref_name);

        refs_manager.delete(allocator, io.io, ref_name) catch {
            try io.eprint("error: tag '{s}' not found\n", .{name});
            return;
        };
        try io.print("Deleted tag '{s}'\n", .{name});
        return;
    }

    const name = tag_name orelse return;

    // Check if tag already exists
    const ref_name = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{name});
    defer allocator.free(ref_name);

    _ = refs_manager.read(allocator, io.io, ref_name) catch {
        // Tag doesn't exist - create it
        if (annotated) {
            // Create annotated tag object
            try createAnnotatedTag(allocator, git_dir, name, message orelse "", io);
        } else {
            // Create lightweight tag
            const sha = refs_manager.read(allocator, io.io, "HEAD") catch {
                try io.eprint("fatal: no commits yet\n", .{});
                return;
            };
            try refs_manager.write(allocator, io.io, ref_name, sha);
        }
        try io.print("Created tag '{s}'\n", .{name});
        return;
    };

    try io.eprint("error: tag '{s}' already exists\n", .{name});
}

fn createAnnotatedTag(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    name: []const u8,
    msg: []const u8,
    io: Io,
) !void {
    const refs_manager = refs_mod.Refs.init(git_dir);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);

    const target_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
        try io.eprint("fatal: no commits yet\n", .{});
        return;
    };

    const now_ts = std.Io.Timestamp.now(io.io, .real);
    const now: i64 = @intCast(@divTrunc(now_ts.nanoseconds, std.time.ns_per_s));

    const tag_obj = object.TagObject{
        .object = target_sha,
        .object_type = .commit,
        .tag_name = name,
        .tagger = .{ .name = "GitZ User", .email = "user@gitz.dev", .timestamp = now, .timezone = "+0000" },
        .message = msg,
    };

    const tag_sha = try store.write(allocator, io.io, object.GitObject{ .tag = tag_obj });

    const ref_name = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{name});
    defer allocator.free(ref_name);
    try refs_manager.write(allocator, io.io, ref_name, tag_sha);
}
