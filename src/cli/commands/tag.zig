const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const refs_mod = @import("../../core/refs.zig");
const object = @import("../../core/object.zig");
const storage_mod = @import("../../core/storage.zig");
const config_cmd = @import("config.zig");
const errors = @import("../errors.zig");
const Repo = @import("../../core/repo.zig").Repo;

/// Everything `gitz tag` can be asked to do.
const Mode = enum {
    /// Print existing tags.
    list,
    /// Create a tag.
    create,
    /// Print a tag plus the commit it points at.
    show,
    /// Delete a tag.
    remove,
    /// Show every ref matching a pattern, with the commit they point at.
    verify,
};

pub fn execute(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    // For a repository with no worktrees the three directories coincide, so
    // the existing path building below is unchanged. A linked worktree gets
    // the right directory per role from `repo`.
    var mode: Mode = .create;
    var annotated = false;
    var force = false;
    var delete = false;
    var message: ?[]const u8 = null;
    var positional = std.ArrayList([]const u8).empty;
    defer positional.deinit(allocator);
    var show_lines: usize = 1;
    var explicit_mode = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            // `-l` did not exist: it fell through to "no arguments", which meant
            // "create a tag" with a null name, so `gitz tag -l` printed nothing
            // and exited 0.
            mode = .list;
            explicit_mode = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delete")) {
            delete = true;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--annotate")) {
            annotated = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sign")) {
            // GPG signing is not implemented; refusing is better than silently
            // producing an unsigned tag.
            errors.errorf(io, "tag signing is not supported", .{});
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verify")) {
            mode = .verify;
            explicit_mode = true;
        } else if (std.mem.eql(u8, arg, "-n")) {
            show_lines = @max(show_lines, 1);
            mode = .show;
            explicit_mode = true;
        } else if (std.mem.startsWith(u8, arg, "-n") and arg.len > 2) {
            show_lines = std.fmt.parseInt(usize, arg[2..], 10) catch 1;
            mode = .show;
            explicit_mode = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            if (i + 1 >= args.len) errors.errorf(io, "option '{s}' requires a value", .{arg});
            i += 1;
            message = args[i];
            // git's `-m` implies an annotated tag; it used to create a
            // lightweight tag and discard the message.
            annotated = true;
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--file")) {
            if (i + 1 >= args.len) errors.errorf(io, "option '{s}' requires a value", .{arg});
            i += 1;
            const text = io.readFileAlloc(args[i]) catch {
                errors.errorf(io, "could not read '{s}'", .{args[i]});
            };
            message = std.mem.trim(u8, text, " \t\r\n");
            annotated = true;
        } else if (std.mem.eql(u8, arg, "--sort") or std.mem.eql(u8, arg, "--contains") or
            std.mem.eql(u8, arg, "--merged") or std.mem.eql(u8, arg, "--no-merged") or
            std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "--column") or
            std.mem.eql(u8, arg, "--no-column") or std.mem.eql(u8, arg, "--create-reflog"))
        {
            if ((std.mem.eql(u8, arg, "--sort") or std.mem.eql(u8, arg, "--format")) and i + 1 < args.len) {
                i += 1; // accepted, value not used
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            // rest are pathspecs/patterns
        } else if (std.mem.startsWith(u8, arg, "-u") or std.mem.startsWith(u8, arg, "--local-user=")) {
            // Accepted; the tagger identity comes from config.
        } else if (std.mem.startsWith(u8, arg, "-")) {
            errors.errorf(io, "unknown option '{s}'", .{arg});
        } else {
            try positional.append(allocator, arg);
        }
    }

    // An explicit flag decides the mode; only in its absence does the shape of
    // the arguments choose. `-n`/`-v` used to be overwritten here, so
    // `gitz tag -v` fell through to "create a tag with no name" and did nothing.
    //
    // `-l` and `-v` are the same request, so `list` and the verify mode
    // collapse into one here rather than leaving `list` set alongside a mode
    // that the caller then ignored.
    if (!explicit_mode) {
        if (positional.items.len == 0 and !delete) {
            mode = .list;
        } else if (delete) {
            mode = .remove;
        } else {
            // Two positionals is `git tag <name> <commit>`: the tag is placed on
            // that commit. The second one used to overwrite the tag name, so
            // `gitz tag v0 <sha>` silently tagged HEAD and created nothing.
            mode = .create;
        }
    } else if (delete) {
        mode = .remove;
    }

    switch (mode) {
        .list => try listTags(allocator, repo, io),
        .remove => try removeTag(allocator, repo, io, positional.items),
        .show => try showTags(allocator, repo, io, positional.items, show_lines),
        .verify => try verifyTags(allocator, repo, io),
        .create => {
            if (positional.items.len == 0) return;
            const target = if (positional.items.len >= 2) positional.items[1] else null;
            try createTag(allocator, repo, io, positional.items[0], message, annotated, force, target);
        },
    }
}

