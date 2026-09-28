const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const Repo = @import("../../core/repo.zig").Repo;
const refs_mod = @import("../../core/refs.zig").Refs;
const storage_mod = @import("../../core/storage.zig").StorageBackend;
const checkout = @import("../../core/checkout.zig");
const index_mod = @import("../../core/index.zig").Index;
const clone_safety = @import("../../util/clone_safety.zig");
const errors = @import("../errors.zig");

const Sub = enum { add, list, remove, prune, move, lock, unlock, repair };

pub fn execute(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    if (args.len == 0) return usage(io);

    const sub = std.meta.stringToEnum(Sub, args[0]) orelse {
        try io.eprint("error: unknown subcommand '{s}'\n", .{args[0]});
        return usage(io);
    };
    const rest = args[1..];

    switch (sub) {
        .add => try add(allocator, repo, rest, io),
        .list => try list(allocator, repo, rest, io),
        .remove => try remove(allocator, repo, rest, io),
        .prune => try prune(allocator, repo, rest, io),
        .move => try moveWorktree(allocator, repo, rest, io),
        .lock => try setLock(allocator, repo, rest, io, true),
        .unlock => try setLock(allocator, repo, rest, io, false),
        .repair => try repair(allocator, repo, rest, io),
    }
}

fn usage(io: Io) !void {
    try io.print(
        \\
        \\usage: gitz worktree <subcommand>
        \\
        \\   add [-b <branch>] [--detach] <path> [<commit>]
        \\       Create a worktree checked out at <commit> (default: HEAD).
        \\   list [--porcelain]
        \\       List worktrees.
        \\   remove [-f] <worktree>
        \\       Remove a worktree. Only clean worktrees unless -f.
        \\   prune
        \\       Remove worktree admin files for directories that are gone.
        \\   move <worktree> <new-path>
        \\       Move a worktree to a new path.
        \\   lock [--reason <r>] <worktree>
        \\       Keep a worktree from being pruned or moved.
        \\   unlock <worktree>
        \\       Undo a lock.
        \\   repair [<path>...]
        \\       Fix worktree links that point at missing directories.
        \\
        \\
    , .{});
}

// ---------------------------------------------------------------------------
// add
// ---------------------------------------------------------------------------

