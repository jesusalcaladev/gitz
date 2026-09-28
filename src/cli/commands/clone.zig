const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const zlib_mod = @import("../../core/zlib.zig");
const http = @import("../../transport/http.zig");
const ssh_cmd = @import("../../transport/ssh_cmd.zig");
const ssh_mod = @import("../../transport/ssh.zig");
const refs_mod = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const alternates_mod = @import("../../core/alternates.zig");
const Sha1 = @import("../../core/sha1.zig").Sha1;
const Fs = @import("../../util/fs.zig").Fs;
const errors = @import("../errors.zig");
const config_mod = @import("../../core/config.zig");
const checkout_mod = @import("../../core/checkout.zig");
const index_mod = @import("../../core/index.zig");
const safety = @import("../../util/clone_safety.zig");
const Repo = @import("../../core/repo.zig").Repo;

/// How the objects of a clone are obtained.
const Transport = enum {
    /// `https://` / `http://` — smart HTTP.
    http,
    /// `git@host:path` / `ssh://` — native SSH.
    ssh,
    /// A filesystem path.
    local,
};

/// Classify a clone URL. Anything that is not a remote URL is a local path,
/// which is what makes `gitz clone ../other-repo` work.
fn classifyUrl(allocator: std.mem.Allocator, url: []const u8) !struct { transport: Transport, normalized: []const u8 } {
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
        return .{ .transport = .http, .normalized = try stripTrailingSlash(allocator, url) };
    }
    // Reuse the same URL classifier fetch/push use, so all three agree on what
    // an SSH URL looks like.
    if (ssh_mod.isSshUrl(url)) {
        return .{ .transport = .ssh, .normalized = url };
    }
    return .{ .transport = .local, .normalized = try allocator.dupe(u8, url) };
}

fn stripTrailingSlash(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var out = url;
    while (out.len > 0 and out[out.len - 1] == '/') out = out[0 .. out.len - 1];
    return try allocator.dupe(u8, out);
}

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, io: Io) !void {
    // Only the first non-flag argument is the URL. The previous guard was
    // `url_index == 0`, which stayed true after the index had been set, so
    // `gitz clone <url> <dir>` used <dir> as the endpoint.
    var shared = false;
    var url: ?[]const u8 = null;
    var dest_arg: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--local") or std.mem.eql(u8, arg, "--shared")) {
            shared = true;
        } else if (url == null) {
            url = arg;
        } else if (dest_arg == null and !std.mem.startsWith(u8, arg, "-")) {
            dest_arg = arg;
        }
    }

    const raw_url = url orelse {
        try io.eprint("usage: gitz clone <url> [directory] [--shared]\n", .{});
        std.process.exit(errors.ExitFailure);
    };

    const classified = try classifyUrl(allocator, raw_url);
    defer if (classified.transport == .local) allocator.free(classified.normalized);

    // For a shared clone the source must be a local repository directory. We
    // route it early so no network transport is set up at all — objects are
    // shared via the alternates file instead of being copied/transferred.
    if (shared) {
        if (classified.transport != .local) {
            errors.errorf(io, "--shared requires a local source repository", .{});
        }
        cloneShared(allocator, if (dest_arg) |d| &[_][]const u8{ classified.normalized, d } else &[_][]const u8{classified.normalized}, io, classified.normalized) catch |e| {
            if (e == error.NotARepository) std.process.exit(errors.ExitFailure);
            errors.fatal(io, "shared clone of '{s}' failed", .{raw_url});
        };
        return;
    }

    if (classified.transport == .local) {
        try cloneLocal(allocator, classified.normalized, dest_arg, io);
        return;
    }

    try cloneRemote(allocator, classified.transport, classified.normalized, dest_arg, io);
}

/// Directory name git would derive from a URL: last path component, minus a
/// trailing `.git`.
fn deriveDest(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var name = url;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| name = name[slash + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, name, ':')) |colon| name = name[colon + 1 ..];
    if (std.mem.endsWith(u8, name, ".git")) name = name[0 .. name.len - 4];
    if (name.len == 0) name = "repo";
    return try allocator.dupe(u8, name);
}

