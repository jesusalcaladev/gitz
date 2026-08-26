const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");
const index_mod = @import("../../core/index.zig");
const ignore_mod = @import("../../core/ignore.zig");
const ui = @import("../../util/ui.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var dry_run = false;
    var force = false;
    var include_dirs = false;
    var interactive = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--dirs")) {
            include_dirs = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, arg, "-x")) {
            // Include ignored files too
        } else if (std.mem.eql(u8, arg, "-fd")) {
            force = true;
            include_dirs = true;
        } else if (std.mem.eql(u8, arg, "-fdx")) {
            force = true;
            include_dirs = true;
        }
    }

    if (!force and !dry_run and !interactive) {
        try io.eprint("fatal: clean requires -f, -n, or -i\n", .{});
        try io.eprint("usage: gitz clean [-f|-n|-i] [-d] [-x]\n", .{});
        return;
    }

    // Collect tracked files from HEAD
    var tracked = std.StringHashMap(void).init(allocator);
    defer tracked.deinit();

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const refs_manager = refs_mod.Refs.init(git_dir);

    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch null;
    if (head_sha) |sha| {
        collectTrackedPaths(allocator, store, io.io, sha, "", &tracked);
    }

    // Also add indexed files
    var idx = index_mod.Index.readFromFile(allocator, git_dir, io.io) catch null;
    if (idx) |*i| {
        defer i.deinit(allocator);
        for (i.entries.items) |entry| {
            const clean_name = if (std.mem.startsWith(u8, entry.name, "./"))
                entry.name[2..]
            else
                entry.name;
            tracked.put(clean_name, {}) catch {};
        }
    }

    // Load .gitignore
    var ignore_stack = ignore_mod.IgnoreStack.init(allocator);
    defer ignore_stack.deinit();
    ignore_stack.loadFile(io.io, ".gitignore") catch {};

    // Scan working directory for untracked files
    var untracked_files = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer {
        for (untracked_files.items) |f| allocator.free(f);
        untracked_files.deinit(allocator);
    }

    try collectUntracked(allocator, git_dir, io.io, "", &tracked, &ignore_stack, &untracked_files, include_dirs);

    if (untracked_files.items.len == 0) {
        try io.print("Nothing to clean.\n", .{});
        return;
    }

    // Show what will be deleted
    var total_size: u64 = 0;
    for (untracked_files.items) |file_path| {
        const stat = std.Io.Dir.cwd().statFile(io.io, file_path, .{}) catch continue;
        total_size += stat.size;

        if (dry_run) {
            try io.print("Would remove {s}{s}{s}\n", .{ ui.c.red, file_path, ui.c.reset });
        } else {
            try io.print("Removing {s}{s}{s}\n", .{ ui.c.red, file_path, ui.c.reset });
        }
    }

    if (dry_run) {
        try io.print("\n{s}{d}{s} file{s} would be removed ({d} bytes)\n", .{
            ui.c.yellow, untracked_files.items.len, ui.c.reset,
            if (untracked_files.items.len != 1) "s" else "",
            total_size,
        });
        return;
    }

    // Actually delete files
    var deleted: usize = 0;
    for (untracked_files.items) |file_path| {
        std.Io.Dir.cwd().deleteFile(io.io, file_path) catch |err| {
            if (!include_dirs) {
                try io.eprint("warning: could not remove '{s}': {}\n", .{ file_path, err });
            }
            continue;
        };
        deleted += 1;
    }

    try io.print("\n{s}{s}{s} {d} file{s} removed ({d} bytes)\n", .{
        ui.c.bgreen, ui.sym.ok, ui.c.reset,
        deleted,
        if (deleted != 1) "s" else "",
        total_size,
    });
}

fn collectTrackedPaths(
    allocator: std.mem.Allocator,
    store: storage_mod.StorageBackend,
    io: std.Io,
    sha: [20]u8,
    prefix: []const u8,
    tracked: *std.StringHashMap(void),
) void {
    const obj = store.read(allocator, io, sha) catch return;
    const commit = switch (obj) {
        .commit => |c| c,
        else => return,
    };

    collectTreePaths(allocator, store, io, commit.tree, prefix, tracked);
}