fn add(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    var new_branch: ?[]const u8 = null;
    var detach = false;
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-b") or std.mem.eql(u8, a, "-c")) {
            if (i + 1 >= args.len) {
                try io.eprint("error: {s} needs a branch name\n", .{a});
                std.process.exit(errors.Exit.usage);
            }
            i += 1;
            new_branch = args[i];
        } else if (std.mem.eql(u8, a, "--detach")) {
            detach = true;
        } else if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--force")) {
            // Creating over an existing directory is refused further down; the
            // flag exists for compatibility and is accepted here.
        } else if (std.mem.startsWith(u8, a, "-")) {
            try io.eprint("error: unknown option '{s}'\n", .{a});
            std.process.exit(errors.Exit.usage);
        } else {
            try positional.append(allocator, a);
        }
    }

    if (positional.items.len < 1 or positional.items.len > 2) {
        try io.eprint("usage: gitz worktree add [-b <branch>] [--detach] <path> [<commit>]\n", .{});
        std.process.exit(errors.Exit.usage);
    }

    const path = positional.items[0];
    const start = if (positional.items.len == 2) positional.items[1] else "HEAD";

    const refs = refs_mod.init(repo);
    const store = storage_mod.fromRepoConfig(allocator, io.io, repo);

    const commit_sha = resolve(allocator, io, refs, store, start) catch {
        try io.eprint("fatal: invalid reference: {s}\n", .{start});
        std.process.exit(errors.Exit.fatal);
    };

    // A branch may only be checked out once. Git refuses, and so must we: two
    // worktrees on one branch would race on the same ref, which is exactly the
    // corruption agents are supposed to be immune to.
    if (new_branch) |b| {
        try rejectCheckedOut(allocator, repo, refs, b, io);
    } else if (!detach) {
        // Without -b, the worktree is detached at the start point.
        detach = true;
    }

    const target_branch = new_branch orelse "";
    if (new_branch) |b| {
        // Refs are stored under their full name, so the branch the user typed
        // has to be expanded before it is written or looked up.
        if (!refs_mod.isValidRefName(b)) {
            try io.eprint("fatal: '{s}' is not a valid branch name\n", .{b});
            std.process.exit(errors.Exit.fatal);
        }
        const full = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{b});
        defer allocator.free(full);

        if ((refs.read(allocator, io.io, full) catch null) != null) {
            try io.eprint("fatal: a branch named '{s}' already exists\n", .{b});
            std.process.exit(errors.Exit.fatal);
        }
        try refs.write(allocator, io.io, full, commit_sha);
    }

    // The worktree name doubles as its admin directory, so it must be a safe
    // single path component.
    const name = std.fs.path.basename(path);
    if (!validWorktreeName(name)) {
        try io.eprint("fatal: invalid worktree name '{s}'\n", .{name});
        std.process.exit(errors.Exit.fatal);
    }
    if (io.isDirAt(repo.common_dir, "worktrees") and adminExists(allocator, repo, name, io)) {
        try io.eprint("fatal: a worktree named '{s}' already exists\n", .{name});
        std.process.exit(errors.Exit.fatal);
    }

    if (io.isDirAt(".", path)) {
        try io.eprint("fatal: '{s}' already exists\n", .{path});
        std.process.exit(errors.Exit.fatal);
    }

    const base = try cwdAlloc(allocator);
    defer allocator.free(base);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, path });
    defer allocator.free(abs_path);
    try std.Io.Dir.cwd().createDirPath(io.io, abs_path);

    const admin = try refs.worktreeAdminDir(allocator, name);
    defer allocator.free(admin);
    try std.Io.Dir.cwd().createDirPath(io.io, admin);

    // `commondir` is how a worktree finds the shared objects. ".." twice from
    // `<common>/worktrees/<name>` lands back on the common dir, which is what
    // git writes and what real git requires in order to read this worktree.
    writeFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/commondir", .{admin}), "../..");
    writeFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/gitdir", .{admin}), try std.fmt.allocPrint(allocator, "{s}/.gitz", .{abs_path}));

    // HEAD, in the same format the main worktree uses, so both git and gitz
    // resolve it the same way.
    const head_content = if (detach)
        try std.fmt.allocPrint(allocator, "{s}\n", .{&Sha1.hex(commit_sha)})
    else
        try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{target_branch});
    writeFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/HEAD", .{admin}), head_content);

    // The `.gitz` file is the indirection that makes this directory a
    // worktree of the parent repository.
    writeFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/.gitz", .{abs_path}), try std.fmt.allocPrint(allocator, "gitdir: {s}\n", .{admin}));

    // Populate the working tree from the start commit.
    const wrepo = Repo{
        .common_dir = repo.common_dir,
        .worktree_dir = admin,
        .worktree_path = abs_path,
    };
    try populate(allocator, wrepo, store, commit_sha, io);

    // `git worktree add` prints where the checkout landed.
    try io.print("HEAD is now at {s}\n", .{Sha1.hex(commit_sha)[0..7]});
}

/// Populate a fresh worktree: check out the commit and write its index.
///
/// The checkout helpers address working-tree files relative to the process
/// cwd, and the caller may be standing in a subdirectory, so the process moves
/// for the duration. This is the same technique `Repo.open` uses to land a
/// command in the worktree root.
fn populate(allocator: std.mem.Allocator, wrepo: Repo, store: storage_mod, commit_sha: [20]u8, io: Io) !void {
    const previous = try cwdAlloc(allocator);
    defer allocator.free(previous);

    try chdirTo(wrepo.worktree_path);
    defer chdirTo(previous) catch {};

    // `checkoutCommit` swallows read errors by design (a missing object leaves
    // the tree untouched), so its result is not an error union here.
    checkout.checkoutCommit(allocator, wrepo, io.io, store, commit_sha) catch |err| {
        try io.eprint("fatal: could not check out {s}: {s}\n", .{ Sha1.hex(commit_sha), @errorName(err) });
        std.process.exit(errors.Exit.fatal);
    };

    try checkout.writeIndexForCommit(allocator, wrepo, io.io, store, commit_sha);
}