/// Failures a clone can hit, mapped to one message each. Transports return
/// these instead of exiting directly, so the caller can remove the
/// half-created destination first: `std.process.exit` skips `errdefer`, so a
/// failed clone would otherwise leave a broken repository on disk.
const CloneError = error{
    ConnectFailed,
    ReadFailed,
    NoRefs,
    FetchFailed,
    CheckoutFailed,
    OutOfMemory,
};

fn removePartialDest(dest: []const u8, io: Io) void {
    std.Io.Dir.cwd().deleteTree(io.io, dest) catch {};
}

/// Resolve `path` against the current directory when it is relative.
/// A repository with no worktrees, where all three directories are the same.
///
/// `gitz clone` builds a fresh repository from scratch, so there is nothing to
/// resolve and no worktree indirection to follow.
fn flat(dir: []const u8) Repo {
    return .{ .common_dir = dir, .worktree_dir = dir, .worktree_path = dir };
}

fn absolutePath(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '/') return try allocator.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(io.io, allocator);
    defer allocator.free(cwd);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, path });
}

fn reportCloneError(io: Io, e: CloneError, url: []const u8) noreturn {
    // `fatal` takes a comptime format string, so the messages are chosen with
    // an if-chain rather than a switch that yields a runtime value.
    if (e == error.ConnectFailed) errors.fatal(io, "could not connect to '{s}'", .{url});
    if (e == error.ReadFailed) errors.fatal(io, "could not read from remote repository '{s}'\nPlease make sure you have the correct access rights and the repository exists", .{url});
    if (e == error.NoRefs) errors.fatal(io, "no refs found on remote '{s}'", .{url});
    if (e == error.FetchFailed) errors.fatal(io, "fetch from '{s}' returned an incomplete packfile", .{url});
    if (e == error.CheckoutFailed) errors.fatal(io, "could not check out '{s}'", .{url});
    errors.fatal(io, "out of memory while cloning '{s}'", .{url});
}

fn cloneRemote(
    allocator: std.mem.Allocator,
    transport_kind: Transport,
    url: []const u8,
    dest_arg: ?[]const u8,
    io: Io,
) !void {
    const dest = if (dest_arg) |d| try allocator.dupe(u8, d) else try deriveDest(allocator, url);
    defer allocator.free(dest);

    try ensureEmptyDestination(io, dest);

    try io.print("Cloning into '{s}'...\n", .{dest});

    _ = createDirPathIfMissing(dest, io) catch false;

    const gitz_dir = initRepoSkeleton(allocator, dest, io) catch {
        removePartialDest(dest, io);
        return error.OutOfMemory;
    };
    defer allocator.free(gitz_dir);

    // The handler is `noreturn`, so the success path just falls through. (An
    // intermediate `const e: CloneError = ... catch |err| err` does not
    // compile here: for `E!void` the catch expression peers to `void`.)
    if (transport_kind == .ssh) {
        cloneOverSsh(allocator, url, dest, gitz_dir, io) catch |err| {
            removePartialDest(dest, io);
            reportCloneError(io, err, url);
        };
    } else {
        cloneOverHttp(allocator, url, dest, gitz_dir, io) catch |err| {
            removePartialDest(dest, io);
            reportCloneError(io, err, url);
        };
    }

    writeRepoConfig(allocator, gitz_dir, io, url) catch {
        removePartialDest(dest, io);
        return error.OutOfMemory;
    };
    finishClone(allocator, gitz_dir, dest, io);
}

