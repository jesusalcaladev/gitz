const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Fs = @import("../../util/fs.zig").Fs;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const index_mod = @import("../../core/index.zig");
const object = @import("../../core/object.zig");
const storage_mod = @import("../../core/storage.zig");
const ignore_mod = @import("../../core/ignore.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    // `add -A` / `add -u` / `add .` all mean "stage the whole worktree",
    // deletions included. Without `-A` there is still nothing to do.
    var stage_all = false;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--all") or
            std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--update"))
        {
            stage_all = true;
        } else if (std.mem.eql(u8, arg, ".") or std.mem.eql(u8, arg, "./")) {
            // git treats `add .` as "stage everything under here", which
            // includes files that were deleted from the worktree.
            stage_all = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try paths.append(allocator, arg);
        }
    }

    if (!stage_all and paths.items.len == 0) {
        try io.eprint("usage: gitz add [-A|--all] <paths...>\n", .{});
        std.process.exit(1);
    }

    var idx = try index_mod.Index.readFromFile(allocator, git_dir, io.io);
    defer idx.deinit(allocator);

    // Reported after the index has been written, so a bad pathspec alongside
    // good ones does not throw away the work that did resolve.
    var pathspec_failed = false;

    // Load .gitignore rules
    var ignore_stack = ignore_mod.IgnoreStack.init(allocator);
    defer ignore_stack.deinit();
    ignore_stack.loadFile(io.io, ".gitignore") catch {};

    for (paths.items) |path| {
        // Check if path is ignored
        if (ignore_stack.isIgnored(path, false)) {
            continue; // silently skip ignored files
        }
        if (isDirectory(path, io)) {
            try addDirectory(allocator, git_dir, &idx, path, io, &ignore_stack);
        } else {
            addFile(allocator, git_dir, &idx, path, io) catch {
                // A pathspec that no longer exists may be a deletion rather
                // than a typo; only complain when it is in the index nowhere.
                if (!removeIfTracked(allocator, &idx, path)) {
                    try io.eprint("fatal: pathspec '{s}' did not match any files\n", .{path});
                    pathspec_failed = true;
                }
            };
        }
    }

    if (stage_all) {
        try addDirectory(allocator, git_dir, &idx, ".", io, &ignore_stack);
        stageDeletions(allocator, &idx, io);
    }

    try idx.writeToFile(git_dir, allocator, io.io);
    if (pathspec_failed) std.process.exit(128);
}

/// Drop index entries whose file is gone from the working tree. Without this
/// a deleted file is invisible: `status` reported a clean tree and `commit`
/// happily re-created the file in the next commit.
fn stageDeletions(allocator: std.mem.Allocator, idx: *index_mod.Index, io: Io) void {
    var i: usize = 0;
    while (i < idx.entries.items.len) {
        const name = idx.entries.items[i].name;
        if (std.Io.Dir.cwd().access(io.io, name, .{})) |_| {
            i += 1;
        } else |_| {
            _ = idx.remove(allocator, name);
        }
    }
}

fn removeIfTracked(allocator: std.mem.Allocator, idx: *index_mod.Index, path: []const u8) bool {
    const clean = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    if (idx.remove(allocator, clean)) return true;
    for (idx.entries.items) |entry| {
        const name = if (std.mem.startsWith(u8, entry.name, "./")) entry.name[2..] else entry.name;
        if (std.mem.eql(u8, name, clean)) return idx.remove(allocator, entry.name);
    }
    return false;
}

fn addFile(allocator: std.mem.Allocator, git_dir: []const u8, idx: *index_mod.Index, path: []const u8, io: Io) !void {
    var f = io.openFile(path) catch return error.FileNotFound;
    defer f.close(io.io);

    const stat = try std.Io.Dir.cwd().statFile(io.io, path, .{});

    // Read through the file's real size rather than a fixed buffer: a blob
    // larger than the buffer would otherwise be silently truncated, and the
    // index would record a hash of the first N bytes.
    const content = try std.Io.Dir.cwd().readFileAlloc(io.io, path, allocator, .unlimited);
    defer allocator.free(content);

    // Write blob to object store
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const blob = object.GitObject{ .blob = .{ .content = content } };
    const sha = try store.write(allocator, io.io, blob);

    // The mode is part of the index and of every tree entry. Hardcoding
    // 100644 lost the execute bit on scripts and turned symlinks into
    // regular files holding the target's bytes.
    const mode: u32 = switch (stat.kind) {
        .sym_link => 0o120000,
        else => if (stat.permissions.toMode() & 0o111 != 0) 0o100755 else 0o100644,
    };

    try idx.add(allocator, path, sha, .{
        .size = @intCast(@min(stat.size, std.math.maxInt(u32))),
        .mtime = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s)),
        .ctime = @intCast(@divTrunc(stat.ctime.nanoseconds, std.time.ns_per_s)),
        .mode = mode,
    });

    try io.print("add: {s}\n", .{path});
}

fn addDirectory(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    idx: *index_mod.Index,
    dir_path: []const u8,
    io: Io,
    ignore: *ignore_mod.IgnoreStack,
) !void {
    var entries: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
    defer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }

    try collectFiles(allocator, dir_path, &entries, ignore, io);

    for (entries.items) |entry| {
        try addFile(allocator, git_dir, idx, entry, io);
    }
}

fn collectFiles(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    entries: *std.ArrayList([]const u8),
    ignore: *ignore_mod.IgnoreStack,
    io: Io,
) !void {
    var dirs_to_visit: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
    defer {
        for (dirs_to_visit.items) |d| allocator.free(d);
        dirs_to_visit.deinit(allocator);
    }

    // `gitz add dir/` is the same as `gitz add dir`. The trailing slash used to
    // be carried into the composed path, so the index held `dir//file.txt`;
    // writeTree then split at the first `/` and produced a tree entry named
    // `/file.txt`, which is not a legal git object and made the repository
    // permanently corrupt.
    var root = dir_path;
    while (root.len > 1 and root[root.len - 1] == '/') root = root[0 .. root.len - 1];
    const start = if (root.len == 0) "." else root;
    try dirs_to_visit.append(allocator, try allocator.dupe(u8, start));

    while (dirs_to_visit.pop()) |current_z| {
        defer allocator.free(current_z);
        const current = try allocator.dupe(u8, std.mem.sliceTo(current_z, 0));
        defer allocator.free(current);

        var dir = Fs.openIterable(io.io, current) catch continue;
        defer dir.close(io.io);

        var iter = dir.iterate();
        while (iter.next(io.io) catch null) |entry| {
            const skip = (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..") or
                std.mem.eql(u8, entry.name, ".gitz") or std.mem.eql(u8, entry.name, ".git"));
            if (skip) continue;

            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current, entry.name });
            const is_dir = entry.kind == .directory;

            if (ignore.isIgnored(full_path, is_dir)) {
                allocator.free(full_path);
                continue;
            }

            if (is_dir) {
                try dirs_to_visit.append(allocator, full_path);
            } else {
                try entries.append(allocator, full_path);
            }
        }
    }
}

fn isDirectory(path: []const u8, io: Io) bool {
    const dir = Fs.openIterable(io.io, path) catch return false;
    dir.close(io.io);
    return true;
}
