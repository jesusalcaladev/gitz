const std = @import("std");

/// Filesystem helpers with one job: make it impossible to get an uniterable
/// `Dir`.
///
/// Zig 0.16's `Dir.OpenOptions.iterate` defaults to `false`. On Linux that
/// makes the io layer open the directory with `O_PATH`, and the resulting
/// handle is then silently unusable with `getdents`/`lseek`: Debug builds abort
/// with `BADF`, Release builds read garbage. Every directory that is going to
/// be iterated must therefore be opened through `openIterable`, so the option
/// can never be forgotten at a new call site.
pub const Fs = struct {
    /// Open `sub_path` relative to `dir` for iteration. The caller owns the
    /// returned handle and must `close` it.
    pub fn openIterable(io: std.Io, sub_path: []const u8) !std.Io.Dir {
        return std.Io.Dir.cwd().openDir(io, sub_path, .{ .iterate = true });
    }

    /// Like `openIterable`, but open relative to an already-open directory.
    pub fn openIterableIn(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !std.Io.Dir {
        return dir.openDir(io, sub_path, .{ .iterate = true });
    }

    /// Count the regular files directly inside `sub_path` (non-recursive).
    /// Returns 0 when the directory cannot be opened, matching the tolerant
    /// behaviour callers expect from an object count.
    pub fn countFilesIn(io: std.Io, sub_path: []const u8) usize {
        var dir = openIterable(io, sub_path) catch return 0;
        defer dir.close(io);

        var iter = dir.iterate();
        var count: usize = 0;
        while (iter.next(io) catch null) |entry| {
            if (entry.kind == .file) count += 1;
        }
        return count;
    }

    /// Recursively count loose git objects (`XX/YYYY…`, 38-char names) under
    /// `objects_dir`.
    pub fn countLooseObjects(io: std.Io, objects_dir: []const u8) usize {
        var dir = openIterable(io, objects_dir) catch return 0;
        defer dir.close(io);

        var iter = dir.iterate();
        var count: usize = 0;
        while (iter.next(io) catch null) |entry| {
            if (entry.kind == .directory) {
                var sub_buf: [std.fs.max_path_bytes]u8 = undefined;
                const sub = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ objects_dir, entry.name }) catch continue;
                count += countLooseObjects(io, sub);
            } else if (entry.name.len == 38) {
                count += 1;
            }
        }
        return count;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "openIterable yields a directory that can actually be read" {
    const io = testing.io;
    const root = "zig-cache/gitz_fs_test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    var f = try std.Io.Dir.cwd().createFile(io, root ++ "/a.txt", .{});
    f.close(io);

    // A bare openDir(.{} ) would panic here with BADF; going through the
    // helper is the whole point of this test.
    var dir = try Fs.openIterable(io, root);
    defer dir.close(io);

    var iter = dir.iterate();
    var seen: usize = 0;
    while (try iter.next(io)) |entry| {
        try testing.expectEqualStrings("a.txt", entry.name);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 1), seen);
}

test "countLooseObjects walks the fanout directories" {
    const io = testing.io;
    const root = "zig-cache/gitz_fs_count_test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try std.Io.Dir.cwd().createDirPath(io, root ++ "/ab");
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/cd");
    // 38-char names are loose objects; anything else must be ignored.
    for ([_][]const u8{ root ++ "/ab/" ++ "0" ** 38, root ++ "/cd/" ++ "1" ** 38, root ++ "/cd/short" }) |p| {
        var f = try std.Io.Dir.cwd().createFile(io, p, .{});
        f.close(io);
    }

    try testing.expectEqual(@as(usize, 2), Fs.countLooseObjects(io, root));
    try testing.expectEqual(@as(usize, 0), Fs.countLooseObjects(io, root ++ "/missing"));
}