fn cloneOverHttp(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest: []const u8,
    gitz_dir: []const u8,
    io: Io,
) CloneError!void {
    var transport = http.HttpTransport.init(allocator, io.io, url) catch return error.ConnectFailed;
    defer transport.deinit();

    const remote_refs = transport.discoverRefs() catch return error.ReadFailed;
    if (remote_refs.len == 0) return error.NoRefs;

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

    const refs_manager = refs_mod.Refs.init(flat(gitz_dir));
    for (remote_refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            refs_manager.write(allocator, io.io, ref.name, ref.sha) catch continue;
            const tracking = std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{ref.name[11..]}) catch continue;
            refs_manager.write(allocator, io.io, tracking, ref.sha) catch {};
            allocator.free(tracking);
        } else if (std.mem.startsWith(u8, ref.name, "refs/tags/")) {
            refs_manager.write(allocator, io.io, ref.name, ref.sha) catch continue;
        }
    }

    if (default_branch) |db| {
        const branch_name = if (std.mem.startsWith(u8, db, "refs/heads/")) db[11..] else db;
        const symbolic = std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name}) catch return error.OutOfMemory;
        refs_manager.writeSymbolic(allocator, io.io, "HEAD", symbolic) catch {};
        allocator.free(symbolic);
    }

    transport.fetch(flat(gitz_dir), remote_refs, &.{}) catch return error.FetchFailed;

    if (head_sha) |sha| {
        checkoutFiles(allocator, io, flat(gitz_dir), sha, dest) catch return error.CheckoutFailed;
    }

    for (remote_refs) |r| allocator.free(r.name);
    allocator.free(remote_refs);
}

fn cloneOverSsh(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest: []const u8,
    gitz_dir: []const u8,
    io: Io,
) !void {
    // Reuse the SSH transport that fetch/push already use, so there is one
    // implementation of the wire protocol rather than two.
    var ssh = ssh_cmd.SshTransport.init(allocator, io.io, url) catch return error.ConnectFailed;
    defer ssh.deinit();

    const refs = ssh.discoverRefs() catch return error.ReadFailed;
    if (refs.len == 0) return error.NoRefs;

    const refs_manager = refs_mod.Refs.init(flat(gitz_dir));
    var head_sha: ?[20]u8 = null;
    var default_branch: ?[]const u8 = null;

    for (refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            refs_manager.write(allocator, io.io, ref.name, ref.sha) catch continue;
            if (head_sha == null) {
                head_sha = ref.sha;
                default_branch = ref.name;
            }
        } else if (std.mem.startsWith(u8, ref.name, "refs/tags/")) {
            refs_manager.write(allocator, io.io, ref.name, ref.sha) catch continue;
        }
    }

    if (default_branch) |db| {
        const branch_name = if (std.mem.startsWith(u8, db, "refs/heads/")) db[11..] else db;
        const symbolic = std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name}) catch return error.OutOfMemory;
        refs_manager.writeSymbolic(allocator, io.io, "HEAD", symbolic) catch {};
        allocator.free(symbolic);
    }

    ssh.fetch(flat(gitz_dir), refs, &.{}) catch return error.FetchFailed;

    if (head_sha) |sha| {
        checkoutFiles(allocator, io, flat(gitz_dir), sha, dest) catch return error.CheckoutFailed;
    }
}