fn listTags(allocator: std.mem.Allocator, repo: Repo, io: Io) !void {
    const refs_manager = refs_mod.Refs.init(repo);

    const tags = try refs_manager.list(allocator, io.io, "tags");
    defer {
        for (tags) |t| allocator.free(t);
        allocator.free(tags);
    }

    // Directory order is not a listing order.
    std.mem.sort([]const u8, tags, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (tags) |tag| {
        const name = if (std.mem.startsWith(u8, tag, "refs/tags/")) tag[10..] else tag;
        try io.print("{s}\n", .{name});
    }
}

fn removeTag(allocator: std.mem.Allocator, repo: Repo, io: Io, positional: []const []const u8) !void {
    const refs_manager = refs_mod.Refs.init(repo);

    const name = positional[0];
    if (!refs_mod.Refs.isValidRefName(name)) {
        errors.errorf(io, "'{s}' is not a valid tag name", .{name});
    }
    const ref_name = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{name});
    defer allocator.free(ref_name);

    _ = refs_manager.read(allocator, io.io, ref_name) catch {
        errors.errorf(io, "tag '{s}' not found", .{name});
    };

    refs_manager.delete(allocator, io.io, ref_name) catch {
        errors.errorf(io, "could not delete tag '{s}'", .{name});
    };
    try io.print("Deleted tag '{s}'\n", .{name});
}

/// Print each tag with the commit it points at.
fn showTags(
    allocator: std.mem.Allocator,
    repo: Repo,
    io: Io,
    positional: []const []const u8,
    show_lines: usize,
) !void {
    _ = show_lines;
    const refs_manager = refs_mod.Refs.init(repo);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);

    // `<commit>` as the only argument lists the tags that reach it.
    const only: ?[]const u8 = if (positional.len >= 1) positional[0] else null;

    const tags = try refs_manager.list(allocator, io.io, "tags");
    defer {
        for (tags) |t| allocator.free(t);
        allocator.free(tags);
    }
    std.mem.sort([]const u8, tags, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (tags) |tag| {
        const name = if (std.mem.startsWith(u8, tag, "refs/tags/")) tag[10..] else tag;

        // Peel annotated tags down to the commit.
        var sha = refs_manager.read(allocator, io.io, tag) catch continue;
        if (store.read(allocator, io.io, sha)) |obj| {
            var current = obj;
            defer current.deinit(allocator);
            if (current == .tag) {
                sha = current.tag.object;
            }
        } else |_| {}

        if (only) |want| {
            const wanted = resolveCommitArg(allocator, io, refs_manager, store, want) orelse continue;
            if (!std.mem.eql(u8, &sha, &wanted)) continue;
        }

        const hex = Sha1.hex(sha);
        try io.print("{s} {s}\n", .{ hex[0..7], name });
    }
}

fn verifyTags(allocator: std.mem.Allocator, repo: Repo, io: Io) !void {
    const refs_manager = refs_mod.Refs.init(repo);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);

    const tags = try refs_manager.list(allocator, io.io, "tags");
    defer {
        for (tags) |t| allocator.free(t);
        allocator.free(tags);
    }

    for (tags) |tag| {
        const name = if (std.mem.startsWith(u8, tag, "refs/tags/")) tag[10..] else tag;
        const sha = refs_manager.read(allocator, io.io, tag) catch continue;
        if (!store.exists(io.io, sha)) {
            errors.errorf(io, "tag '{s}' points at a missing object", .{name});
        }
        const hex = Sha1.hex(sha);
        try io.print("{s}: {s} {s}\n", .{ name, hex[0..7], "ok" });
    }
}

