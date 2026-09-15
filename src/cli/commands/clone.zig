const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const zlib_mod = @import("../../core/zlib.zig");
const http = @import("../../transport/http.zig");
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const alternates_mod = @import("../../core/alternates.zig");
const Sha1 = @import("../../core/sha1.zig").Sha1;

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, io: Io) !void {
    // Detect the --local / --shared flag (share objects with an existing repo).
    var shared = false;
    var url_index: usize = 0;
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--local") or std.mem.eql(u8, arg, "--shared")) {
            shared = true;
        } else if (url_index == 0) {
            url_index = i;
        }
    }

    if (args.len == 0 or url_index >= args.len) {
        try io.eprint("usage: gitz clone <url> [directory] [--local]\n", .{});
        std.process.exit(1);
    }

    const url = args[url_index];

    // For a shared clone the source must be a local repository directory.
    // We route it early so no network transport is set up at all — objects are
    // shared via the alternates file instead of being copied/transferred.
    if (shared) {
        cloneShared(allocator, args[url_index..], io, url) catch {
            try io.eprint("fatal: shared clone of '{s}' failed\n", .{url});
            return;
        };
        return;
    }

    const dest = if (args.len > 1) args[1] else dest: {
        const last_slash = std.mem.lastIndexOf(u8, url, "/") orelse url.len;
        var name = url[last_slash..];
        if (name.len > 0 and name[0] == '/') name = name[1..];
        if (std.mem.lastIndexOf(u8, name, ":")) |colon_pos| {
            name = name[colon_pos + 1 ..];
        }
        if (std.mem.endsWith(u8, name, ".git")) {
            name = name[0 .. name.len - 4];
        }
        break :dest name;
    };

    try io.print("Cloning into '{s}'...\n", .{dest});

    // Create destination directory structure
    std.Io.Dir.cwd().createDirPath(io.io, dest) catch {};

    // Create .gitz structure
    const gitz_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dest});
    defer allocator.free(gitz_dir);
    std.Io.Dir.cwd().createDirPath(io.io, gitz_dir) catch {};

    const refs_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/heads", .{dest});
    defer allocator.free(refs_dir);
    std.Io.Dir.cwd().createDirPath(io.io, refs_dir) catch {};

    const tags_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/tags", .{dest});
    defer allocator.free(tags_dir);
    std.Io.Dir.cwd().createDirPath(io.io, tags_dir) catch {};

    const objects_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/objects", .{dest});
    defer allocator.free(objects_dir);
    std.Io.Dir.cwd().createDirPath(io.io, objects_dir) catch {};

    // Write HEAD
    const head_path = try std.fmt.allocPrint(allocator, "{s}/.gitz/HEAD", .{dest});
    defer allocator.free(head_path);
    var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
    defer hf.close(io.io);
    try std.Io.File.writeStreamingAll(hf, io.io, "ref: refs/heads/main\n");

    // Write remote config
    const remotes_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/remotes", .{dest});
    defer allocator.free(remotes_dir);
    std.Io.Dir.cwd().createDirPath(io.io, remotes_dir) catch {};
    const remote_path = try std.fmt.allocPrint(allocator, "{s}/.gitz/remotes/origin", .{dest});
    defer allocator.free(remote_path);
    io.writeFile(remote_path, url) catch {};

    // Use native HTTP transport to discover refs and fetch objects
    var transport = http.HttpTransport.init(allocator, io.io, url) catch {
        try io.eprint("fatal: could not connect to '{s}'\n", .{url});
        return;
    };
    defer transport.deinit();

    const remote_refs = transport.discoverRefs() catch {
        try io.eprint("fatal: could not read from remote repository.\n", .{});
        try io.eprint("Please make sure you have the correct access rights\n", .{});
        try io.eprint("and the repository exists.\n", .{});
        return;
    };
    defer {
        for (remote_refs) |r| allocator.free(r.name);
        allocator.free(remote_refs);
    }

    if (remote_refs.len == 0) {
        try io.eprint("fatal: no refs found on remote\n", .{});
        return;
    }

    // Find default branch (main or master)
    var head_sha: ?[20]u8 = null;
    var default_branch: ?[]const u8 = null;
    for (remote_refs) |ref| {
        if (std.mem.eql(u8, ref.name, "refs/heads/main") or
            std.mem.eql(u8, ref.name, "refs/heads/master"))
        {
            head_sha = ref.sha;
            default_branch = ref.name;
            break;
        }
    }
    if (head_sha == null) {
        head_sha = remote_refs[0].sha;
        default_branch = remote_refs[0].name;
    }

    // Write all remote refs locally
    const refs_manager = refs_mod.Refs.init(gitz_dir);
    var ref_count: u32 = 0;
    for (remote_refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            refs_manager.write(allocator, io.io, ref.name, ref.sha) catch continue;
            ref_count += 1;

            // Write remote-tracking ref
            const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{ref.name[11..]});
            defer allocator.free(remote_ref);
            const remote_ref_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/remotes/origin", .{dest});
            defer allocator.free(remote_ref_dir);
            std.Io.Dir.cwd().createDirPath(io.io, remote_ref_dir) catch {};
            refs_manager.write(allocator, io.io, remote_ref, ref.sha) catch {};
        } else if (std.mem.startsWith(u8, ref.name, "refs/tags/")) {
            refs_manager.write(allocator, io.io, ref.name, ref.sha) catch {};
            ref_count += 1;
        }
    }

    // Set HEAD to default branch
    if (default_branch) |db| {
        const branch_name = if (std.mem.startsWith(u8, db, "refs/heads/")) db[11..] else db;
        const symbolic_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name});
        defer allocator.free(symbolic_ref);
        refs_manager.writeSymbolic(allocator, io.io, "HEAD", symbolic_ref) catch {};
    }

    // Fetch all objects
    transport.fetch(gitz_dir, remote_refs, &.{}) catch {
        try io.eprint("warning: fetch incomplete, some objects may be missing\n", .{});
    };

    // Checkout files from HEAD commit
    if (head_sha) |sha| {
        checkoutFiles(allocator, io, gitz_dir, sha, dest) catch {
            try io.eprint("warning: checkout incomplete\n", .{});
        };
    }

    var object_count: u32 = 0;
    // Count objects in the new repo
    const obj_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/objects", .{dest});
    defer allocator.free(obj_dir);
    countObjects(allocator, io, obj_dir, &object_count) catch {};

    try io.print("Cloned into '{s}'\n", .{dest});
    try io.print("  {d} refs, {d} objects\n", .{ ref_count, object_count });
}

