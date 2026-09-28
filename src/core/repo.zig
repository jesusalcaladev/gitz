const std = @import("std");
const builtin = @import("builtin");
const Io = @import("../util/io.zig").Io;

/// The three directories a repository is made of.
///
/// GitZ used to pass a single `git_dir` string everywhere, which quietly
/// assumed that the object store, the per-worktree admin files and the checked
/// out files all lived in the same place. That holds for a plain repository and
/// breaks the moment a linked worktree is involved: the admin dir is
/// `.gitz/worktrees/<name>/` while the files are in `../<name>/`.
///
/// The split matters for two reasons:
///
///   - `objects/`, `refs/`, `config` and `packed-refs` are *shared* by every
///     worktree of a repository, so two agents in different worktrees see each
///     other's commits.
///   - `HEAD`, `index` and the pseudo-refs are *private*, which is exactly what
///     lets two agents sit on different branches at the same time.
///
/// For a repository with no worktrees all three are the same directory, so
/// `open` is the plain, unchanged behaviour.
pub const Repo = struct {
    /// Shared: `objects/`, `refs/`, `config`, `packed-refs`, `worktrees/`.
    common_dir: []const u8,
    /// Private: `HEAD`, `index`, `ORIG_HEAD`, `MERGE_HEAD`, `logs/`, rebase
    /// state. Equals `common_dir` for a main worktree.
    worktree_dir: []const u8,
    /// Root of the checked out files. Commands treat every relative path as
    /// starting here, so this is what the process is chdir'd into.
    worktree_path: []const u8,

    pub fn deinit(self: Repo, allocator: std.mem.Allocator) void {
        // `worktree_path` is only allocated when it differs from the directory
        // that was found, so freeing all three is safe as long as they are
        // distinct allocations -- which they are, see `open`.
        allocator.free(self.common_dir);
        if (!std.mem.eql(u8, self.worktree_dir, self.common_dir)) allocator.free(self.worktree_dir);
        allocator.free(self.worktree_path);
    }

    /// Whether this is the repository's main worktree rather than a linked one.
    pub fn isMainWorktree(self: Repo) bool {
        return std.mem.eql(u8, self.common_dir, self.worktree_dir);
    }

    /// A repository with no worktrees, where all three directories are the same.
    ///
    /// Used where a repository is being built rather than found -- `gitz clone`
    /// creating a fresh one, or a transport resolving the object store of a
    /// path it was handed. Nothing borrows ownership: the slices must outlive
    /// the returned value.
    pub fn flat(dir: []const u8) Repo {
        return .{ .common_dir = dir, .worktree_dir = dir, .worktree_path = dir };
    }

    /// Open the repository containing the current directory.
    ///
    /// Resolution order, matching git:
    ///
    ///   - `GIT_DIR` set -> it is the *worktree* dir; the common dir comes from
    ///     its `commondir` file when present.
    ///   - a `.gitz` or `.git` directory -> common, worktree and path all the
    ///     same.
    ///   - a `.gitz` or `.git` *file* -> a linked worktree. `gitdir:` names the
    ///     worktree dir, `commondir` inside it names the shared dir, and the
    ///     directory that held the file is the worktree path.
    ///
    /// The returned repository is for the worktree the caller is standing in. A
    /// worktree the caller is not inside is only reachable through
    /// `GITZ_WORKTREE`, which is what `gitz worktree exec` sets.
    pub fn open(allocator: std.mem.Allocator, io: *Io) !Repo {
        if (io.get("GIT_DIR")) |env_dir| {
            defer allocator.free(env_dir);
            if (env_dir.len > 0) {
                const worktree_dir = try allocator.dupe(u8, env_dir);
                errdefer allocator.free(worktree_dir);

                // With GIT_DIR the working directory is the worktree root
                // unless GIT_WORK_TREE says otherwise, mirroring git.
                const worktree_path = if (io.get("GIT_WORK_TREE")) |wt|
                    try allocator.dupe(u8, wt)
                else
                    try std.Io.Dir.cwd().realPathFileAlloc(io.io, ".", allocator);
                errdefer allocator.free(worktree_path);

                const common_dir = try resolveCommonDir(allocator, io.*, worktree_dir);
                return .{ .common_dir = common_dir, .worktree_dir = worktree_dir, .worktree_path = worktree_path };
            }
        }

        // `realPath("")` fails on POSIX, so the cwd comes from resolving ".".
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io.io, ".", allocator);
        var dir = try allocator.dupe(u8, cwd);
        defer allocator.free(dir);

        // The walk frees and reallocates `dir` on every iteration, so the
        // starting directory is kept for the subdirectory prefix.
        const start_dir = try allocator.dupe(u8, cwd);
        defer allocator.free(start_dir);

        while (true) {
            if (try findIn(allocator, io.*, dir)) |found| {
                // Commands treat every path as relative to the worktree root,
                // so from a subdirectory `root.txt` looked like a deleted file.
                // Move to the root and remember the prefix so user-supplied
                // pathspecs can be rebased onto it.
                try moveTo(io, dir);
                io.setSubdirPrefix(start_dir, dir);
                return found;
            }

            const parent = std.fs.path.dirname(dir) orelse break;
            if (std.mem.eql(u8, parent, dir)) break;
            const next = try allocator.dupe(u8, parent);
            allocator.free(dir);
            dir = next;
        }

        return error.NotAGitRepo;
    }

    /// The common dir for a worktree dir, following `commondir` if it has one.
    ///
    /// A main worktree has no `commondir` file: there the common dir *is* the
    /// worktree dir, so the same allocation is handed back rather than a copy.
    fn resolveCommonDir(allocator: std.mem.Allocator, io: Io, worktree_dir: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(allocator, "{s}/commondir", .{worktree_dir});
        defer allocator.free(path);

        const content = io.readFileAlloc(path) catch return allocator.dupe(u8, worktree_dir);
        defer allocator.free(content);

        const target = std.mem.trim(u8, content, " \t\r\n");
        if (target.len == 0) return allocator.dupe(u8, worktree_dir);

        // `commondir` holds a path relative to the worktree dir ("../.."), but
        // git also accepts an absolute one.
        if (std.fs.path.isAbsolute(target)) return allocator.dupe(u8, target);
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktree_dir, target });
    }
};