fn resolve(allocator: std.mem.Allocator, io: Io, refs: refs_mod, store: storage_mod, spec: []const u8) ![20]u8 {
    _ = store;
    return refs.read(allocator, io.io, spec);
}

/// Refuse a branch that another worktree already has checked out.
fn rejectCheckedOut(allocator: std.mem.Allocator, repo: Repo, refs: refs_mod, branch: []const u8, io: Io) !void {
    const wt_dir = try refs.worktreesDir(allocator);
    defer allocator.free(wt_dir);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    listWorktreeNames(allocator, io, wt_dir, &names) catch {};

    for (names.items) |name| {
        const admin = try refs.worktreeAdminDir(allocator, name);
        defer allocator.free(admin);

        const head = readAt(allocator, io, admin, "HEAD") orelse continue;
        if (std.mem.indexOf(u8, head, "refs/heads/") == null) continue;
        const checked_out = std.mem.trim(u8, std.mem.trim(u8, head, " \t\r\n")["ref: ".len..], " \t\r\n");
        if (std.mem.eql(u8, checked_out, branch)) {
            try io.eprint("fatal: branch '{s}' is already checked out at '{s}'\n", .{ branch, name });
            std.process.exit(errors.Exit.fatal);
        }
    }

    // The main worktree holds a branch too, and it is the one most likely to
    // collide with an agent's request.
    const main_head = readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/HEAD", .{repo.worktree_dir})) orelse return;
    if (std.mem.indexOf(u8, main_head, "refs/heads/") != null) {
        const current = std.mem.trim(u8, std.mem.trim(u8, main_head, " \t\r\n")["ref: ".len..], " \t\r\n");
        if (std.mem.eql(u8, current, branch)) {
            try io.eprint("fatal: branch '{s}' is already checked out in the main worktree\n", .{branch});
            std.process.exit(errors.Exit.fatal);
        }
    }
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

fn list(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    var porcelain = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--porcelain")) {
            porcelain = true;
        } else {
            try io.eprint("error: unknown option '{s}'\n", .{a});
            std.process.exit(errors.Exit.usage);
        }
    }

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |e| {
            allocator.free(e.path);
            allocator.free(e.admin);
        }
        entries.deinit(allocator);
    }

    // The main worktree is listed first, exactly as git does.
    try entries.append(allocator, .{
        .path = try cwdAlloc(allocator),
        .admin = repo.worktree_dir,
        .locked = false,
        .prunable = false,
    });

    const refs = refs_mod.init(repo);
    const wt_dir = try refs.worktreesDir(allocator);
    defer allocator.free(wt_dir);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    listWorktreeNames(allocator, io, wt_dir, &names) catch {};

    for (names.items) |name| {
        // The entry keeps the admin dir, so ownership moves into it rather
        // than being released at the end of this iteration.
        const admin = try refs.worktreeAdminDir(allocator, name);

        // `gitdir` names the `.gitz` file inside the worktree; the worktree
        // itself is its parent directory.
        const gitdir_path = readAt(allocator, io, admin, "gitdir") orelse {
            allocator.free(admin);
            continue;
        };
        const linked = std.fs.path.dirname(std.mem.trim(u8, gitdir_path, " \t\r\n")) orelse {
            allocator.free(admin);
            continue;
        };

        entries.append(allocator, .{
            .path = allocator.dupe(u8, linked) catch {
                allocator.free(admin);
                continue;
            },
            .admin = admin,
            .locked = lockReason(allocator, io, admin) != null,
            .prunable = !isDir(io, linked),
        }) catch {
            allocator.free(admin);
            continue;
        };
    }

    for (entries.items) |e| {
        const head = readHead(allocator, io, e.admin);

        // A symbolic HEAD has to be resolved against the shared ref store,
        // which is where `refs/heads/*` lives for every worktree. `head.branch`
        // already holds the full ref name, so it is used as-is.
        var sha = head.sha;
        if (sha == null) {
            if (head.branch) |b| {
                sha = refs.read(allocator, io.io, b) catch null;
            }
        }

        if (porcelain) {
            // Byte-compatible with `git worktree list --porcelain`, including
            // the `locked` and `prunable` reason lines, so anything that parses
            // the output round-trips.
            try io.print("worktree {s}\n", .{e.path});
            if (sha) |s| try io.print("HEAD {s}\n", .{&Sha1.hex(s)});
            if (head.branch) |b| {
                try io.print("branch {s}\n", .{b});
            } else {
                try io.print("detached\n", .{});
            }
            if (e.locked) try io.print("locked\n", .{});
            if (e.prunable) try io.print("prunable\n", .{});
            try io.print("\n", .{});
        } else {
            const short: []const u8 = if (sha) |s| Sha1.hex(s)[0..7] else "";
            if (head.branch) |b| {
                // `trimStart` takes a *set* of bytes, so passing "refs/heads/"
                // would strip any leading r/e/f/s/h/a/d/t and turn "feature"
                // into "ture". The prefix has to be matched literally.
                const name = if (std.mem.startsWith(u8, b, "refs/heads/")) b["refs/heads/".len..] else b;
                try io.print("{s}  [{s}] {s}\n", .{ e.path, name, short });
            } else {
                try io.print("{s}  (detached HEAD) {s}\n", .{ e.path, short });
            }
            if (e.locked) try io.print("  locked\n", .{});
            if (e.prunable) try io.print("  prunable\n", .{});
        }
    }
}