/// Recursively count loose objects in the objects directory.
fn countObjects(allocator: std.mem.Allocator, io: Io, dir_path: []const u8, count: *u32) !void {
    var dir = std.Io.Dir.cwd().openDir(io.io, dir_path, .{}) catch return;
    defer dir.close(io.io);

    var iter = dir.iterate();
    while (iter.next(io.io) catch null) |entry| {
        if (entry.kind == .directory) {
            const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer allocator.free(sub_path);
            try countObjects(allocator, io, sub_path, count);
        } else if (entry.name.len == 38) {
            count.* += 1;
        }
    }
}

/// Checkout files from a commit into a directory.
/// Threads a single StorageBackend through the whole traversal (rather than
/// re-parsing repo config for every entry) and resolves objects through
/// alternates when they are not stored locally (shared clones).
/// Shared (aka --local / --shared) clone: create a new working copy that
/// references the source repository's object store via `objects/info/alternates`
/// instead of copying or re-downloading the objects.
///
/// This is GitZ's answer to "clone that scales": the source acts as a single
/// canonical object store that many cheap clones share. Cloning is instant and
/// uses ~zero extra disk for the shared history.
fn cloneShared(allocator: std.mem.Allocator, args: []const []const u8, io: Io, source: []const u8) !void {
    // Strip a trailing "/.gitz" from the source if given a git dir.
    var source_repo = source;
    if (std.mem.endsWith(u8, source_repo, "/.gitz")) {
        source_repo = source_repo[0 .. source_repo.len - 6];
    } else if (std.mem.endsWith(u8, source_repo, ".gitz")) {
        source_repo = source_repo[0 .. source_repo.len - 5];
    }

    const source_git = try std.fmt.allocPrint(allocator, "{s}/.gitz", .{source_repo});
    defer allocator.free(source_git);

    // Validate the source is a gitz repository.
    const source_head = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{source_git});
    defer allocator.free(source_head);
    if (!io.fileExists(source_head)) {
        try io.eprint("fatal: not a gitz repository: '{s}'\n", .{source_repo});
        return error.NotARepository;
    }

    // Destination name: last path component of the source.
    const dest = if (args.len > 1) args[1] else dest: {
        const trimmed = std.mem.trimEnd(u8, source_repo, "/");
        const last_slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse 0;
        var name = if (last_slash == 0) trimmed else trimmed[last_slash + 1 ..];
        if (name.len == 0) name = "repo";
        if (std.mem.endsWith(u8, name, ".gitz")) {
            name = name[0 .. name.len - 5];
        }
        break :dest name;
    };

    try io.print("Cloning (shared objects) into '{s}'...\n", .{dest});

    // Create destination .gitz structure
    std.Io.Dir.cwd().createDirPath(io.io, dest) catch {};
    const gitz_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dest});
    defer allocator.free(gitz_dir);
    std.Io.Dir.cwd().createDirPath(io.io, gitz_dir) catch {};
    std.Io.Dir.cwd().createDirPath(io.io, try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/heads", .{dest})) catch {};
    std.Io.Dir.cwd().createDirPath(io.io, try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/tags", .{dest})) catch {};
    std.Io.Dir.cwd().createDirPath(io.io, try std.fmt.allocPrint(allocator, "{s}/.gitz/objects", .{dest})) catch {};

    // Write HEAD (symbolic, points at the source default branch if we can tell)
    const head_path = try std.fmt.allocPrint(allocator, "{s}/.gitz/HEAD", .{dest});
    defer allocator.free(head_path);
    var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
    defer hf.close(io.io);
    const source_head_content = std.Io.Dir.cwd().readFileAlloc(io.io, source_head, allocator, .unlimited) catch "ref: refs/heads/main\n";
    defer allocator.free(source_head_content);
    try std.Io.File.writeStreamingAll(hf, io.io, source_head_content);

    // Write remote config pointing at the source
    const remotes_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/remotes", .{dest});
    defer allocator.free(remotes_dir);
    std.Io.Dir.cwd().createDirPath(io.io, remotes_dir) catch {};
    const remote_path = try std.fmt.allocPrint(allocator, "{s}/.gitz/remotes/origin", .{dest});
    defer allocator.free(remote_path);
    io.writeFile(remote_path, source_repo) catch {};

    // Point alternates at the source object store — the key sharing step.
    const source_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{source_git});
    defer allocator.free(source_objects);
    const alts = alternates_mod.Alternates.init(gitz_dir);
    try alts.write(allocator, io.io, &.{source_objects});

    // Copy refs from the source repo (heads and tags).
    const src_refs = refs_mod.Refs.init(source_git);
    const dst_refs = refs_mod.Refs.init(gitz_dir);
    var ref_count: u32 = 0;

    const heads = try src_refs.list(allocator, io.io, "heads");
    defer {
        for (heads) |r| allocator.free(r);
        allocator.free(heads);
    }
    for (heads) |ref| {
        const sha = src_refs.read(allocator, io.io, ref) catch continue;
        dst_refs.write(allocator, io.io, ref, sha) catch continue;
        ref_count += 1;
    }

    const tags = try src_refs.list(allocator, io.io, "tags");
    defer {
        for (tags) |r| allocator.free(r);
        allocator.free(tags);
    }
    for (tags) |ref| {
        const sha = src_refs.read(allocator, io.io, ref) catch continue;
        dst_refs.write(allocator, io.io, ref, sha) catch continue;
        ref_count += 1;
    }

    // Checkout from the shared (alternate) objects.
    if (src_refs.read(allocator, io.io, "HEAD")) |head_sha| {
        checkoutFiles(allocator, io, gitz_dir, head_sha, dest) catch {
            try io.eprint("warning: checkout incomplete\n", .{});
        };
    } else |_| {}

    try io.print("Shared clone complete: '{s}' ({d} refs, objects shared with '{s}')\n", .{ dest, ref_count, source_repo });
}
fn checkoutFiles(allocator: std.mem.Allocator, io: Io, git_dir: []const u8, commit_sha: [20]u8, dest: []const u8) !void {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const alts = alternates_mod.Alternates.init(git_dir);

    // Read commit
    const obj = readWithAlternates(allocator, io, &store, &alts, commit_sha) catch return;
    const commit = switch (obj) {
        .commit => |c| c,
        else => return,
    };
    defer freeGitObject(allocator, obj);

    // Read tree
    const tree_obj = readWithAlternates(allocator, io, &store, &alts, commit.tree) catch return;
    defer freeGitObject(allocator, tree_obj);
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        checkoutTreeEntry(allocator, io, git_dir, &store, &alts, entry, dest) catch continue;
    }
}

