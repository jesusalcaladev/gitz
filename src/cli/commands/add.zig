const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const index_mod = @import("../../core/index.zig");
const object = @import("../../core/object.zig");
const storage_mod = @import("../../core/storage.zig");
const ignore_mod = @import("../../core/ignore.zig");
const ui = @import("../../util/ui.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    if (args.len == 0) {
        try io.eprint("usage: gitz add <paths...>\n", .{});
        std.process.exit(1);
    }

    var idx = try index_mod.Index.readFromFile(allocator, git_dir, io.io);

    // Load .gitignore rules
    var ignore_stack = ignore_mod.IgnoreStack.init(allocator);
    defer ignore_stack.deinit();
    ignore_stack.loadFile(io.io, ".gitignore") catch {};

    // First collect all files to add so we know the total for the progress bar
    var all_files = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer {
        for (all_files.items) |f| allocator.free(f);
        all_files.deinit(allocator);
    }

    for (args) |path| {
        if (std.mem.eql(u8, path, ".")) {
            try collectFilesRecursive(allocator, ".", &all_files, &ignore_stack);
        } else {
            if (ignore_stack.isIgnored(path, false)) continue;
            // Check if it's a directory
            if (isDirectory(path)) {
                try collectFilesRecursive(allocator, path, &all_files, &ignore_stack);
            } else {
                const owned = try allocator.dupe(u8, path);
                try all_files.append(allocator, owned);
            }
        }
    }

    if (all_files.items.len == 0) {
        try io.print("Nothing to add.\n", .{});
        return;
    }

    const total: u32 = @intCast(all_files.items.len);
    var progress = ui.Progress{ .total = total };

    for (all_files.items) |file_path| {
        addFile(allocator, git_dir, &idx, file_path, io) catch {
            try io.eprint("fatal: pathspec '{s}' did not match any files\n", .{file_path});
            continue;
        };
        ui.tick(io, "Staging", &progress);
    }
    ui.clearLine(io);

    try idx.writeToFile(git_dir, allocator, io.io);
    idx.deinit(allocator);

    // Show summary
    try io.print("{s}{s}{s} {d} file(s) staged\n", .{
        ui.c.bgreen, ui.sym.ok, ui.c.reset,
        total,
    });
}

fn addFile(allocator: std.mem.Allocator, git_dir: []const u8, idx: *index_mod.Index, path: []const u8, io: Io) !void {
    var f = io.openFile(path) catch return error.FileNotFound;
    defer f.close(io.io);

    var buf: [10 * 1024 * 1024]u8 = undefined;
    const n = try f.readStreaming(io.io, &.{&buf});
    const content = buf[0..n];

    // Write blob to object store
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const blob = object.GitObject{ .blob = .{ .content = content } };
    const sha = try store.write(allocator, io.io, blob);

    const stat = try std.Io.Dir.cwd().statFile(io.io, path, .{});

    try idx.add(allocator, path, sha, .{
        .size = @intCast(stat.size),
        .mtime = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s)),
        .ctime = @intCast(@divTrunc(stat.ctime.nanoseconds, std.time.ns_per_s)),
        .mode = 0o100644,
    });
}

/// Collect files recursively for staging
fn collectFilesRecursive(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    entries: *std.ArrayList([]const u8),
    ignore: *ignore_mod.IgnoreStack,
) !void {
    var dirs_to_visit: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
    defer {
        for (dirs_to_visit.items) |d| allocator.free(d);
        dirs_to_visit.deinit(allocator);
    }

    try dirs_to_visit.append(allocator, try allocator.dupe(u8, dir_path));

    while (dirs_to_visit.items.len > 0) {
        const current = dirs_to_visit.pop() orelse break;
        defer allocator.free(current);

        const current_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{current}, 0);
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
                    (name.len == 5 and name[0] == '.' and std.mem.eql(u8, name, ".gitz"));
                if (!skip) {
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current, name });

                    // Check .gitignore
                    const is_dir = isDirectory(full_path);
                    if (ignore.isIgnored(full_path, is_dir)) {
                        allocator.free(full_path);
                        pos += direntry.reclen;
                        continue;
                    }

                    if (is_dir) {
                        try dirs_to_visit.append(allocator, full_path);
                    } else {
                        try entries.append(allocator, full_path);
                    }
                }
                pos += direntry.reclen;
            }
        }
    }
}

fn isDirectory(path: []const u8) bool {
    const path_z = std.fmt.allocPrintSentinel(std.heap.page_allocator, "{s}", .{path}, 0) catch return false;
    defer std.heap.page_allocator.free(path_z);

    const fd = std.posix.openat(std.posix.AT.FDCWD, path_z, std.posix.O{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch return false;
    _ = std.os.linux.close(@intCast(fd));
    return true;
}