/// Clone from a repository on this filesystem. This is what makes mirroring,
/// CI checkouts and self-hosted setups possible without a network round trip.
fn cloneLocal(
    allocator: std.mem.Allocator,
    source: []const u8,
    dest_arg: ?[]const u8,
    io: Io,
) !void {
    const source_git = try resolveSourceGitDir(allocator, source, io);
    defer allocator.free(source_git);

    if (!io.fileExists(try std.fmt.allocPrint(allocator, "{s}/HEAD", .{source_git}))) {
        errors.fatal(io, "repository '{s}' does not exist", .{source});
    }

    const dest = if (dest_arg) |d| try allocator.dupe(u8, d) else blk: {
        var trimmed = source;
        if (std.mem.endsWith(u8, trimmed, "/")) trimmed = trimmed[0 .. trimmed.len - 1];
        var name = std.fs.path.basename(trimmed);
        if (std.mem.eql(u8, name, ".gitz") or std.mem.eql(u8, name, ".git")) {
            name = std.fs.path.basename(std.fs.path.dirname(trimmed) orelse trimmed);
        }
        if (std.mem.endsWith(u8, name, ".git")) name = name[0 .. name.len - 4];
        if (name.len == 0) name = "repo";
        break :blk try allocator.dupe(u8, name);
    };
    defer allocator.free(dest);

    try ensureEmptyDestination(io, dest);

    try io.print("Cloning into '{s}'...\n", .{dest});

    const gitz_dir = initRepoSkeleton(allocator, dest, io) catch {
        removePartialDest(dest, io);
        return error.OutOfMemory;
    };
    defer allocator.free(gitz_dir);

    // Copy the object store. A shared clone (`--shared`) deliberately skips
    // this and points at the source through alternates instead.
    const src_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{source_git});
    defer allocator.free(src_objects);
    const dst_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{gitz_dir});
    defer allocator.free(dst_objects);
    copyTree(allocator, io, src_objects, dst_objects) catch {};

    // Copy refs and point HEAD at the same branch the source is on.
    const src_refs = refs_mod.Refs.init(flat(source_git));
    const dst_refs = refs_mod.Refs.init(flat(gitz_dir));
    var ref_count: u32 = 0;

    for ([_][]const u8{ "heads", "tags" }) |kind| {
        const list = src_refs.list(allocator, io.io, kind) catch continue;
        defer {
            for (list) |r| allocator.free(r);
            allocator.free(list);
        }
        for (list) |ref| {
            const sha = src_refs.read(allocator, io.io, ref) catch continue;
            dst_refs.write(allocator, io.io, ref, sha) catch continue;
            ref_count += 1;
        }
    }

    if (src_refs.read(allocator, io.io, "HEAD")) |head_sha| {
        // Mirror the source's HEAD shape. Writing the raw sha would leave the
        // clone with a detached HEAD, so every command would report
        // "HEAD detached at ..." instead of a branch name.
        const src_head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{source_git});
        defer allocator.free(src_head_path);
        const src_head = std.Io.Dir.cwd().readFileAlloc(io.io, src_head_path, allocator, .unlimited) catch null;
        defer if (src_head) |sh| allocator.free(sh);

        if (src_head) |sh| {
            const trimmed = std.mem.trim(u8, sh, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                dst_refs.writeSymbolic(allocator, io.io, "HEAD", trimmed[5..]) catch
                    dst_refs.write(allocator, io.io, "HEAD", head_sha) catch {};
            } else {
                dst_refs.write(allocator, io.io, "HEAD", head_sha) catch {};
            }
        } else {
            dst_refs.write(allocator, io.io, "HEAD", head_sha) catch {};
        }

        checkoutFiles(allocator, io, flat(gitz_dir), head_sha, dest) catch {
            removePartialDest(dest, io);
            errors.fatal(io, "could not check out '{s}'", .{source});
        };
    } else |_| {
        removePartialDest(dest, io);
        errors.fatal(io, "source repository '{s}' has no commits", .{source});
    }

    writeRepoConfig(allocator, gitz_dir, io, source) catch {
        removePartialDest(dest, io);
        return error.OutOfMemory;
    };
    finishClone(allocator, gitz_dir, dest, io);
}

/// Accept both a worktree (`/path/repo`) and a git dir (`/path/repo/.gitz`,
/// `/path/repo/.git`, or a bare `/path/repo.git`).
fn resolveSourceGitDir(allocator: std.mem.Allocator, source: []const u8, io: Io) ![]const u8 {
    for ([_][]const u8{ ".gitz", ".git" }) |n| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source, n });
        if (std.Io.Dir.cwd().access(io.io, p, .{})) |_| {
            return p;
        } else |_| {
            allocator.free(p);
        }
    }

    // Bare repository: the path itself is the git dir.
    const objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{source});
    defer allocator.free(objects);
    std.Io.Dir.cwd().access(io.io, objects, .{}) catch
        errors.fatal(io, "not a repository: '{s}'", .{source});
    return try allocator.dupe(u8, source);
}

fn createDirPathIfMissing(path: []const u8, io: Io) !bool {
    std.Io.Dir.cwd().access(io.io, path, .{}) catch {
        try std.Io.Dir.cwd().createDirPath(io.io, path);
        return true;
    };
    return false;
}

fn isNonEmptyDir(path: []const u8, io: Io) !bool {
    const dir = Fs.openIterable(io.io, path) catch return false;
    defer dir.close(io.io);
    var iter = dir.iterate();
    while (iter.next(io.io) catch null) |_| return true;
    return false;
}