/// Resolve the repository rooted at one directory, if there is one there.
fn findIn(allocator: std.mem.Allocator, io: Io, dir: []const u8) !?Repo {
    if (io.isDirAt(dir, ".gitz")) {
        const d = try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dir});
        return try plain(allocator, d);
    }
    if (io.isDirAt(dir, ".git")) {
        const d = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
        return try plain(allocator, d);
    }
    if (io.isFileAt(dir, ".gitz")) {
        if (try linked(allocator, io, dir, ".gitz")) |r| return r;
    }
    if (io.isFileAt(dir, ".git")) {
        if (try linked(allocator, io, dir, ".git")) |r| return r;
    }
    return null;
}

/// A repository with no worktrees: one directory serving all three roles.
fn plain(allocator: std.mem.Allocator, dir: []const u8) !Repo {
    const path = try std.fmt.allocPrint(allocator, "{s}", .{dir});
    errdefer allocator.free(path);
    return .{
        .common_dir = path,
        .worktree_dir = path,
        .worktree_path = try allocator.dupe(u8, dir),
    };
}

/// A linked worktree: a `<dir>/.git` file pointing at an admin directory that
/// redirects the shared objects through its own `commondir`.
fn linked(allocator: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8) !?Repo {
    const file = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(file);

    const content = io.readFileAlloc(file) catch return null;
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir:")) return null;

    const target = std.mem.trim(u8, trimmed["gitdir:".len..], " \t\r\n");
    if (target.len == 0) return null;

    const worktree_dir = if (std.fs.path.isAbsolute(target))
        try allocator.dupe(u8, target)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, target });
    errdefer allocator.free(worktree_dir);

    const worktree_path = try allocator.dupe(u8, dir);
    errdefer allocator.free(worktree_path);

    const common_dir = try Repo.resolveCommonDir(allocator, io, worktree_dir);
    return .{
        .common_dir = common_dir,
        .worktree_dir = worktree_dir,
        .worktree_path = worktree_path,
    };
}

/// Change the process working directory to the worktree root.
///
/// `std.Io` has no chdir in the vtable, so the POSIX syscall is used directly,
/// consistent with the raw syscalls elsewhere in the tree.
fn moveTo(io: *Io, root: []const u8) !void {
    _ = io;
    if (builtin.os.tag != .linux) return;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (root.len >= buf.len) return;
    @memcpy(buf[0..root.len], root);
    buf[root.len] = 0;

    const rc = std.os.linux.chdir(@ptrCast(&buf));
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        // Staying put is better than aborting the command.
        else => {},
    }
}