/// Read an object from the local store, falling back to the alternates object
/// directories when the object is not present locally (i.e. shared clones).
fn readWithAlternates(
    allocator: std.mem.Allocator,
    io: Io,
    store: *const storage_mod.StorageBackend,
    alts: *const alternates_mod.Alternates,
    sha: [20]u8,
) !object.GitObject {
    return store.read(allocator, io.io, sha) catch {
        return alts.readObject(allocator, io.io, sha);
    };
}

/// Free every allocation made by `object.deserialize` for the given object.
/// Tree/commit/tag payloads allocate strings/slices that must be released
/// explicitly (blob content is the raw reader buffer).
fn freeGitObject(allocator: std.mem.Allocator, obj: object.GitObject) void {
    switch (obj) {
        .blob => |b| allocator.free(b.content),
        .tree => |t| {
            for (t.entries) |e| allocator.free(e.name);
            allocator.free(t.entries);
        },
        .commit => |c| {
            allocator.free(c.parents);
            allocator.free(c.author.name);
            allocator.free(c.author.email);
            allocator.free(c.author.timezone);
            allocator.free(c.committer.name);
            allocator.free(c.committer.email);
            allocator.free(c.committer.timezone);
            allocator.free(c.message);
        },
        .tag => |t| {
            allocator.free(t.tag_name);
            allocator.free(t.tagger.name);
            allocator.free(t.tagger.email);
            allocator.free(t.tagger.timezone);
            allocator.free(t.message);
        },
    }
}

