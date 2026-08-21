const std = @import("std");

/// Zig 0.16 I/O wrapper.
/// Uses std.Io.Dir.cwd() for filesystem and std.Io.File for stdout/stderr.
pub const Io = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) Io {
        return .{ .io = io, .allocator = allocator };
    }

    // ── Output ───────────────────────────────────────────────────────

    pub fn print(self: Io, comptime fmt: []const u8, args: anytype) !void {
        var buf: [8192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        var stdout = std.Io.File.stdout();
        try stdout.writeStreamingAll(self.io, msg);
    }

    pub fn eprint(self: Io, comptime fmt: []const u8, args: anytype) !void {
        var buf: [8192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        var stderr = std.Io.File.stderr();
        try stderr.writeStreamingAll(self.io, msg);
    }

    // ── Filesystem ───────────────────────────────────────────────────

    pub fn createFile(self: Io, path: []const u8) !std.Io.File {
        return std.Io.Dir.cwd().createFile(self.io, path, .{});
    }

    pub fn openFile(self: Io, path: []const u8) !std.Io.File {
        return std.Io.Dir.cwd().openFile(self.io, path, .{});
    }

    pub fn fileExists(self: Io, path: []const u8) bool {
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return false;
        return true;
    }

    pub fn makeDir(self: Io, path: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(self.io, path);
    }

    pub fn removeFile(self: Io, path: []const u8) !void {
        try std.Io.Dir.cwd().deleteFile(self.io, path);
    }

    pub fn removeTree(self: Io, path: []const u8) !void {
        try std.Io.Dir.cwd().deleteTree(self.io, path);
    }

    pub fn readFileAlloc(self: Io, path: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
    }

    pub fn writeFile(self: Io, path: []const u8, content: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = content,
        });
    }
};