fn createTag(
    allocator: std.mem.Allocator,
    repo: Repo,
    io: Io,
    name: []const u8,
    message: ?[]const u8,
    annotated: bool,
    force: bool,
    target_arg: ?[]const u8,
) !void {
    if (!refs_mod.Refs.isValidRefName(name)) {
        errors.errorf(io, "'{s}' is not a valid tag name", .{name});
    }

    const refs_manager = refs_mod.Refs.init(repo);
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);

    const ref_name = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{name});
    defer allocator.free(ref_name);

    if (refs_manager.read(allocator, io.io, ref_name)) |_| {
        if (!force) {
            errors.errorf(io, "tag '{s}' already exists", .{name});
        }
        refs_manager.delete(allocator, io.io, ref_name) catch {};
    } else |_| {}

    // `gitz tag <name> <commit>` places the tag where asked. The second
    // positional used to overwrite the tag name, so the commit was ignored and
    // the tag silently landed on HEAD.
    const target_sha = if (target_arg) |spec|
        resolveCommitArg(allocator, io, refs_manager, store, spec) orelse
            errors.errorf(io, "not a valid object name: '{s}'", .{spec})
    else
        refs_manager.read(allocator, io.io, "HEAD") catch
            errors.fatal(io, "failed to resolve 'HEAD' as a valid ref", .{});

    if (annotated) {
        // git requires a message for an annotated tag; an empty one was
        // silently accepted.
        const msg = message orelse errors.errorf(io, "no tag message supplied", .{});
        const tag_sha = try createAnnotatedTag(allocator, repo, io, name, msg, target_sha);
        try refs_manager.write(allocator, io.io, ref_name, tag_sha);
    } else {
        try refs_manager.write(allocator, io.io, ref_name, target_sha);
    }

    try io.print("Created tag '{s}'\n", .{name});
}

fn resolveCommitArg(
    allocator: std.mem.Allocator,
    io: Io,
    refs_manager: refs_mod.Refs,
    store: storage_mod.StorageBackend,
    spec: []const u8,
) ?[20]u8 {
    if (refs_manager.read(allocator, io.io, spec)) |sha| return sha else |_| {}

    // HEAD~N / HEAD^N
    if (std.mem.indexOfScalar(u8, spec, '~') != null or std.mem.indexOfScalar(u8, spec, '^') != null) {
        const head = refs_manager.read(allocator, io.io, "HEAD") catch return null;
        var current = head;
        const suffix_start = @min(
            std.mem.indexOfAny(u8, spec, "~^") orelse return null,
            spec.len,
        );
        const suffix = spec[suffix_start + 1 ..];
        var count: usize = 1;
        if (suffix.len > 0) {
            count = std.fmt.parseInt(usize, suffix, 10) catch 1;
        }
        for (0..count) |_| {
            const obj = store.read(allocator, io.io, current) catch return null;
            const commit = switch (obj) {
                .commit => |c| c,
                else => return null,
            };
            if (commit.parents.len == 0) return null;
            current = commit.parents[0];
        }
        return current;
    }

    if (Sha1.fromHex(spec)) |sha| {
        if (store.exists(io.io, sha)) return sha;
        return null;
    } else |_| {}

    return null;
}

fn createAnnotatedTag(
    allocator: std.mem.Allocator,
    repo: Repo,
    io: Io,
    name: []const u8,
    msg: []const u8,
    target_sha: [20]u8,
) ![20]u8 {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);

    const now_ts = std.Io.Timestamp.now(io.io, .real);
    const now: i64 = @intCast(@divTrunc(now_ts.nanoseconds, std.time.ns_per_s));

    // The tagger was hardcoded to "GitZ User <user@gitz.dev>", so every tag was
    // attributed to the wrong identity even with user.name configured.
    const tagger_name = config_cmd.getUserName(allocator, repo.common_dir, io);
    defer if (!std.mem.eql(u8, tagger_name, "GitZ User")) allocator.free(tagger_name);
    const tagger_email = config_cmd.getUserEmail(allocator, repo.common_dir, io);
    defer if (!std.mem.eql(u8, tagger_email, "user@gitz.dev")) allocator.free(tagger_email);

    const tag_obj = object.TagObject{
        .object = target_sha,
        .object_type = .commit,
        .tag_name = name,
        .tagger = .{ .name = tagger_name, .email = tagger_email, .timestamp = now, .timezone = "+0000" },
        .message = msg,
    };

    return store.write(allocator, io.io, object.GitObject{ .tag = tag_obj });
}