/// Recursively write a tree entry. `base` is the physical directory that this
/// entry belongs to (it grows as we descend into subdirectories).
fn checkoutTreeEntry(
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: []const u8,
    store: *const storage_mod.StorageBackend,
    alts: *const alternates_mod.Alternates,
    entry: object.TreeEntry,
    base: []const u8,
) !void {
    const obj = readWithAlternates(allocator, io, store, alts, entry.sha) catch return;
    defer freeGitObject(allocator, obj);

    switch (obj) {
        .blob => |b| {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, entry.name });
            defer allocator.free(file_path);

            // Ensure parent directory exists
            if (std.fs.path.dirname(file_path)) |dir| {
                std.Io.Dir.cwd().createDirPath(io.io, dir) catch {};
            }

            var file = std.Io.Dir.cwd().createFile(io.io, file_path, .{}) catch return;
            defer file.close(io.io);
            try std.Io.File.writeStreamingAll(file, io.io, b.content);
        },
        .tree => |t| {
            // Recurse into subdirectory — descend with the subdir as the base.
            const sub_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, entry.name });
            defer allocator.free(sub_dir);
            std.Io.Dir.cwd().createDirPath(io.io, sub_dir) catch {};
            for (t.entries) |sub_entry| {
                checkoutTreeEntry(allocator, io, git_dir, store, alts, sub_entry, sub_dir) catch continue;
            }
        },
        else => {},
    }
}

// ============================================================================
// TDD — freeGitObject must release every allocation made by object.deserialize
// (regression: tree/commit/tag payloads leaked because only blob content was
// freed). std.testing.allocator fails the test if anything leaks.
// ============================================================================

test "freeGitObject releases all tree allocations" {
    const allocator = std.testing.allocator;

    var entries: std.ArrayList(object.TreeEntry) = .empty;
    defer entries.deinit(allocator);
    try entries.append(allocator, .{ .mode = 0o100644, .name = try allocator.dupe(u8, "hello.txt"), .sha = Sha1.hash("a") });
    try entries.append(allocator, .{ .mode = 0o40000, .name = try allocator.dupe(u8, "subdir"), .sha = Sha1.hash("b") });

    const tree_obj = object.GitObject{ .tree = .{ .entries = try entries.toOwnedSlice(allocator) } };
    freeGitObject(allocator, tree_obj);
}

test "freeGitObject releases all commit allocations" {
    const allocator = std.testing.allocator;

    const parents = try allocator.alloc([20]u8, 1);
    parents[0] = Sha1.hash("parent");
    const commit_obj = object.GitObject{ .commit = .{
        .tree = Sha1.hash("tree"),
        .parents = parents,
        .author = .{ .name = try allocator.dupe(u8, "A"), .email = try allocator.dupe(u8, "a@b.c"), .timestamp = 1, .timezone = try allocator.dupe(u8, "+0000") },
        .committer = .{ .name = try allocator.dupe(u8, "B"), .email = try allocator.dupe(u8, "b@c.d"), .timestamp = 2, .timezone = try allocator.dupe(u8, "+0100") },
        .message = try allocator.dupe(u8, "msg\n"),
    } };
    freeGitObject(allocator, commit_obj);
}

test "freeGitObject releases all tag allocations" {
    const allocator = std.testing.allocator;

    const tag_obj = object.GitObject{ .tag = .{
        .object = Sha1.hash("target"),
        .object_type = .commit,
        .tag_name = try allocator.dupe(u8, "v1.0"),
        .tagger = .{ .name = try allocator.dupe(u8, "T"), .email = try allocator.dupe(u8, "t@t.t"), .timestamp = 3, .timezone = try allocator.dupe(u8, "+0200") },
        .message = try allocator.dupe(u8, "release\n"),
    } };
    freeGitObject(allocator, tag_obj);
}

test "freeGitObject releases blob content" {
    const allocator = std.testing.allocator;
    const blob_obj = object.GitObject{ .blob = .{ .content = try allocator.dupe(u8, "content") } };
    freeGitObject(allocator, blob_obj);
}
