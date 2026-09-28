const std = @import("std");

/// Zig 0.16 I/O wrapper.
/// Uses std.Io.Dir.cwd() for filesystem and std.Io.File for stdout/stderr.
pub const Io = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    color: bool,
    /// The process environment, kept so child processes can inherit it while
    /// overriding individual variables. Passing a `Environ.Map` replaces the
    /// whole environment, so anything spawning git needs the original values
    /// (PATH, HOME, SSH_AUTH_SOCK) plus the overrides.
    environ: std.process.Environ,
    /// Owned subdirectory prefix, set once the repository root is known.
    owned_prefix: ?[]u8 = null,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, environ: std.process.Environ) Io {
        const no_color = std.process.Environ.contains(environ, std.heap.page_allocator, "NO_COLOR") catch false;
        return .{
            .io = io,
            .allocator = allocator,
            .color = !no_color,
            .environ = environ,
        };
    }

    /// Snapshot the current environment, then apply `overrides` on top.
    ///
    /// Used to run `git` as a fallback without going through a shell: the
    /// remote name and ref come from argv, and building an `sh -c` string out of
    /// them made `gitz push 'origin; id' --git` execute arbitrary commands.
    pub fn childEnviron(
        self: Io,
        allocator: std.mem.Allocator,
        overrides: []const [2][]const u8,
    ) !std.process.Environ.Map {
        var map = std.process.Environ.Map.init(allocator);
        errdefer map.deinit();

        // `Environ.Block` is a per-OS type, not a union, so the branch is
        // resolved at comptime for the target.
        if (@hasDecl(std.process.Environ.PosixBlock, "view")) {
            const block: *const std.process.Environ.PosixBlock = &self.environ.block;
            map.putPosixBlock(block.view()) catch {};
        } else if (@hasDecl(std.process.Environ.WindowsBlock, "view")) {
            const block: *const std.process.Environ.WindowsBlock = &self.environ.block;
            map.putWindowsBlock(block.view()) catch {};
        }

        for (overrides) |kv| {
            map.put(kv[0], kv[1]) catch {};
        }
        return map;
    }

    // ── Output ───────────────────────────────────────────────────────

    pub fn print(self: Io, comptime fmt: []const u8, args: anytype) !void {
        var buf: [8192]u8 = undefined;
        var owned_msg: ?[]u8 = null;
        defer if (owned_msg) |msg| self.allocator.free(msg);

        const msg = std.fmt.bufPrint(&buf, fmt, args) catch |err| switch (err) {
            error.NoSpaceLeft => blk: {
                owned_msg = try std.fmt.allocPrint(self.allocator, fmt, args);
                break :blk owned_msg.?;
            },
        };

        try self.writeOutput(std.Io.File.stdout(), msg);
    }

    pub fn eprint(self: Io, comptime fmt: []const u8, args: anytype) !void {
        var buf: [8192]u8 = undefined;
        var owned_msg: ?[]u8 = null;
        defer if (owned_msg) |msg| self.allocator.free(msg);

        const msg = std.fmt.bufPrint(&buf, fmt, args) catch |err| switch (err) {
            error.NoSpaceLeft => blk: {
                owned_msg = try std.fmt.allocPrint(self.allocator, fmt, args);
                break :blk owned_msg.?;
            },
        };

        try self.writeOutput(std.Io.File.stderr(), msg);
    }

    fn writeOutput(self: Io, file: std.Io.File, msg: []const u8) !void {
        if (self.color) return file.writeStreamingAll(self.io, msg);

        const plain = try stripAnsi(self.allocator, msg);
        defer self.allocator.free(plain);
        try file.writeStreamingAll(self.io, plain);
    }

    fn stripAnsi(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        var plain_len: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '[') {
                i += 2;
                while (i < bytes.len) : (i += 1) {
                    if (bytes[i] >= 0x40 and bytes[i] <= 0x7e) {
                        i += 1;
                        break;
                    }
                }
            } else {
                plain_len += 1;
                i += 1;
            }
        }

        const plain = try allocator.alloc(u8, plain_len);
        var out: usize = 0;
        i = 0;
        while (i < bytes.len) {
            if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '[') {
                i += 2;
                while (i < bytes.len) : (i += 1) {
                    if (bytes[i] >= 0x40 and bytes[i] <= 0x7e) {
                        i += 1;
                        break;
                    }
                }
            } else {
                plain[out] = bytes[i];
                out += 1;
                i += 1;
            }
        }
        return plain;
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

    /// Whether `path` exists and is a directory. Symlinks are followed, matching
    /// how git resolves a worktree's `.git` link.
    pub fn isDirAt(self: Io, dir: []const u8, name: []const u8) bool {
        const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, name }) catch return false;
        defer self.allocator.free(path);
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return stat.kind == .directory;
    }

    /// Whether `path` exists and is a regular file.
    pub fn isFileAt(self: Io, dir: []const u8, name: []const u8) bool {
        const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, name }) catch return false;
        defer self.allocator.free(path);
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return stat.kind == .file;
    }

    /// Look up an environment variable. The returned slice is owned by the
    /// caller.
    pub fn get(self: Io, name: []const u8) ?[]const u8 {
        return self.environ.getAlloc(self.allocator, name) catch null;
    }

    /// Record the subdirectory the command was invoked from, relative to the
    /// worktree root.
    ///
    /// The process is moved to the root so that every command can treat paths
    /// as root-relative, which means a pathspec the user typed inside a
    /// subdirectory has to be re-anchored here.
    pub fn setSubdirPrefix(self: *Io, from: []const u8, root: []const u8) void {
        if (self.owned_prefix) |p| self.allocator.free(p);
        self.owned_prefix = null;

        if (std.mem.eql(u8, from, root)) return;

        var rel = from[root.len..];
    while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        if (rel.len == 0) return;
        self.owned_prefix = self.allocator.dupe(u8, rel) catch null;
    }

    /// The subdirectory prefix, or an empty slice at the worktree root.
    pub fn subdirPrefix(self: Io) []const u8 {
        return self.owned_prefix orelse "";
    }

    /// Re-anchor a user-supplied path on the worktree root.
    ///
    /// `gitz add file.txt` inside `src/` means `<root>/src/file.txt`, but the
    /// command runs from the root. Absolute paths and `..` are left alone.
    pub fn rebasePath(self: Io, path: []const u8) ![]const u8 {
        const prefix = self.subdirPrefix();
        if (prefix.len == 0) return self.allocator.dupe(u8, path);
        if (std.fs.path.isAbsolute(path)) return self.allocator.dupe(u8, path);
        if (std.mem.startsWith(u8, path, "..")) return self.allocator.dupe(u8, path);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, path });
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

test "NO_COLOR strips terminal control sequences" {
    const plain = try Io.stripAnsi(std.testing.allocator, "\x1b[1;31mred\x1b[0m plain\x1b[2K");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("red plain", plain);
}
