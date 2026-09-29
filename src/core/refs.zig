const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;
const Repo = @import("repo.zig").Repo;

pub const HeadInfo = union(enum) {
    /// A branch that exists and has commits.
    branch: struct { name: std.ArrayList(u8), sha: [20]u8 },
    /// HEAD points directly at a commit.
    detached: struct { sha: [20]u8 },
    /// HEAD names a branch with no commits yet (`gitz init`, before the first
    /// commit). This used to be reported as a detached HEAD at the all-zero
    /// SHA, so a fresh repository printed "HEAD detached at 0000000" instead of
    /// "On branch main / No commits yet", `gitz switch -c foo` refused with "no
    /// commits yet", and `gitz merge` treated HEAD as a detached all-zero
    /// commit.
    unborn: struct { name: std.ArrayList(u8) },

    pub fn deinit(self: *HeadInfo, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .branch => |*b| b.name.deinit(allocator),
            .detached => {},
            .unborn => |*u| u.name.deinit(allocator),
        }
    }

    pub fn branchName(self: HeadInfo) []const u8 {
        return switch (self) {
            .branch => |b| b.name.items,
            .unborn => |u| u.name.items,
            // A detached HEAD has no branch name; callers must not ask for one.
            .detached => unreachable,
        };
    }

    /// The commit HEAD points at, if any. An unborn branch has none.
    pub fn sha(self: HeadInfo) ?[20]u8 {
        return switch (self) {
            .branch => |b| b.sha,
            .detached => |d| d.sha,
            .unborn => null,
        };
    }

    /// The branch HEAD points at, whether or not it has commits.
    pub fn branchOf(self: HeadInfo) ?[]const u8 {
        return switch (self) {
            .branch => |b| b.name.items,
            .unborn => |u| u.name.items,
            .detached => null,
        };
    }
};

