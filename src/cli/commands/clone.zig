const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const safety = @import("../../util/clone_safety.zig");
const http = @import("../../transport/http.zig");
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const index_mod = @import("../../core/index.zig");
const alternates_mod = @import("../../core/alternates.zig");
const Sha1 = @import("../../core/sha1.zig").Sha1;

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, io: Io) !void {
    executeClone(allocator, args, io) catch |err| {
        try io.eprint("fatal: clone failed: {s}\n", .{@errorName(err)});
        std.process.exit(128);
    };
}

fn executeClone(allocator: std.mem.Allocator, args: []const []const u8, io: Io) !void {
    // Detect the --local / --shared flag (share objects with an existing repo).
    var shared = false;
    var url: ?[]const u8 = null;
    var explicit_dest: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--local") or std.mem.eql(u8, arg, "--shared")) {
            shared = true;
        } else if (url == null) {
            url = arg;
        } else if (explicit_dest == null) {
            explicit_dest = arg;
        } else {
            try io.eprint("usage: gitz clone <url> [directory] [--local]\n", .{});
            std.process.exit(1);
        }
    }

    const source = url orelse {
        try io.eprint("usage: gitz clone <url> [directory] [--local]\n", .{});
        std.process.exit(1);
    };

    // For a shared clone the source must be a local repository directory.
    // We route it early so no network transport is set up at all — objects are
    // shared via the alternates file instead of being copied/transferred.
    if (shared) return cloneShared(allocator, source, explicit_dest, io);

    const dest = explicit_dest orelse dest: {
        const last_slash = std.mem.lastIndexOf(u8, source, "/") orelse source.len;
        var name = source[last_slash..];
        if (name.len > 0 and name[0] == '/') name = name[1..];
        if (std.mem.lastIndexOf(u8, name, ":")) |colon_pos| {
            name = name[colon_pos + 1 ..];
        }
        if (std.mem.endsWith(u8, name, ".git")) {
            name = name[0 .. name.len - 4];
        }
        break :dest name;
    };

    try ensureEmptyDestination(io.io, dest);
    try io.print("Cloning into '{s}'...\n", .{dest});

    // Create destination directory structure
    try std.Io.Dir.cwd().createDirPath(io.io, dest);

    // Create .gitz structure
    const gitz_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dest});
    defer allocator.free(gitz_dir);
    try std.Io.Dir.cwd().createDirPath(io.io, gitz_dir);

    const refs_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/heads", .{dest});
    defer allocator.free(refs_dir);
    try std.Io.Dir.cwd().createDirPath(io.io, refs_dir);

    const tags_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/tags", .{dest});
    defer allocator.free(tags_dir);
    try std.Io.Dir.cwd().createDirPath(io.io, tags_dir);

    const objects_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/objects", .{dest});
    defer allocator.free(objects_dir);
    try std.Io.Dir.cwd().createDirPath(io.io, objects_dir);

    // Write HEAD
    const head_path = try std.fmt.allocPrint(allocator, "{s}/.gitz/HEAD", .{dest});
    defer allocator.free(head_path);
    var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
    defer hf.close(io.io);
    try std.Io.File.writeStreamingAll(hf, io.io, "ref: refs/heads/main\n");

    // Write remote config
    const remotes_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/remotes", .{dest});
    defer allocator.free(remotes_dir);
    try std.Io.Dir.cwd().createDirPath(io.io, remotes_dir);
    const remote_path = try std.fmt.allocPrint(allocator, "{s}/.gitz/remotes/origin", .{dest});
    defer allocator.free(remote_path);
    try io.writeFile(remote_path, source);

    // Use native HTTP transport to discover refs and fetch objects
    var transport = http.HttpTransport.init(allocator, io.io, source) catch |err| {
        try io.eprint("fatal: could not connect to '{s}' ({s})\n", .{ source, @errorName(err) });
        return err;
    };
    defer transport.deinit();

    const remote_refs = transport.discoverRefs() catch |err| {
        try io.eprint("fatal: could not read from remote repository ({s}).\n", .{@errorName(err)});
        try io.eprint("Please make sure you have the correct access rights\n", .{});
        try io.eprint("and the repository exists.\n", .{});
        return err;
    };
    defer {
        for (remote_refs) |r| allocator.free(r.name);
        allocator.free(remote_refs);
    }

    if (remote_refs.len == 0) {
        try io.eprint("fatal: no refs found on remote\n", .{});
        return error.NoRefsFound;
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
            try refs_manager.write(allocator, io.io, ref.name, ref.sha);
            ref_count += 1;

            // Write remote-tracking ref
            const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{ref.name[11..]});
            defer allocator.free(remote_ref);
            const remote_ref_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/remotes/origin", .{dest});
            defer allocator.free(remote_ref_dir);
            try std.Io.Dir.cwd().createDirPath(io.io, remote_ref_dir);
            try refs_manager.write(allocator, io.io, remote_ref, ref.sha);
        } else if (std.mem.startsWith(u8, ref.name, "refs/tags/")) {
            try refs_manager.write(allocator, io.io, ref.name, ref.sha);
            ref_count += 1;
        }
    }

    // Set HEAD to default branch
    if (default_branch) |db| {
        const branch_name = if (std.mem.startsWith(u8, db, "refs/heads/")) db[11..] else db;
        const symbolic_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name});
        defer allocator.free(symbolic_ref);
        try refs_manager.writeSymbolic(allocator, io.io, "HEAD", symbolic_ref);
    }

    // Fetch all objects
    try transport.fetch(gitz_dir, remote_refs, &.{});

    // Checkout files from HEAD commit
    if (head_sha) |sha| {
        try checkoutFiles(allocator, io, gitz_dir, sha, dest);
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
fn cloneShared(allocator: std.mem.Allocator, source: []const u8, explicit_dest: ?[]const u8, io: Io) !void {
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
    const dest = explicit_dest orelse dest: {
        const trimmed = std.mem.trimEnd(u8, source_repo, "/");
        const last_slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse 0;
        var name = if (last_slash == 0) trimmed else trimmed[last_slash + 1 ..];
        if (name.len == 0) name = "repo";
        if (std.mem.endsWith(u8, name, ".gitz")) {
            name = name[0 .. name.len - 5];
        }
        break :dest name;
    };

    try ensureEmptyDestination(io.io, dest);
    try io.print("Cloning (shared objects) into '{s}'...\n", .{dest});

    // Create destination .gitz structure
    try std.Io.Dir.cwd().createDirPath(io.io, dest);
    const gitz_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dest});
    defer allocator.free(gitz_dir);
    try std.Io.Dir.cwd().createDirPath(io.io, gitz_dir);
    const shared_refs_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/heads", .{dest});
    defer allocator.free(shared_refs_dir);
    try std.Io.Dir.cwd().createDirPath(io.io, shared_refs_dir);
    const shared_tags_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/tags", .{dest});
    defer allocator.free(shared_tags_dir);
    try std.Io.Dir.cwd().createDirPath(io.io, shared_tags_dir);
    const shared_objects_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/objects", .{dest});
    defer allocator.free(shared_objects_dir);
    try std.Io.Dir.cwd().createDirPath(io.io, shared_objects_dir);

    // Write HEAD (symbolic, points at the source default branch if we can tell)
    const head_path = try std.fmt.allocPrint(allocator, "{s}/.gitz/HEAD", .{dest});
    defer allocator.free(head_path);
    var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
    defer hf.close(io.io);
    const source_head_content = try std.Io.Dir.cwd().readFileAlloc(io.io, source_head, allocator, .unlimited);
    defer allocator.free(source_head_content);
    try std.Io.File.writeStreamingAll(hf, io.io, source_head_content);

    // Write remote config pointing at the source
    const remotes_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/remotes", .{dest});
    defer allocator.free(remotes_dir);
    try std.Io.Dir.cwd().createDirPath(io.io, remotes_dir);
    const remote_path = try std.fmt.allocPrint(allocator, "{s}/.gitz/remotes/origin", .{dest});
    defer allocator.free(remote_path);
    try io.writeFile(remote_path, source_repo);

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
        const sha = try src_refs.read(allocator, io.io, ref);
        try dst_refs.write(allocator, io.io, ref, sha);
        ref_count += 1;
    }

    const tags = try src_refs.list(allocator, io.io, "tags");
    defer {
        for (tags) |r| allocator.free(r);
        allocator.free(tags);
    }
    for (tags) |ref| {
        const sha = try src_refs.read(allocator, io.io, ref);
        try dst_refs.write(allocator, io.io, ref, sha);
        ref_count += 1;
    }

    // Checkout from the shared (alternate) objects. A source without a
    // resolvable HEAD is incomplete and must not be reported as a success.
    const head_sha = try src_refs.read(allocator, io.io, "HEAD");
    try checkoutFiles(allocator, io, gitz_dir, head_sha, dest);

    try io.print("Shared clone complete: '{s}' ({d} refs, objects shared with '{s}')\n", .{ dest, ref_count, source_repo });
}
fn checkoutFiles(allocator: std.mem.Allocator, io: Io, git_dir: []const u8, commit_sha: [20]u8, dest: []const u8) !void {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    var alts = try alternates_mod.Reader.init(allocator, io.io, git_dir);
    defer alts.deinit();

    // Read commit
    const obj = try readWithAlternates(allocator, io, &store, &alts, commit_sha);
    const commit = switch (obj) {
        .commit => |c| c,
        else => return error.ExpectedCommit,
    };
    defer freeGitObject(allocator, obj);

    // Read tree
    const tree_obj = try readWithAlternates(allocator, io, &store, &alts, commit.tree);
    defer freeGitObject(allocator, tree_obj);
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return error.ExpectedTree,
    };

    var idx = index_mod.Index.init(allocator);
    defer idx.deinit(allocator);
    for (tree.entries) |entry| {
        try checkoutTreeEntry(allocator, io, &store, &alts, entry, dest, "", &idx);
    }
    try idx.writeToFile(git_dir, allocator, io.io);
}