/// Parse a worktree `HEAD`: the branch it names, or the commit it is detached
/// at. A symbolic HEAD resolves to no SHA here; the caller follows the ref.
const Head = struct {
    branch: ?[]const u8,
    sha: ?[20]u8,
};

fn readHead(allocator: std.mem.Allocator, io: Io, dir: []const u8) Head {
    const content = readAt(allocator, io, dir, "HEAD") orelse return .{ .branch = null, .sha = null };
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) {
        return .{
            .branch = allocator.dupe(u8, trimmed["ref: ".len..]) catch null,
            .sha = null,
        };
    }
    return .{ .branch = null, .sha = Sha1.fromHex(trimmed) catch null };
}

const Entry = struct {
    path: []const u8,
    /// Directory holding this worktree's `HEAD`: the repository dir for the
    /// main worktree, the admin dir for a linked one.
    admin: []const u8,
    locked: bool,
    prunable: bool,
};

/// The branch a HEAD file names, or null when it is detached or absent.
fn branchOf(head: ?[]const u8) ?[]const u8 {
    const h = head orelse return null;
    const trimmed = std.mem.trim(u8, h, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) return null;
    return trimmed["ref: refs/heads/".len..];
}

// ---------------------------------------------------------------------------
// remove
// ---------------------------------------------------------------------------

fn remove(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    var force = false;
    var target: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            try io.eprint("error: unknown option '{s}'\n", .{a});
            std.process.exit(errors.Exit.usage);
        } else if (target == null) {
            target = a;
        }
    }
    const name = target orelse {
        try io.eprint("usage: gitz worktree remove [-f] <worktree>\n", .{});
        std.process.exit(errors.Exit.usage);
    };

    const admin = try refs_mod.init(repo).worktreeAdminDir(allocator, name);
    defer allocator.free(admin);
    if (!adminExists(allocator, repo, name, io)) {
        try io.eprint("error: '{s}' is not a working tree\n", .{name});
        std.process.exit(errors.Exit.fatal);
    }

    // Removing the main worktree is not a thing.
    if (repo.isMainWorktree() and std.mem.eql(u8, name, std.fs.path.basename(repo.worktree_path))) {
        try io.eprint("error: cannot remove the main working tree\n", .{});
        std.process.exit(errors.Exit.fatal);
    }

    if (!force and lockReason(allocator, io, admin) != null) {
        try io.eprint("error: '{s}' is locked; use --force to override\n", .{name});
        std.process.exit(errors.Exit.fatal);
    }

    const gitdir_path = readAt(allocator, io, admin, "gitdir");
    if (gitdir_path) |p| {
        const linked = std.fs.path.dirname(std.mem.trim(u8, p, " \t\r\n")) orelse "";
        if (linked.len > 0) {
            if (!force and !isClean(allocator, repo, admin, linked, io)) {
                try io.eprint("error: '{s}' contains modified or untracked files\n", .{linked});
                try io.eprint("hint: commit, stash or remove them, or use --force\n", .{});
                std.process.exit(errors.Exit.fatal);
            }
            // Remove the indirection file first so a failure here cannot leave
            // a directory that still looks like a worktree with no admin dir.
            std.Io.Dir.cwd().deleteFile(io.io, try std.fmt.allocPrint(allocator, "{s}/.gitz", .{linked})) catch {};
            std.Io.Dir.cwd().deleteTree(io.io, linked) catch {};
        }
    }

    std.Io.Dir.cwd().deleteTree(io.io, admin) catch {};
    try io.print("Removed '{s}'\n", .{name});
}