pub const Refs = struct {
    repo: Repo,

    pub fn init(repo: Repo) Refs {
        return .{ .repo = repo };
    }

    /// Whether a ref belongs to the worktree rather than the shared store.
    ///
    /// `HEAD` and the pseudo-refs beside it are what two worktrees must not
    /// share: that is the whole reason a worktree has its own checkout. Every
    /// other ref -- `refs/heads/*`, `refs/tags/*`, `refs/remotes/*` -- is
    /// shared, so a commit made in one worktree is visible from the others.
    fn isPerWorktree(refname: []const u8) bool {
        if (std.mem.eql(u8, refname, "HEAD")) return true;
        for ([_][]const u8{
            "ORIG_HEAD",    "FETCH_HEAD",     "MERGE_HEAD",      "MERGE_AUTOSTASH",
            "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_HEAD",     "AUTO_MERGE",
        }) |name| {
            if (std.mem.eql(u8, refname, name)) return true;
        }
        // Bisect state is per worktree too, so two agents can bisect
        // independently without overwriting each other.
        if (std.mem.startsWith(u8, refname, "refs/bisect/")) return true;
        return false;
    }

    /// The directory a ref is stored in.
    fn dirFor(self: Refs, allocator: std.mem.Allocator, refname: []const u8) ![]u8 {
        return try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ if (isPerWorktree(refname)) self.repo.worktree_dir else self.repo.common_dir, refname },
        );
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
        const full_path = try self.dirFor(allocator, sub_path);
        defer allocator.free(full_path);
        return std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .unlimited);
    }

    /// Look a ref up in `packed-refs`, the file git uses to hold every ref in
    /// one place.
    ///
    /// git prunes the loose `refs/heads/main` once it has written a ref there,
    /// so a repository that has ever been `gc`'d keeps *no* loose refs at all.
    /// Reading only loose files made every command in such a repository report
    /// no commits, while `git` was perfectly happy. The loose file still wins,
    /// because that is where a ref being updated lives.
    fn readPackedRefs(self: Refs, allocator: std.mem.Allocator, io: std.Io, refname: []const u8) ![20]u8 {
        const path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{self.repo.common_dir});
        defer allocator.free(path);

        const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch
            return error.RefNotFound;
        defer allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            // A line is `<sha> <refname>`, optionally followed by `^<peeled>` on
            // the next line. `^` never starts a refname, so skipping it here is
            // enough.
            if (line[0] == '^') continue;

            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const sha_hex = line[0..space];
            const name = std.mem.trim(u8, line[space + 1 ..], " \t\r");
            if (name.len != refname.len) continue;
            if (!std.mem.eql(u8, name, refname)) continue;
            if (sha_hex.len != 40) continue;
            return Sha1.fromHex(sha_hex) catch return error.InvalidRef;
        }
        return error.RefNotFound;
    }

    pub fn read(self: Refs, allocator: std.mem.Allocator, io: std.Io, refname: []const u8) ![20]u8 {
        const content = self.readFileContent(allocator, io, refname) catch {
            // No loose file: the ref may live in `packed-refs` instead.
            return self.readPackedRefs(allocator, io, refname);
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

    /// The raw contents of a ref file, without resolving symrefs or parsing a
    /// SHA. `refs/stash` is a log whose lines are `<sha> <message>`, so `read`
    /// rejects it and the reachability walk needs the first token instead.
    pub fn readRaw(self: Refs, allocator: std.mem.Allocator, io: std.Io, refname: []const u8) ![]u8 {
        return self.readFileContent(allocator, io, refname);
    }

    pub fn write(self: Refs, allocator: std.mem.Allocator, io: std.Io, refname: []const u8, sha: [20]u8) !void {
        // Refuse to write outside the git dir. Without this, a name containing
        // `..` created or overwrote files anywhere on the filesystem.
        if (!isValidRefName(refname)) return error.InvalidRefName;

        const ref_path = try self.dirFor(allocator, refname);
        defer allocator.free(ref_path);

        if (std.fs.path.dirname(ref_path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }

        var f = try std.Io.Dir.cwd().createFile(io, ref_path, .{});
        defer f.close(io);

        const hex = Sha1.hex(sha);
        try std.Io.File.writeStreamingAll(f, io, &hex);
        try std.Io.File.writeStreamingAll(f, io, "\n");
    }

    pub fn writeSymbolic(self: Refs, allocator: std.mem.Allocator, io: std.Io, name: []const u8, target: []const u8) !void {
        if (!isValidRefName(name) or !isValidRefName(target)) return error.InvalidRefName;

        const ref_path = try self.dirFor(allocator, name);
        defer allocator.free(ref_path);

        var f = try std.Io.Dir.cwd().createFile(io, ref_path, .{});
        defer f.close(io);

        try std.Io.File.writeStreamingAll(f, io, "ref: ");
        try std.Io.File.writeStreamingAll(f, io, target);
        try std.Io.File.writeStreamingAll(f, io, "\n");
    }

    /// The contents of `packed-refs`, or an empty list when there is no such file.
fn packedRefsLines(self: Refs, allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{self.repo.common_dir});
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return "";
}

/// Rewrite `packed-refs` with one entry per name in `updates`, leaving every
/// other entry alone.
///
/// A ref written loose shadows the packed copy, so the packed line is dropped
/// rather than replaced. Leaving it behind is what makes a delete look like it
/// did nothing: git prunes the loose file after packing, so the stale line was
/// all that remained and the branch came straight back.
fn removeFromPackedRefs(
    allocator: std.mem.Allocator,
    io: std.Io,
    common_dir: []const u8,
    refname: []const u8,
) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{common_dir});
    defer allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return;
    defer allocator.free(content);

    var kept: std.Io.Writer.Allocating = .init(allocator);
    defer kept.deinit();

    // The peeled line `^<sha>` that follows a tag's entry belongs to that
    // entry, so dropping the entry has to drop both.
    var skip_peeled = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const line = std.mem.trim(u8, raw, " \t\r");

        if (skip_peeled and line.len > 0 and line[0] == '^') {
            skip_peeled = false;
            continue;
        }
        skip_peeled = false;

        if (line.len > 0 and line[0] != '#' and line[0] != '^') {
            if (std.mem.indexOfScalar(u8, line, ' ')) |space| {
                const name = std.mem.trim(u8, line[space + 1 ..], " \t\r");
                if (std.mem.eql(u8, name, refname)) {
                    skip_peeled = true;
                    continue;
                }
            }
        }
        try kept.writer.writeAll(raw);
        try kept.writer.writeAll("\n");
    }

    const out = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer out.close(io);
    try std.Io.File.writeStreamingAll(out, io, kept.written());
}