/// Read an object from the local store, falling back to the alternates object
/// directories when the object is not present locally (i.e. shared clones).
fn readWithAlternates(
    allocator: std.mem.Allocator,
    io: Io,
    store: *const storage_mod.StorageBackend,
    alts: *const alternates_mod.Reader,
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

fn validateCheckoutEntryName(name: []const u8) !void {
    return safety.validateTreeEntryName(name);
}

fn ensureEmptyDestination(io: std.Io, dest: []const u8) !void {
    return safety.ensureEmptyDestination(io, dest);
}

/// Recursively write a tree entry. `base` is the physical directory that this
/// entry belongs to (it grows as we descend into subdirectories).
fn checkoutTreeEntry(
    allocator: std.mem.Allocator,
    io: Io,
    store: *const storage_mod.StorageBackend,
    alts: *const alternates_mod.Reader,
    entry: object.TreeEntry,
    base: []const u8,
    relative_base: []const u8,
    index: ?*index_mod.Index,
) !void {
    try validateCheckoutEntryName(entry.name);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, entry.name });
    defer allocator.free(file_path);
    if (std.Io.Dir.cwd().access(io.io, file_path, .{})) |_| {
        return error.CheckoutPathAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const obj = try readWithAlternates(allocator, io, store, alts, entry.sha);
    defer freeGitObject(allocator, obj);

    switch (obj) {
        .blob => |b| {
            if (std.fs.path.dirname(file_path)) |dir| {
                try std.Io.Dir.cwd().createDirPath(io.io, dir);
            }
            var file = try std.Io.Dir.cwd().createFile(io.io, file_path, .{ .exclusive = true });
            defer file.close(io.io);
            try std.Io.File.writeStreamingAll(file, io.io, b.content);

            if (index) |idx| {
                const relative_path = if (relative_base.len == 0)
                    try allocator.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_base, entry.name });
                defer allocator.free(relative_path);
                const stat = try std.Io.Dir.cwd().statFile(io.io, file_path, .{});
                try idx.add(allocator, relative_path, entry.sha, .{
                    .size = @intCast(b.content.len),
                    .mtime = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s)),
                    .ctime = @intCast(@divTrunc(stat.ctime.nanoseconds, std.time.ns_per_s)),
                    .mode = entry.mode,
                });
            }
        },
        .tree => |t| {
            try std.Io.Dir.cwd().createDirPath(io.io, file_path);
            const sub_relative = if (relative_base.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_base, entry.name });
            defer allocator.free(sub_relative);
            for (t.entries) |sub_entry| {
                try checkoutTreeEntry(allocator, io, store, alts, sub_entry, file_path, sub_relative, index);
            }
        },
        else => return error.ExpectedBlobOrTree,
    }
}