fn collectTreePaths(
    allocator: std.mem.Allocator,
    store: storage_mod.StorageBackend,
    io: std.Io,
    tree_sha: [20]u8,
    prefix: []const u8,
    tracked: *std.StringHashMap(void),
) void {
    const obj = store.read(allocator, io, tree_sha) catch return;
    const tree = switch (obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        const full_path = if (prefix.len > 0)
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name }) catch continue
        else
            allocator.dupe(u8, entry.name) catch continue;

        if (entry.mode == 0o040000) {
            collectTreePaths(allocator, store, io, entry.sha, full_path, tracked);
            allocator.free(full_path);
        } else {
            tracked.put(full_path, {}) catch {
                allocator.free(full_path);
            };
        }
    }
}

fn collectUntracked(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.Io,
    prefix: []const u8,
    tracked: *const std.StringHashMap(void),
    ignore: *const ignore_mod.IgnoreStack,
    untracked: *std.ArrayList([]const u8),
    include_dirs: bool,
) !void {
    var dirs_to_visit = std.ArrayList(struct { path: []const u8, prefix: []const u8 }){ .items = &.{}, .capacity = 0 };
    defer {
        for (dirs_to_visit.items) |item| {
            allocator.free(item.path);
            allocator.free(item.prefix);
        }
        dirs_to_visit.deinit(allocator);
    }

    const initial_path = if (prefix.len > 0)
        try allocator.dupe(u8, prefix)
    else
        try allocator.dupe(u8, ".");
    const initial_prefix = try allocator.dupe(u8, prefix);
    try dirs_to_visit.append(allocator, .{ .path = initial_path, .prefix = initial_prefix });

    while (dirs_to_visit.items.len > 0) {
        const item = dirs_to_visit.pop() orelse break;
        defer allocator.free(item.path);
        defer allocator.free(item.prefix);

        const current_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{item.path}, 0);
        defer allocator.free(current_z);

        const fd = std.posix.openat(std.posix.AT.FDCWD, current_z, std.posix.O{ .ACCMODE = .RDONLY }, 0) catch continue;
        defer {
            _ = std.os.linux.close(@intCast(fd));
        }

        var buf: [4096]u8 align(@alignOf(usize)) = undefined;
        while (true) {
            const rc = std.os.linux.getdents64(@intCast(fd), &buf, buf.len);
            const n: usize = if (rc > 0) @intCast(rc) else break;
            if (n == 0) break;

            var pos: usize = 0;
            while (pos < n) {
                const direntry: *align(1) const std.os.linux.dirent64 = @ptrCast(&buf[pos]);
                const name: []const u8 = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&direntry.name)), 0);

                const skip = (name.len == 1 and name[0] == '.') or
                    (name.len == 2 and name[0] == '.' and name[1] == '.') or
                    (name.len == 5 and std.mem.eql(u8, name, ".gitz"));
                if (!skip) {
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ item.path, name });
                    const rel_path = if (item.prefix.len > 0)
                        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ item.prefix, name })
                    else
                        try allocator.dupe(u8, name);

                    const is_dir = blk: {
                        const fp_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{full_path}, 0);
                        defer allocator.free(fp_z);
                        const sub_fd = std.posix.openat(std.posix.AT.FDCWD, fp_z, std.posix.O{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch break :blk false;
                        _ = std.os.linux.close(@intCast(sub_fd));
                        break :blk true;
                    };

                    if (is_dir) {
                        if (!ignore.isIgnored(rel_path, true)) {
                            try dirs_to_visit.append(allocator, .{ .path = full_path, .prefix = rel_path });
                            if (include_dirs and !tracked.contains(rel_path)) {
                                try untracked.append(allocator, full_path);
                                continue;
                            }
                        } else {
                            allocator.free(full_path);
                        }
                        allocator.free(rel_path);
                    } else {
                        if (ignore.isIgnored(rel_path, false) or tracked.contains(rel_path)) {
                            allocator.free(full_path);
                            allocator.free(rel_path);
                        } else {
                            try untracked.append(allocator, full_path);
                            allocator.free(rel_path);
                        }
                    }
                }
                pos += direntry.reclen;
            }
        }
    }
}