/// Refuse to clone into something that already has content in it, or that is
/// a symlink: a clone must land where the user named it, not wherever a link
/// points.
fn ensureEmptyDestination(io: Io, dest: []const u8) !void {
    safety.ensureEmptyDestination(io.io, dest) catch |err| switch (err) {
        error.DestinationNotEmpty => errors.fatal(io, "destination path '{s}' already exists and is not an empty directory", .{dest}),
        else => return err,
    };
}

/// Create `.gitz` with the directory layout and an initial HEAD.
fn initRepoSkeleton(allocator: std.mem.Allocator, dest: []const u8, io: Io) ![]const u8 {
    const gitz_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dest});

    for ([_][]const u8{ "", "refs/heads", "refs/tags", "objects" }) |sub| {
        const p = if (sub.len == 0)
            try allocator.dupe(u8, gitz_dir)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ gitz_dir, sub });
        defer allocator.free(p);
        std.Io.Dir.cwd().createDirPath(io.io, p) catch {};
    }

    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{gitz_dir});
    defer allocator.free(head_path);
    const hf = std.Io.Dir.cwd().createFile(io.io, head_path, .{}) catch null;
    if (hf) |f| {
        defer f.close(io.io);
        std.Io.File.writeStreamingAll(f, io.io, "ref: refs/heads/main\n") catch {};
    }
    return gitz_dir;
}

/// Write `.gitz/config` with the remote, using the same shape `gitz init`
/// produces. `remote.zig:getRemoteUrl` reads the remote from here, so without
/// this a freshly cloned repository had no remote at all: `gitz remote list`
/// printed "No remotes configured." and `gitz push` failed.
fn writeRepoConfig(allocator: std.mem.Allocator, gitz_dir: []const u8, io: Io, remote_url: []const u8) !void {
    var cfg = config_mod.Config.init(allocator);
    defer cfg.deinit();

    try cfg.set("core", "repositoryformatversion", "0");
    try cfg.set("core", "filemode", "true");
    try cfg.set("core", "bare", "false");
    try cfg.set("core", "logallrefupdates", "true");
    try cfg.set("remote \"origin\"", "url", remote_url);
    try cfg.set("remote \"origin\"", "fetch", "+refs/heads/*:refs/remotes/origin/*");

    const serialized = try cfg.serialize(allocator);
    defer allocator.free(serialized);

    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{gitz_dir});
    defer allocator.free(config_path);
    io.writeFile(config_path, serialized) catch
        errors.fatal(io, "could not write '{s}'", .{config_path});
}

/// Shared tail of every clone: rebuild the index so `gitz status` is clean, then
/// report the result.
fn finishClone(allocator: std.mem.Allocator, gitz_dir: []const u8, dest: []const u8, io: Io) void {
    // The index is written by checkoutFiles as it walks the tree, so there is
    // nothing to rebuild here: in a shared clone the blobs only exist in the
    // alternates, and a later rebuild from the clone's own store would come up
    // empty and report every file as untracked.
    const objects_dir = std.fmt.allocPrint(allocator, "{s}/objects", .{gitz_dir}) catch return;
    defer allocator.free(objects_dir);
    const object_count = Fs.countLooseObjects(io.io, objects_dir);

    io.print("Cloned into '{s}'\n", .{dest}) catch {};
    io.print("  {d} objects\n", .{object_count}) catch {};
}