// ============================================================================
// Clone path-safety regressions
// ============================================================================

test "checkout entry names are exactly one safe relative component" {
    const valid = [_][]const u8{ "README.md", "file:name", "name.", "..name", "..." };
    for (valid) |name| try validateCheckoutEntryName(name);

    const invalid = [_][]const u8{
        "",          ".",          "..",           "/",           "\\",         "dir/file", "dir\\file",
        "/absolute", "\\absolute", "C:\\absolute", "c:/absolute", "C:relative", ".gitz",    ".GITZ",
        ".GiTz",
    };
    for (invalid) |name| {
        try std.testing.expectError(error.UnsafeCheckoutEntryName, validateCheckoutEntryName(name));
    }
}

test "malicious checkout entry is rejected before object access" {
    const allocator = std.testing.allocator;
    const io = Io.init(std.testing.io, allocator, std.process.Environ.empty);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dest = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/work/clone", .{tmp.sub_path});
    defer allocator.free(dest);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dest);

    const store = storage_mod.StorageBackend.looseBackend(dest);
    var alts = try alternates_mod.Reader.init(allocator, std.testing.io, dest);
    defer alts.deinit();
    const entry = object.TreeEntry{
        .mode = 0o100644,
        .name = "../../victim.txt",
        .sha = Sha1.hash("not-present"),
    };

    try std.testing.expectError(
        error.UnsafeCheckoutEntryName,
        checkoutTreeEntry(allocator, io, &store, &alts, entry, dest, "", null),
    );
}

test "clone destination accepts missing and empty directories only" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const missing = try std.fmt.allocPrint(allocator, "{s}/missing", .{root});
    defer allocator.free(missing);
    const empty = try std.fmt.allocPrint(allocator, "{s}/empty", .{root});
    defer allocator.free(empty);
    const occupied = try std.fmt.allocPrint(allocator, "{s}/occupied", .{root});
    defer allocator.free(occupied);
    const file = try std.fmt.allocPrint(allocator, "{s}/file", .{root});
    defer allocator.free(file);
    const child = try std.fmt.allocPrint(allocator, "{s}/child", .{occupied});
    defer allocator.free(child);

    try ensureEmptyDestination(io, missing);
    try std.Io.Dir.cwd().createDirPath(io, empty);
    try std.Io.Dir.cwd().createDirPath(io, occupied);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = child, .data = "keep" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "keep" });

    try ensureEmptyDestination(io, empty);
    try std.testing.expectError(error.DestinationNotEmpty, ensureEmptyDestination(io, occupied));
    try std.testing.expectError(error.DestinationNotEmpty, ensureEmptyDestination(io, file));
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