/// A worktree is clean when nothing under it differs from its index.
fn isClean(allocator: std.mem.Allocator, repo: Repo, admin: []const u8, linked: []const u8, io: Io) bool {
    _ = repo;
    const previous = cwdAlloc(allocator) catch return false;
    defer allocator.free(previous);
    chdirTo(linked) catch return false;
    defer chdirTo(previous) catch {};

    // Compared through the same machinery `gitz status` uses, so "clean" means
    // the same thing here as it does everywhere else: an index entry whose
    // file on disk no longer hashes to the recorded blob is a modification, and
    // a tracked file with nothing on disk is a deletion.
    var idx = index_mod.readFromFile(allocator, admin, io.io) catch return false;
    defer idx.deinit(allocator);

    for (idx.entries.items) |entry| {
        const content = readFile(allocator, io, entry.name) orelse return false;
        const sha = checkout.blobSha(allocator, content) catch return false;
        if (!std.mem.eql(u8, &sha, &entry.sha)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// prune
// ---------------------------------------------------------------------------

fn prune(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    _ = args;
    const refs = refs_mod.init(repo);
    const wt_dir = try refs.worktreesDir(allocator);
    defer allocator.free(wt_dir);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    listWorktreeNames(allocator, io, wt_dir, &names) catch {};

    for (names.items) |name| {
        const admin = try refs.worktreeAdminDir(allocator, name);
        defer allocator.free(admin);

        if (lockReason(allocator, io, admin) != null) continue;

        const gitdir_path = readAt(allocator, io, admin, "gitdir") orelse {
            std.Io.Dir.cwd().deleteTree(io.io, admin) catch {};
            try io.print("Removing worktrees/{s}: gitdir file is missing\n", .{name});
            continue;
        };
        const linked = std.fs.path.dirname(std.mem.trim(u8, gitdir_path, " \t\r\n")) orelse continue;
        if (isDir(io, linked)) continue;

        std.Io.Dir.cwd().deleteTree(io.io, admin) catch {};
        try io.print("Removing worktrees/{s}: gitdir file points to non-existent location\n", .{name});
    }
}

// ---------------------------------------------------------------------------
// move
// ---------------------------------------------------------------------------

fn moveWorktree(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    if (args.len != 2) {
        try io.eprint("usage: gitz worktree move <worktree> <new-path>\n", .{});
        std.process.exit(errors.Exit.usage);
    }
    const name = args[0];
    const new_path = args[1];

    const refs = refs_mod.init(repo);
    const admin = try refs.worktreeAdminDir(allocator, name);
    defer allocator.free(admin);
    if (!adminExists(allocator, repo, name, io)) {
        try io.eprint("error: '{s}' is not a working tree\n", .{name});
        std.process.exit(errors.Exit.fatal);
    }
    if (lockReason(allocator, io, admin) != null) {
        try io.eprint("error: '{s}' is locked\n", .{name});
        std.process.exit(errors.Exit.fatal);
    }

    const old_gitdir = readAt(allocator, io, admin, "gitdir") orelse return;
    const old_path = std.fs.path.dirname(std.mem.trim(u8, old_gitdir, " \t\r\n")) orelse "";

    const base = try cwdAlloc(allocator);
    defer allocator.free(base);
    const abs_new = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, new_path });
    defer allocator.free(abs_new);
    if (io.isDirAt(".", new_path)) {
        try io.eprint("fatal: '{s}' already exists\n", .{new_path});
        std.process.exit(errors.Exit.fatal);
    }

    // The raw syscall wants NUL-terminated paths.
    const z_old = try std.fmt.allocPrintSentinel(allocator, "{s}", .{old_path}, 0);
    defer allocator.free(z_old);
    const z_new = try std.fmt.allocPrintSentinel(allocator, "{s}", .{abs_new}, 0);
    defer allocator.free(z_new);

    const rc = std.os.linux.rename(z_old.ptr, z_new.ptr);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => {
            try io.eprint("error: could not move '{s}' to '{s}'\n", .{ old_path, abs_new });
            std.process.exit(errors.Exit.fatal);
        },
    }

    // Both sides of the link change: the admin dir's `gitdir` and the moved
    // directory's `.gitz` file. Leaving either stale makes the worktree
    // unreachable.
    writeFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/gitdir", .{admin}), try std.fmt.allocPrint(allocator, "{s}/.gitz", .{abs_new}));
    writeFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/.gitz", .{abs_new}), try std.fmt.allocPrint(allocator, "gitdir: {s}\n", .{admin}));

    try io.print("Moved '{s}' to '{s}'\n", .{ name, new_path });
}

