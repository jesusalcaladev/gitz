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

/// Validate a full worktree-relative path (as assembled from tree entries).
///
/// `validateTreeEntryName` only accepts a single component, because clone
/// consumes one tree entry at a time. Checkout, merge and reset work on
/// assembled paths like `src/lib/foo.zig`, so each component is checked
/// separately here. Without this, a tree containing an entry named
/// `../../../../home/user/.bashrc` made `restoreTree` write outside the
/// worktree.
pub fn validateWorktreePath(path: []const u8) !void {
    if (path.len == 0) return error.UnsafeCheckoutEntryName;
    if (std.fs.path.isAbsolute(path)) return error.UnsafeCheckoutEntryName;
    // A backslash is a separator on Windows and a legal filename character on
    // POSIX; rejecting it keeps a tree from changing meaning across platforms.
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.UnsafeCheckoutEntryName;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (component.len == 0) continue; // collapse of "a//b" is harmless
        try validateTreeEntryName(component);
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
