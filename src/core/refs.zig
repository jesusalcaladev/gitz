const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;

pub const HeadInfo = union(enum) {
    branch: struct { name: std.ArrayList(u8), sha: [20]u8 },
    detached: struct { sha: [20]u8 },

    pub fn deinit(self: *HeadInfo, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .branch => |*b| b.name.deinit(allocator),
            .detached => {},
        }
    }

    pub fn branchName(self: HeadInfo) []const u8 {
        return switch (self) {
            .branch => |b| b.name.items,
            .detached => unreachable,
        };
    }

    pub fn sha(self: HeadInfo) [20]u8 {
        return switch (self) {
            .branch => |b| b.sha,
            .detached => |d| d.sha,
        };
    }
};

pub const Refs = struct {
    git_dir: []const u8,

    pub fn init(git_dir: []const u8) Refs {
        return .{ .git_dir = git_dir };
    }

    fn readFileContent(self: Refs, allocator: std.mem.Allocator, io: std.Io, sub_path: []const u8) ![]u8 {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.git_dir, sub_path });
        defer allocator.free(full_path);
        return std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .unlimited);
    }

    pub fn read(self: Refs, allocator: std.mem.Allocator, io: std.Io, refname: []const u8) ![20]u8 {
        const content = self.readFileContent(allocator, io, refname) catch {
            return error.RefNotFound;
        };
        defer allocator.free(content);

        const trimmed = std.mem.trim(u8, content, &[_]u8{ '\n', '\r', ' ' });

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const target = trimmed[5..];
            return self.read(allocator, io, target);
        }

        if (trimmed.len != 40) return error.InvalidRef;
        return Sha1.fromHex(trimmed);
    }

    pub fn write(self: Refs, allocator: std.mem.Allocator, io: std.Io, refname: []const u8, sha: [20]u8) !void {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.git_dir, std.fs.path.dirname(refname) orelse "." });
        defer allocator.free(dir_path);

        try std.Io.Dir.cwd().createDirPath(io, dir_path);

        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.git_dir, refname });
        defer allocator.free(ref_path);

        var f = try std.Io.Dir.cwd().createFile(io, ref_path, .{});
        defer f.close(io);

        const hex = Sha1.hex(sha);
        try std.Io.File.writeStreamingAll(f, io, &hex);
        try std.Io.File.writeStreamingAll(f, io, "\n");
    }

    pub fn writeSymbolic(self: Refs, allocator: std.mem.Allocator, io: std.Io, name: []const u8, target: []const u8) !void {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.git_dir, name });
        defer allocator.free(ref_path);

        var f = try std.Io.Dir.cwd().createFile(io, ref_path, .{});
        defer f.close(io);

        try std.Io.File.writeStreamingAll(f, io, "ref: ");
        try std.Io.File.writeStreamingAll(f, io, target);
        try std.Io.File.writeStreamingAll(f, io, "\n");
    }

    pub fn delete(self: Refs, allocator: std.mem.Allocator, io: std.Io, refname: []const u8) !void {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.git_dir, refname });
        defer allocator.free(ref_path);
        try std.Io.Dir.cwd().deleteFile(io, ref_path);
    }

    pub fn head(self: Refs, allocator: std.mem.Allocator, io: std.Io) !HeadInfo {
        const sha = self.read(allocator, io, "HEAD") catch {
            return HeadInfo{ .detached = .{ .sha = [_]u8{0} ** 20 } };
        };

        const head_content = self.readFileContent(allocator, io, "HEAD") catch {
            return HeadInfo{ .detached = .{ .sha = sha } };
        };
        defer allocator.free(head_content);

        const trimmed = std.mem.trim(u8, head_content, &[_]u8{ '\n', '\r', ' ' });

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const target = trimmed[5..];
            const raw_name = if (std.mem.startsWith(u8, target, "refs/heads/"))
                target[11..]
            else
                target;
            var name_list: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
            try name_list.appendSlice(allocator, raw_name);
            return HeadInfo{ .branch = .{ .name = name_list, .sha = sha } };
        }

        return HeadInfo{ .detached = .{ .sha = sha } };
    }

    /// List all ref files under a subdirectory of refs/ (e.g. "heads" or "tags").
    /// Uses raw Linux getdents64 syscall to avoid Zig 0.16 Dir.iterate() fd lifecycle issues.
    /// Returns fully-qualified ref names like "refs/heads/main".
    pub fn list(self: Refs, allocator: std.mem.Allocator, io: std.Io, subcategory: []const u8) ![][]const u8 {
        _ = io;
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/refs/{s}", .{ self.git_dir, subcategory });
        defer allocator.free(dir_path);

        const prefix = try std.fmt.allocPrint(allocator, "refs/{s}", .{subcategory});
        defer allocator.free(prefix);

        return listDirRaw(allocator, dir_path, prefix) catch &.{};
    }

    /// Raw directory listing using Linux getdents64 syscall
    fn listDirRaw(allocator: std.mem.Allocator, dir_path: []const u8, prefix: []const u8) ![][]const u8 {
        var result: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };

        // Open directory using posix.openat
        const dir_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{dir_path}, 0);
        defer allocator.free(dir_z);

        const fd = std.posix.openat(std.posix.AT.FDCWD, dir_z, std.posix.O{ .ACCMODE = .RDONLY }, 0) catch {
            return &.{};
        };
        defer { _ = std.os.linux.close(@intCast(fd)); }

        var buf: [4096]u8 align(@alignOf(usize)) = undefined;
        while (true) {
            const rc = std.os.linux.getdents64(@intCast(fd), &buf, buf.len);
            const n: usize = if (rc > 0) @intCast(rc) else break;
            if (n == 0) break;

            var pos: usize = 0;
            while (pos < n) {
                const entry: *align(1) const std.os.linux.dirent64 = @ptrCast(&buf[pos]);
                const name: []const u8 = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);

                // Skip . and ..
                if (name.len > 0 and name[0] != '.') {
                    const full_ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
                    try result.append(allocator, full_ref);
                }
                pos += entry.reclen;
            }
        }

        return result.toOwnedSlice(allocator);
    }
};
