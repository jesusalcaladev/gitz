const std = @import("std");

/// A tree entry name must be a single safe relative path component. Keeping
/// this rule in one module protects every clone entry point from traversal.
pub fn validateTreeEntryName(name: []const u8) !void {
    if (name.len == 0 or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\") != null or
        std.fs.path.isAbsolute(name) or
        std.ascii.eqlIgnoreCase(name, ".gitz"))
    {
        return error.UnsafeCheckoutEntryName;
    }

    // Reject Windows drive-qualified names even when running on POSIX.
    if (name.len >= 2 and name[1] == ':' and std.ascii.isAlphabetic(name[0])) {
        return error.UnsafeCheckoutEntryName;
    }
}

/// Refuse to write into an existing non-empty destination. A symlink is also
/// rejected so a clone cannot be redirected outside the user-named path.
pub fn ensureEmptyDestination(io: std.Io, dest: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(io, dest, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .directory) return error.DestinationNotEmpty;

    var dir = try std.Io.Dir.cwd().openDir(io, dest, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer dir.close(io);
    var iter = dir.iterate();
    if (try iter.next(io) != null) return error.DestinationNotEmpty;
}