pub fn delete(self: Refs, allocator: std.mem.Allocator, io: std.Io, refname: []const u8) !void {
    if (!isValidRefName(refname)) return error.InvalidRefName;

    const ref_path = try self.dirFor(allocator, refname);
    defer allocator.free(ref_path);
    std.Io.Dir.cwd().deleteFile(io, ref_path) catch {};

    // The ref may only exist in `packed-refs`, where a missing loose file is
    // the normal state rather than an error, so deleting it must not fail.
    removeFromPackedRefs(allocator, io, self.repo.common_dir, refname) catch {};
}

    /// Describe HEAD.
    ///
    /// A symbolic HEAD whose branch does not exist yet is `.unborn`, not a
    /// detached HEAD at the all-zero SHA. The two were conflated, so a freshly
    /// initialised repository reported "HEAD detached at 0000000" and the
    /// branch-creating commands treated it as a detached commit.
    pub fn head(self: Refs, allocator: std.mem.Allocator, io: std.Io) !HeadInfo {
        const head_content = self.readFileContent(allocator, io, "HEAD") catch {
            return error.RefNotFound;
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

            // The branch the symref names may not exist yet.
            const sha = self.read(allocator, io, target) catch {
                return HeadInfo{ .unborn = .{ .name = name_list } };
            };
            return HeadInfo{ .branch = .{ .name = name_list, .sha = sha } };
        }

        // A direct SHA in HEAD: a detached head.
        const sha = Sha1.fromHex(trimmed) catch return error.InvalidRef;
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
    /// The refs in one namespace (`heads`, `tags`, `remotes`), loose and packed.
///
/// `packed-refs` is included because after a `git gc` the directory is simply
/// empty: listing it alone reported a repository with no branches at all.
pub fn list(self: Refs, allocator: std.mem.Allocator, io: std.Io, subcategory: []const u8) ![][]const u8 {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/refs/{s}", .{ self.repo.common_dir, subcategory });
        defer allocator.free(dir_path);

        const prefix = try std.fmt.allocPrint(allocator, "refs/{s}", .{subcategory});
        defer allocator.free(prefix);

        var all = std.ArrayList([]const u8).empty;
        errdefer {
            for (all.items) |r| allocator.free(r);
            all.deinit(allocator);
        }

        {
            const loose = listDirRaw(allocator, io, dir_path, prefix, 0) catch &.{};
            defer {
                for (loose) |r| allocator.free(r);
                allocator.free(loose);
            }
            for (loose) |name| {
                const copy = try allocator.dupe(u8, name);
                all.append(allocator, copy) catch {
                    allocator.free(copy);
                    return error.OutOfMemory;
                };
            }
        }

        const content = packedRefsLines(self, allocator, io) catch "";
        defer if (content.len > 0) allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const name = std.mem.trim(u8, line[space + 1 ..], " \t\r");
            if (name.len <= prefix.len or !std.mem.startsWith(u8, name, prefix)) continue;
            if (name[prefix.len] != '/') continue;

            var already = false;
            for (all.items) |existing| {
                if (std.mem.eql(u8, existing, name)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;

            const copy = try allocator.dupe(u8, name);
            all.append(allocator, copy) catch {
                allocator.free(copy);
                return error.OutOfMemory;
            };
        }

        return all.toOwnedSlice(allocator);
    }

    /// List every ref in the repository, regardless of namespace
    /// (`refs/heads`, `refs/tags`, `refs/remotes`, `refs/stash`, ...).
    /// Every ref in the repository, loose or packed.
///
/// The loose `refs/` tree is walked first and `packed-refs` is folded in
/// afterwards, keeping the loose spelling when both hold the same name. A
/// repository that has been `git gc`'d keeps *no* loose refs at all, so listing
/// only the directory reported an empty repository: `gitz branch` printed
/// nothing and `--all` walks started from nothing.
pub fn listAll(self: Refs, allocator: std.mem.Allocator, io: std.Io) ![][]const u8 {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/refs", .{self.repo.common_dir});
        defer allocator.free(dir_path);

        var all: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
        errdefer {
            for (all.items) |r| allocator.free(r);
            all.deinit(allocator);
        }

        {
            const loose = listDirRaw(allocator, io, dir_path, "refs", 0) catch &.{};
            defer {
                for (loose) |r| allocator.free(r);
                allocator.free(loose);
            }
            for (loose) |name| {
                const copy = try allocator.dupe(u8, name);
                all.append(allocator, copy) catch {
                    allocator.free(copy);
                    return error.OutOfMemory;
                };
            }
        }

        const content = packedRefsLines(self, allocator, io) catch "";
        defer if (content.len > 0) allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const name = std.mem.trim(u8, line[space + 1 ..], " \t\r");
            if (name.len == 0) continue;

            var already: ?usize = null;
            for (all.items, 0..) |existing, i| {
                if (std.mem.eql(u8, existing, name)) {
                    already = i;
                    break;
                }
            }
            if (already != null) continue;

            const copy = try allocator.dupe(u8, name);
            all.append(allocator, copy) catch {
                allocator.free(copy);
                return error.OutOfMemory;
            };
        }

        return all.toOwnedSlice(allocator);
    }

    /// The `worktrees/` admin directory, where linked worktrees keep their
    /// per-worktree HEAD, index and `commondir` pointer.
    pub fn worktreesDir(self: Refs, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{s}/worktrees", .{self.repo.common_dir});
    }

    /// Path of one worktree's admin directory.
    pub fn worktreeAdminDir(self: Refs, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{s}/worktrees/{s}", .{ self.repo.common_dir, name });
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