/// Recursively copy `from` into `to`, creating directories as needed.
fn copyTree(allocator: std.mem.Allocator, io: Io, from: []const u8, to: []const u8) !void {
    var dir = Fs.openIterable(io.io, from) catch return;
    defer dir.close(io.io);

    var iter = dir.iterate();
    while (try iter.next(io.io)) |entry| {
        const src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ from, entry.name });
        defer allocator.free(src);
        const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ to, entry.name });
        errdefer allocator.free(dst);

        switch (entry.kind) {
            .directory => {
                try std.Io.Dir.cwd().createDirPath(io.io, dst);
                try copyTree(allocator, io, src, dst);
            },
            .file => {
                const content = try std.Io.Dir.cwd().readFileAlloc(io.io, src, allocator, .unlimited);
                defer allocator.free(content);
                if (std.fs.path.dirname(dst)) |parent| {
                    std.Io.Dir.cwd().createDirPath(io.io, parent) catch {};
                }
                try std.Io.Dir.cwd().writeFile(io.io, .{ .sub_path = dst, .data = content });
            },
            else => {},
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

    // Write the remote into `.gitz/config` (the same place `gitz remote add`
    // and `gitz init` use) instead of a bespoke `.gitz/remotes/origin` file that
    // nothing else in the codebase reads.
    try writeRepoConfig(allocator, gitz_dir, io, source_repo);

    // Point alternates at the source object store — the key sharing step.
    // The path must be absolute: git resolves entries in
    // `objects/info/alternates` relative to the *reading* repository, so a
    // relative path such as `src/.gitz/objects` would be looked up inside the
    // clone itself.
    const source_objects = try absolutePath(allocator, io, try std.fmt.allocPrint(allocator, "{s}/objects", .{source_git}));
    defer allocator.free(source_objects);
    const alts = alternates_mod.Alternates.init(gitz_dir);
    try alts.write(allocator, io.io, &.{source_objects});

    // Copy refs from the source repo (heads and tags). Both sides are plain
    // repositories here, so the common, worktree and path roles collapse to a
    // single directory.
    const src_refs = refs_mod.Refs.init(flat(source_git));
    const dst_refs = refs_mod.Refs.init(flat(gitz_dir));
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

    // Checkout from the shared (alternate) objects. `checkoutFiles` builds the
    // index as it walks, resolving blobs through the alternates, so the clone
    // reports a clean tree instead of every file as untracked.
    if (src_refs.read(allocator, io.io, "HEAD")) |head_sha| {
        checkoutFiles(allocator, io, flat(gitz_dir), head_sha, dest) catch {
            removePartialDest(dest, io);
            errors.fatal(io, "could not check out '{s}'", .{source_repo});
        };
    } else |_| {}

    try io.print("Shared clone complete: '{s}' ({d} refs, objects shared with '{s}')\n", .{ dest, ref_count, source_repo });
}
/// Check out `commit_sha` into `dest`, building the index as it goes.
///
/// The index is produced here rather than afterwards: the blobs are resolved
/// through the alternates in a shared clone, so rebuilding the index from the
/// clone's own object store afterwards would find nothing and report every file
/// as untracked.
fn checkoutFiles(allocator: std.mem.Allocator, io: Io, repo: Repo, commit_sha: [20]u8, dest: []const u8) !void {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);
    var alts = try alternates_mod.Reader.init(allocator, io.io, repo.common_dir);
    defer alts.deinit();

    const obj = try readWithAlternates(allocator, io, &store, &alts, commit_sha);
    const commit = switch (obj) {
        .commit => |c| c,
        else => return error.ExpectedCommit,
    };
    defer freeGitObject(allocator, obj);

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
    try idx.writeToFile(repo.worktree_dir, allocator, io.io);
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

/// Reject tree entry names that could escape the destination directory.
fn validateCheckoutEntryName(name: []const u8) !void {
    return safety.validateTreeEntryName(name);
}

/// Recursively write a tree entry. `base` is the physical directory that this
/// entry belongs to (it grows as we descend into subdirectories).
///
/// Each name is validated and each file is created exclusively, so a hostile
/// tree cannot write outside `dest` or clobber a file that is already there.
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
                const name = if (relative_base.len == 0)
                    try allocator.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_base, entry.name });
                idx.add(allocator, name, entry.sha, .{ .mode = entry.mode }) catch {
                    allocator.free(name);
                };
            }
        },
        .tree => |t| {
            const sub_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, entry.name });
            defer allocator.free(sub_dir);
            try std.Io.Dir.cwd().createDirPath(io.io, sub_dir);
            const sub_relative = if (relative_base.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_base, entry.name });
            defer allocator.free(sub_relative);
            for (t.entries) |sub_entry| {
                try checkoutTreeEntry(allocator, io, store, alts, sub_entry, sub_dir, sub_relative, index);
            }
        },
        else => return error.ExpectedBlobOrTree,
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