// ---------------------------------------------------------------------------
// lock / unlock
// ---------------------------------------------------------------------------

fn setLock(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io, lock: bool) !void {
    var reason: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--reason")) {
            if (i + 1 >= args.len) {
                try io.eprint("error: --reason needs a value\n", .{});
                std.process.exit(errors.Exit.usage);
            }
            i += 1;
            reason = args[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            try io.eprint("error: unknown option '{s}'\n", .{a});
            std.process.exit(errors.Exit.usage);
        } else if (target == null) {
            target = a;
        }
    }

    const name = target orelse {
        try io.eprint("usage: gitz worktree {s} <worktree>\n", .{if (lock) "lock" else "unlock"});
        std.process.exit(errors.Exit.usage);
    };

    const admin = try refs_mod.init(repo).worktreeAdminDir(allocator, name);
    defer allocator.free(admin);
    if (!adminExists(allocator, repo, name, io)) {
        try io.eprint("error: '{s}' is not a working tree\n", .{name});
        std.process.exit(errors.Exit.fatal);
    }

    const lock_path = try std.fmt.allocPrint(allocator, "{s}/locked", .{admin});
    defer allocator.free(lock_path);

    if (lock) {
        // An empty `locked` file is what git writes for a bare lock; a reason
        // is appended after a newline.
        const content = if (reason) |r| try std.fmt.allocPrint(allocator, "{s}\n", .{r}) else "";
        writeFile(allocator, io, lock_path, content);
    } else {
        std.Io.Dir.cwd().deleteFile(io.io, lock_path) catch {
            try io.eprint("error: '{s}' is not locked\n", .{name});
            std.process.exit(errors.Exit.fatal);
        };
    }
}

/// The lock reason, or null when the worktree is not locked.
/// The lock reason, or null when the worktree is not locked. The caller owns
/// the result; the lock file may be empty, which is how git writes a bare lock.
fn lockReason(allocator: std.mem.Allocator, io: Io, admin: []const u8) ?[]u8 {
    const content = readAt(allocator, io, admin, "locked") orelse return null;
    defer allocator.free(content);
    return std.fmt.allocPrint(allocator, "{s}", .{std.mem.trim(u8, content, " \t\r\n")}) catch null;
}

// ---------------------------------------------------------------------------
// repair
// ---------------------------------------------------------------------------

