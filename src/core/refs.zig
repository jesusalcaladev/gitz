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

    /// Whether a ref name is safe to turn into a path inside the git dir.
    ///
    /// Ref names were previously concatenated into `{git_dir}/{refname}` with no
    /// validation, so `gitz branch ../../../tmp/x`, `gitz tag ../y` and
    /// `gitz switch -c ../../z` created and deleted files outside `.gitz`.
    /// This is the subset of `git check-ref-format` that matters for that.
    pub fn isValidRefName(name: []const u8) bool {
        if (name.len == 0) return false;
        if (std.mem.eql(u8, name, "@")) return false;
        if (name[0] == '/' or name[name.len - 1] == '/') return false;
        if (name[0] == '.') return false;
        if (std.mem.endsWith(u8, name, ".lock")) return false;
        if (std.mem.indexOf(u8, name, "..") != null) return false;
        if (std.mem.indexOf(u8, name, "@{") != null) return false;
        if (std.mem.indexOfScalar(u8, name, '\\') != null) return false;
        if (std.mem.indexOfScalar(u8, name, 0) != null) return false;
        // No component may start with a dot, and none may end in ".lock".
        var it = std.mem.splitScalar(u8, name, '/');
        while (it.next()) |component| {
            if (component.len == 0) return false;
            if (component[0] == '.') return false;
            if (std.mem.endsWith(u8, component, ".lock")) return false;
        }
        return true;
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
        // Refuse to write outside the git dir. Without this, a name containing
        // `..` created or overwrote files anywhere on the filesystem.
        if (!isValidRefName(refname)) return error.InvalidRefName;

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
        if (!isValidRefName(name) or !isValidRefName(target)) return error.InvalidRefName;

        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.git_dir, name });
        defer allocator.free(ref_path);

        var f = try std.Io.Dir.cwd().createFile(io, ref_path, .{});
        defer f.close(io);

        try std.Io.File.writeStreamingAll(f, io, "ref: ");
        try std.Io.File.writeStreamingAll(f, io, target);
        try std.Io.File.writeStreamingAll(f, io, "\n");
    }

    pub fn delete(self: Refs, allocator: std.mem.Allocator, io: std.Io, refname: []const u8) !void {
        if (!isValidRefName(refname)) return error.InvalidRefName;

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
    /// Returns fully-qualified ref names like "refs/heads/main".
    ///
    /// The listing recurses into subdirectories: git branch names may contain
    /// slashes (`refs/heads/feature/login`), and a non-recursive walk reported
    /// the intermediate directory `refs/heads/feature` as if it were the ref,
    /// hiding `feature/login` from `gitz branch`, `log --all` and reachability
    /// walks in `gc`.
    pub fn list(self: Refs, allocator: std.mem.Allocator, io: std.Io, subcategory: []const u8) ![][]const u8 {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/refs/{s}", .{ self.git_dir, subcategory });
        defer allocator.free(dir_path);

        const prefix = try std.fmt.allocPrint(allocator, "refs/{s}", .{subcategory});
        defer allocator.free(prefix);

        return listDirRaw(allocator, io, dir_path, prefix, 0) catch &.{};
    }

    /// List every ref in the repository, regardless of namespace
    /// (`refs/heads`, `refs/tags`, `refs/remotes`, `refs/stash`, ...).
    pub fn listAll(self: Refs, allocator: std.mem.Allocator, io: std.Io) ![][]const u8 {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/refs", .{self.git_dir});
        defer allocator.free(dir_path);

        return listDirRaw(allocator, io, dir_path, "refs", 0) catch &.{};
    }

    /// Maximum directory depth walked by `listDirRaw`. Refs nest one directory
    /// per slash, so this is a runaway guard rather than a real limit.
    const max_ref_depth = 32;

    /// Raw directory listing using Linux getdents64 syscall.
    ///
    /// `d_type` is 0 (DT_UNKNOWN) on some filesystems, so entry kind is
    /// confirmed with fstatat before deciding whether to recurse.
    fn listDirRaw(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, prefix: []const u8, depth: usize) ![][]const u8 {
        if (depth > max_ref_depth) return &.{};

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
                pos += entry.reclen;

                // Skip . and ..
                if (name.len == 0 or name[0] == '.') continue;

                const full_ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name });

                if (entryIsDir(io, full_path, entry.type) catch false) {
                    const children = listDirRaw(allocator, io, full_path, full_ref, depth + 1) catch &.{};
                    allocator.free(full_path);

                    for (children) |child| try result.append(allocator, child);
                    // The directory itself is a namespace, never a ref: a
                    // leftover file at that path would collide with the refs
                    // stored below it, exactly as in git.
                    allocator.free(full_ref);
                } else {
                    allocator.free(full_path);
                    try result.append(allocator, full_ref);
                }
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Whether a directory entry is a subdirectory, resolving DT_UNKNOWN via stat.
    fn entryIsDir(io: std.Io, full_path: []const u8, d_type: u8) !bool {
        const DT_DIR: u8 = 4;
        const DT_UNKNOWN: u8 = 0;

        if (d_type == DT_DIR) return true;
        if (d_type != DT_UNKNOWN) return false;

        const st = std.Io.Dir.cwd().statFile(io, full_path, .{}) catch return false;
        return st.kind == .directory;
    }
};