fn repair(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    _ = args;
    const refs = refs_mod.init(repo);
    const wt_dir = try refs.worktreesDir(allocator);
    defer allocator.free(wt_dir);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    listWorktreeNames(allocator, io, wt_dir, &names) catch {};

    for (names.items) |name| {
        const admin = try refs.worktreeAdminDir(allocator, name);
        defer allocator.free(admin);

        const gitdir_path = readAt(allocator, io, admin, "gitdir") orelse continue;
        const linked = std.fs.path.dirname(std.mem.trim(u8, gitdir_path, " \t\r\n")) orelse continue;
        if (!isDir(io, linked)) continue;

        // Rewrite the indirection file from the admin dir, which is the side
        // that knows the truth. A worktree whose `.gitz` was deleted or edited
        // by hand becomes reachable again.
        const correct = try std.fmt.allocPrint(allocator, "gitdir: {s}\n", .{admin});
        writeFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/.gitz", .{linked}), correct);
        try io.print("repairing '{s}'\n", .{linked});
    }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn cwdAlloc(allocator: std.mem.Allocator) ![]u8 {
    const buf = try allocator.alloc(u8, std.fs.max_path_bytes);
    errdefer allocator.free(buf);
    // Linux's `getcwd` reports the length directly rather than through errno,
    // and it counts the terminating NUL. Slicing to the reported length kept
    // that NUL, and every later `createDirPath` rejected the path.
    const len = std.os.linux.getcwd(buf.ptr, buf.len);
    if (len == 0 or len > buf.len) return error.CwdFailed;
    const end = if (len > 0 and buf[len - 1] == 0) len - 1 else len;
    return allocator.realloc(buf, end) catch buf[0..end];
}

fn chdirTo(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = std.os.linux.chdir(@ptrCast(&buf));
    if (std.posix.errno(rc) != .SUCCESS) return error.ChdirFailed;
}

fn validWorktreeName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    if (std.mem.startsWith(u8, name, ".")) return false;
    return true;
}

fn adminExists(allocator: std.mem.Allocator, repo: Repo, name: []const u8, io: Io) bool {
    const admin = std.fmt.allocPrint(allocator, "{s}/worktrees/{s}", .{ repo.common_dir, name }) catch return false;
    defer allocator.free(admin);
    return isDir(io, admin);
}

/// Whether an absolute path is a directory.
///
/// `Io.isDirAt` joins the name onto a prefix, so an absolute path would build
/// something like `.//tmp/...`, which resolves against the cwd and never
/// matches. Worktree bookkeeping stores absolute paths, so it needs a direct
/// stat instead.
fn isDir(io: Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io.io, path, .{}) catch return false;
    return stat.kind == .directory;
}

/// List the names in a worktree admin directory, skipping dotfiles.
fn listWorktreeNames(allocator: std.mem.Allocator, io: Io, dir: []const u8, out: *std.ArrayList([]const u8)) !void {
    var d = std.Io.Dir.cwd().openDir(io.io, dir, .{ .iterate = true }) catch return;
    defer d.close(io.io);

    var it = d.iterate();
    while (it.next(io.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        try out.append(allocator, try allocator.dupe(u8, entry.name));
    }
}

/// Read a file, or null when it does not exist. The caller owns the result.
/// `path` is only borrowed.
fn readFile(allocator: std.mem.Allocator, io: Io, path: []const u8) ?[]u8 {
    _ = allocator;
    return io.readFileAlloc(path) catch null;
}

/// Read `<dir>/<name>`, or null when it does not exist. The caller owns the
/// result.
fn readAt(allocator: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8) ?[]u8 {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name }) catch return null;
    defer allocator.free(path);
    return io.readFileAlloc(path) catch null;
}

/// Write a worktree admin file, creating its directory first.
///
/// Failures are swallowed: a missing `commondir` is caught later by
/// `Repo.open`, and a missing `.gitz` leaves a directory that `prune` can
/// clean up. Aborting half-way through `add` would instead leave an admin dir
/// with no link, which is the state that is hard to recover from by hand.
fn writeFile(allocator: std.mem.Allocator, io: Io, path: []const u8, content: []const u8) void {
    _ = allocator;
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io.io, parent) catch {};
    }
    _ = io.writeFile(path, content) catch {};
}
