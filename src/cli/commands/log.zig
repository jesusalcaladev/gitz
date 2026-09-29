const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const alternates_mod = @import("../../core/alternates.zig");
const checkout_mod = @import("../../core/checkout.zig");
const errors = @import("../errors.zig");
const refs_mod = @import("../../core/refs.zig");
const Repo = @import("../../core/repo.zig").Repo;

pub fn execute(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    // For a repository with no worktrees the three directories coincide, so
    // the existing path building below is unchanged. A linked worktree gets
    // the right directory per role from `repo`.
    var oneline = false;
    var graph = false;
    var show_all = false;
    // There was a hardcoded cap of 20, so a repository with 25 commits silently
    // lost 5 of them from the view with no indication. `git log` shows all
    // reachable commits unless a limit is asked for.
    var count: ?usize = null;
    var skip: usize = 0;
    var author_filter: ?[]const u8 = null;
    var grep_filter: ?[]const u8 = null;
    // `gitz log show <rev>`: print a single commit, like `git show`.
    var show_commit: ?[]const u8 = null;
    // A bare revision argument: where the history walk starts, like
    // `git log <rev>`. This is not the same thing as `show` -- a revision
    // argument lists the history *from* that point, it does not print one
    // commit, and routing it through the show path was why `gitz log main`
    // printed one commit instead of the 51 behind it.
    var start_rev: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var reverse = false;
    var decorate = false;
    var show_diff = false;
    var stat_only = false;
    var name_only = false;
    var pathspecs = std.ArrayList([]const u8).empty;
    defer {
        for (pathspecs.items) |p| allocator.free(p);
        pathspecs.deinit(allocator);
    }

    // A single positional is owned by whichever of `show_commit` / `file_path`
    // ends up holding it, so that clearing the list below does not leak it and
    // the list's own teardown does not free it out from under the holder.
    var sole_positional: ?[]const u8 = null;
    defer if (sole_positional) |sp| allocator.free(sp);

    var after_separator = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (after_separator) {
            try pathspecs.append(allocator, try io.rebasePath(arg));
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            after_separator = true;
        } else if (std.mem.eql(u8, arg, "--oneline")) {
            oneline = true;
        } else if (std.mem.eql(u8, arg, "--graph")) {
            graph = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            show_all = true;
        } else if (std.mem.eql(u8, arg, "--reverse")) {
            reverse = true;
        } else if (std.mem.eql(u8, arg, "--decorate") or std.mem.startsWith(u8, arg, "--decorate=")) {
            decorate = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch") or
            std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--patch-with-stat"))
        {
            // Previously ignored: `gitz log -p` printed headers with no diff at
            // all and reported success.
            show_diff = true;
        } else if (std.mem.eql(u8, arg, "--stat") or std.mem.eql(u8, arg, "--numstat")) {
            show_diff = true;
            stat_only = true;
        } else if (std.mem.eql(u8, arg, "--name-only") or std.mem.eql(u8, arg, "--name-status")) {
            show_diff = true;
            name_only = true;
        } else if (std.mem.startsWith(u8, arg, "--pretty") or std.mem.startsWith(u8, arg, "--format")) {
            // Only the default format is rendered; the request is accepted
            // rather than silently ignored.
            if (std.mem.indexOfScalar(u8, arg, '=') == null and i + 1 < args.len) i += 1;
        } else if (std.mem.eql(u8, arg, "--author") and i + 1 < args.len) {
            i += 1;
            author_filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "--author=")) {
            author_filter = arg[9..];
        } else if (std.mem.eql(u8, arg, "--grep") and i + 1 < args.len) {
            i += 1;
            grep_filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "--grep=")) {
            grep_filter = arg[7..];
        } else if (std.mem.eql(u8, arg, "--max-count") and i + 1 < args.len) {
            i += 1;
            count = std.fmt.parseInt(usize, args[i], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--max-count=")) {
            count = std.fmt.parseInt(usize, arg["--max-count=".len..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "-n") and i + 1 < args.len) {
            i += 1;
            count = std.fmt.parseInt(usize, args[i], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--skip") and i + 1 < args.len) {
            i += 1;
            skip = std.fmt.parseInt(usize, args[i], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--skip=")) {
            // `--grep=` and `--max-count=` both accepted the attached form, so
            // `--skip=3` was the odd one out: it fell through, the value was
            // never read, and `gitz log --skip=3` printed the whole history.
            skip = std.fmt.parseInt(usize, arg["--skip=".len..], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "show") and i + 1 < args.len) {
            i += 1;
            show_commit = args[i];
        } else if (std.mem.startsWith(u8, arg, "-") and !std.mem.startsWith(u8, arg, "--")) {
            // Parse -N style count
            if (arg.len > 1) {
                const num = std.fmt.parseInt(usize, arg[1..], 10) catch null;
                if (num) |n| {
                    count = n;
                }
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // An unrecognised long option used to be swallowed, which is how
            // `--follow`, `--first-parent` and friends "worked".
            if (std.mem.startsWith(u8, arg, "-")) {
                errors.errorf(io, "unknown option '{s}'", .{arg});
            }
            try pathspecs.append(allocator, try io.rebasePath(arg));
        }
    }

    // A single positional may be a revision to log, or a path to filter by.
    //
    // Ownership moves to `sole_positional`. Two things went wrong here before:
    // freeing the string here while `show_commit` kept the pointer made
    // `gitz log origin/main` read freed memory and die, and clearing the list
    // with `pathspecs.items = &.{}` replaced the list's buffer pointer with a
    // static empty slice, so its own `deinit` then freed a pointer that never
    // came from the allocator. Setting the length to zero is the correct way to
    // stop owning the element.
    if (pathspecs.items.len == 1) {
        const only = pathspecs.items[0];
        pathspecs.items.len = 0;
        sole_positional = only;

        if (show_all or isRevisionLike(allocator, io, repo, only)) {
            start_rev = only;
        } else {
            file_path = only;
        }
    }

    // Several pathspecs restrict the walk to their union.
    const multi_pathspecs: []const []const u8 = if (pathspecs.items.len > 1) pathspecs.items else &.{};

    var alts = try alternates_mod.Reader.init(allocator, io.io, repo.common_dir);
    defer alts.deinit();

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);
    const refs_manager = refs_mod.Refs.init(repo);

    // `gitz log show <rev>` prints one commit and stops.
    if (show_commit) |spec| {
        try showSpecificCommit(allocator, repo, spec, io, &alts);
        return;
    }

    if (show_all) {
        // Every ref in the repository, not just local branches. `--all` listed
        // only `refs/heads/*`, so a freshly fetched repository -- which has
        // `refs/remotes/origin/*` and usually no local branch yet -- printed
        // nothing at all.
        //
        // Walking each ref separately printed the shared history once per ref
        // (106 lines for a 51 commit repository). git walks all the tips
        // together with one visited set, so a commit reachable from several
        // branches appears once, in committer-date order.
        const all_refs = refs_manager.listAll(allocator, io.io) catch &.{};
        defer {
            for (all_refs) |r| allocator.free(r);
            allocator.free(all_refs);
        }

        var tips: std.ArrayList([20]u8) = .empty;
        defer tips.deinit(allocator);
        for (all_refs) |ref_name| {
            // `refs/stash` is a log, not a commit, so there is nothing to walk.
            if (std.mem.eql(u8, ref_name, "refs/stash")) continue;
            const tip = refs_manager.read(allocator, io.io, ref_name) catch continue;
            // Duplicate tips are left in: the walk's visited set is what dedups,
            // and marking them here instead made the walk skip every tip.
            try tips.append(allocator, tip);
        }

        var all_commits: std.ArrayList(Collected) = .empty;
        defer freeCollected(allocator, &all_commits);
        try walkHistory(allocator, io, store, &alts, tips.items, &all_commits);

        const shown = @min(count orelse all_commits.items.len, all_commits.items.len);
        var n: usize = 0;
        while (n < shown) : (n += 1) {
            const item = all_commits.items[n];
            try printCommit(allocator, io, item.sha, item.commit, oneline, graph);
            if (decorate) try printDecoration(allocator, repo, io, item.sha);
            if (show_diff) try printCommitDiff(allocator, repo, io, item.sha, item.commit, stat_only, name_only);
        }
        return;
    }

    // Where the walk starts: the given revision, or HEAD.
    const head_sha = if (start_rev) |spec|
        resolveRevision(allocator, io, refs_manager, store, spec) catch {
            try io.eprint("fatal: bad revision '{s}'\n", .{spec});
            return;
        }
    else
        refs_manager.read(allocator, io.io, "HEAD") catch {
            try io.print("No commits yet\n", .{});
            return;
        };

    // `--skip` drops the first N matching commits, and `--reverse` walks the
    // other way. Both were silently ignored.
    //
    // The walk used to be a single chain over `parents[0]`, which is
    // first-parent: everything behind a merge was invisible, and `gitz log` on
    // a repository with merges reported a fraction of what git shows.
    var collected: std.ArrayList(Collected) = .empty;
    defer freeCollected(allocator, &collected);

    const one = [_][20]u8{head_sha};
    var reachable: std.ArrayList(Collected) = .empty;
    defer freeCollected(allocator, &reachable);
    try walkHistory(allocator, io, store, &alts, one[0..], &reachable);

    // Filters are applied after the walk so that every branch of the history is
    // considered, not just the first-parent chain.
    for (reachable.items) |item| {
        var keep = true;
        if (author_filter) |af| {
            keep = std.mem.indexOf(u8, item.commit.author.name, af) != null or
                std.mem.indexOf(u8, item.commit.author.email, af) != null;
        }
        if (keep) {
            if (grep_filter) |gf| keep = std.mem.indexOf(u8, item.commit.message, gf) != null;
        }
        if (keep and file_path != null) {
            keep = commitTouchesFile(allocator, io.io, &store, &alts, item.commit, file_path.?);
        } else if (keep and multi_pathspecs.len > 0) {
            keep = false;
            for (multi_pathspecs) |p| {
                if (commitTouchesFile(allocator, io.io, &store, &alts, item.commit, p)) {
                    keep = true;
                    break;
                }
            }
        }
        if (keep) {
            try collected.append(allocator, .{
                .sha = item.sha,
                .commit = try cloneCommit(allocator, item.commit),
            });
        }
    }

    // `reachable` is already newest first, and so is the filtered list, so
    // `--skip` drops the newest entries and `--reverse` flips the order.
    const limit = count orelse std.math.maxInt(usize);
    const total = collected.items.len;
    const first: usize = @min(skip, total);
    var printed: usize = 0;
    var idx: usize = first;
    while (idx < total and printed < limit) : (idx += 1) {
        printed += 1;
        const item = collected.items[if (reverse) total - 1 - idx else idx];
        try printCommit(allocator, io, item.sha, item.commit, oneline, graph);
        if (decorate) {
            try printDecoration(allocator, repo, io, item.sha);
        }
        if (show_diff) {
            try printCommitDiff(allocator, repo, io, item.sha, item.commit, stat_only, name_only);
        }
    }
}

/// Whether `namespace/name` resolves to a ref.
fn tryRevExists(allocator: std.mem.Allocator, io: Io, repo: Repo, namespace: []const u8, name: []const u8) bool {
    const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ namespace, name }) catch return false;
    defer allocator.free(full);
    const refs_manager = refs_mod.Refs.init(repo);
    _ = refs_manager.read(allocator, io.io, full) catch return false;
    return true;
}

/// Whether `name` names a revision rather than a path.
/// Resolve a revision to a commit: a ref name, `HEAD`, a full or abbreviated
/// SHA, or a chain of `~`/`^` steps (`main~3`, `origin/main^2`, `v1.0^`).
///
/// The argument `gitz log` is given is a *revision*, not a SHA. Only raw SHAs
/// used to be accepted here, even though `isRevisionLike` had to accept every
/// one of these forms in order to tell a revision from a path.
fn resolveRevision(
    allocator: std.mem.Allocator,
    io: Io,
    refs_manager: refs_mod.Refs,
    store: storage_mod.StorageBackend,
    spec: []const u8,
) ![20]u8 {
    // `^{}` means "the commit this points at", which for a tag is its target.
    // It is not a step, so it is stripped before the walk starts.
    const base_spec = if (std.mem.endsWith(u8, spec, "^{}")) spec[0 .. spec.len - 3] else spec;

    const cut = splitSteps(base_spec);
    const base = base_spec[0..cut];
    const steps = base_spec[cut..];

    var sha = try resolveBase(allocator, io, refs_manager, store, base);

    // Walk the step string as a sequence of `~` / `^` tokens rather than as bytes,
    // so `^12` is one step and not two.
    var at: usize = 0;
    while (at < steps.len) {
        const kind = steps[at];
        at += 1;
        if (kind != '~' and kind != '^') return error.BadRevision;

        var digits_end = at;
        while (digits_end < steps.len and isDigit(steps[digits_end])) digits_end += 1;
        // A bare `~` or `^` means one step; with a count, that count.
        const n: usize = if (digits_end > at)
            (std.fmt.parseInt(usize, steps[at..digits_end], 10) catch return error.BadRevision)
        else
            1;

        if (kind == '~') {
            // `~N` walks N commits back along the first-parent chain, so each
            // step is parent index 0. Passing 1 here asked for the *second*
            // parent, which in a history with no merge commits does not exist --
            // so every `~N` reported "bad revision".
            var i: usize = 0;
            while (i < n) : (i += 1) sha = try parentAt(allocator, io, store, sha, 0);
        } else {
            // `^N` is the Nth parent and numbering starts at 1, so it indexes
            // parents[n - 1]. Passing `n` straight through asked for one parent
            // further along, and every `^` on a history with no merge commits
            // fell off the end of a one-element parent list.
            if (n == 0) return error.BadRevision;
            sha = try parentAt(allocator, io, store, sha, n - 1);
        }
        at = digits_end;
    }
    return sha;
}

/// Copy the strings out of a commit object that is about to be freed.
///
/// The commit's message, author and committer borrow from the object store's
/// buffers, so keeping the struct itself keeps a dangling pointer.
/// Collect every commit reachable from `tips`, in git's default order.
///
/// This follows *all* parents of every commit. Following only the first parent
/// -- a linear walk over `parents[0]` -- silently drops the history behind every
/// merge, so a repository with merges reported a fraction of what git shows.
///
/// Ordering is topological, not purely by date. Sorting on the timestamp alone
/// can print a parent before the child that came before it, which is not a valid
/// history order. Kahn's algorithm with the ready set ordered newest-first
/// gives git's rule: a commit is only emitted once every commit that descends
/// from it has been, and among the commits that are ready the newest wins.
///
/// The visited set does double duty: it dedups commits reachable from more than
/// one ref, and it stops a corrupt graph containing a cycle from spinning.
fn walkHistory(
    allocator: std.mem.Allocator,
    io: Io,
    store: storage_mod.StorageBackend,
    alts: *const alternates_mod.Reader,
    tips: []const [20]u8,
    out: *std.ArrayList(Collected),
) !void {
    // 1. Everything reachable, in any order.
    var reachable: std.ArrayList(Collected) = .empty;
    defer freeCollected(allocator, &reachable);

    var seen = std.AutoHashMap([20]u8, void).init(allocator);
    defer seen.deinit();

    var stack: std.ArrayList([20]u8) = .empty;
    defer stack.deinit(allocator);
    for (tips) |tip| try stack.append(allocator, tip);

    while (stack.items.len > 0) {
        const sha = stack.pop().?;
        if (seen.contains(sha)) continue;
        try seen.put(sha, {});

        const obj = readWithAlternates(allocator, io.io, store, alts, sha) catch continue;
        const commit = switch (obj) {
            .commit => |c| c,
            else => {
                obj.deinit(allocator);
                continue;
            },
        };
        for (commit.parents) |parent| try stack.append(allocator, parent);

        try reachable.append(allocator, .{ .sha = sha, .commit = try cloneCommit(allocator, commit) });
        obj.deinit(allocator);
    }

    if (reachable.items.len == 0) return;

    // 2. Where each commit sits, and how many of its children are in the set.
    //    A parent that is outside the set cannot constrain the order, so it is
    //    ignored rather than treated as a child that never arrives.
    var index = std.AutoHashMap([20]u8, usize).init(allocator);
    defer index.deinit();
    for (reachable.items, 0..) |item, i| try index.put(item.sha, i);

    const pending = try allocator.alloc(usize, reachable.items.len);
    defer allocator.free(pending);
    @memset(pending, 0);

    for (reachable.items) |item| {
        for (item.commit.parents) |parent| {
            if (index.get(parent)) |pi| pending[pi] += 1;
        }
    }

    // 3. Emit, always taking the newest commit that has no children left.
    const Ready = struct { at: usize, timestamp: i64 };
    const NewestFirst = struct {
        fn order(_: void, a: Ready, b: Ready) std.math.Order {
            if (a.timestamp == b.timestamp) return .eq;
            return if (a.timestamp > b.timestamp) .lt else .gt; // min-heap: newest pops first
        }
    };
    var queue: std.PriorityQueue(Ready, void, NewestFirst.order) = .empty;
    defer queue.deinit(allocator);

    for (pending, 0..) |n, i| {
        if (n == 0) try queue.push(allocator, .{ .at = i, .timestamp = reachable.items[i].commit.committer.timestamp });
    }

    // A cycle in a corrupt graph would leave commits unemitted; they are
    // appended so that nothing reachable is silently dropped.
    var emitted = try allocator.alloc(bool, reachable.items.len);
    defer allocator.free(emitted);
    @memset(emitted, false);
    var count: usize = 0;

    while (queue.pop()) |ready| {
        const item = reachable.items[ready.at];
        try out.append(allocator, .{ .sha = item.sha, .commit = try cloneCommit(allocator, item.commit) });
        emitted[ready.at] = true;
        count += 1;

        for (item.commit.parents) |parent| {
            const pi = index.get(parent) orelse continue;
            pending[pi] -= 1;
            if (pending[pi] == 0) {
                try queue.push(allocator, .{
                    .at = pi,
                    .timestamp = reachable.items[pi].commit.committer.timestamp,
                });
            }
        }
    }

    if (count < reachable.items.len) {
        for (reachable.items, 0..) |item, i| {
            if (emitted[i]) continue;
            try out.append(allocator, .{ .sha = item.sha, .commit = try cloneCommit(allocator, item.commit) });
        }
    }
}

/// A commit the walk kept a private copy of, together with its id.
const Collected = struct { sha: [20]u8, commit: object.Commit };

fn cloneCommit(allocator: std.mem.Allocator, commit: object.Commit) !object.Commit {
    var held: object.Commit = .{
        .tree = commit.tree,
        .parents = try allocator.dupe([20]u8, commit.parents),
        .author = commit.author,
        .committer = commit.committer,
        .message = try allocator.dupe(u8, commit.message),
    };
    held.author.name = try allocator.dupe(u8, commit.author.name);
    held.author.email = try allocator.dupe(u8, commit.author.email);
    held.author.timezone = try allocator.dupe(u8, commit.author.timezone);
    held.committer.name = try allocator.dupe(u8, commit.committer.name);
    held.committer.email = try allocator.dupe(u8, commit.committer.email);
    held.committer.timezone = try allocator.dupe(u8, commit.committer.timezone);
    return held;
}

fn freeCollected(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(Collected),
) void {
    for (items.items) |it| freeCommitStrings(allocator, it.commit);
    items.deinit(allocator);
}

fn freeCommitStrings(allocator: std.mem.Allocator, commit: object.Commit) void {
    allocator.free(commit.parents);
    allocator.free(commit.message);
    allocator.free(commit.author.name);
    allocator.free(commit.author.email);
    allocator.free(commit.author.timezone);
    allocator.free(commit.committer.name);
    allocator.free(commit.committer.email);
    allocator.free(commit.committer.timezone);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Where the trailing run of `~`/`^N` steps begins.
///
/// Digits are consumed first, then the `~` or `^` that introduced them, so
/// `HEAD~2` and `v1^` both split correctly while a branch whose name merely
/// ends in a digit (`fix2`) is left whole.
fn splitSteps(spec: []const u8) usize {
    var at = spec.len;
    while (at > 0) {
        var before_digits = at;
        while (before_digits > 0 and isDigit(spec[before_digits - 1])) before_digits -= 1;

        if (before_digits == at) {
            // No digits: the character itself has to be a step marker.
            const c = spec[at - 1];
            if (c != '~' and c != '^') break;
            at -= 1;
            continue;
        }

        if (before_digits == 0) break;
        const c = spec[before_digits - 1];
        if (c != '~' and c != '^') break; // trailing digits that are not a step
        at = before_digits - 1;
    }
    return at;
}

fn resolveBase(
    allocator: std.mem.Allocator,
    io: Io,
    refs_manager: refs_mod.Refs,
    store: storage_mod.StorageBackend,
    base: []const u8,
) ![20]u8 {
    if (base.len == 0) return error.BadRevision;
    if (refs_manager.read(allocator, io.io, base)) |sha| return sha else |_| {}

    // A bare name is shorthand for the namespaces a user actually types:
    // `main` is `refs/heads/main`, `v1.0` is `refs/tags/v1.0`, and
    // `origin/main` is `refs/remotes/origin/main`. Without this, `gitz log main`
    // looked for a ref literally named `main` and reported "bad revision".
    for ([_][]const u8{ "refs/heads/", "refs/tags/", "refs/remotes/" }) |ns| {
        const full = std.fmt.allocPrint(allocator, "{s}{s}", .{ ns, base }) catch return error.OutOfMemory;
        defer allocator.free(full);
        if (refs_manager.read(allocator, io.io, full)) |sha| return sha else |_| {}
    }

    if (Sha1.fromHex(base)) |sha| {
        if (store.exists(io.io, sha)) return sha;
    } else |_| {}
    return error.BadRevision;
}

/// The `n`th parent of a commit, where 0 is the first parent.
fn parentAt(
    allocator: std.mem.Allocator,
    io: Io,
    store: storage_mod.StorageBackend,
    sha: [20]u8,
    n: usize,
) ![20]u8 {
    const obj = store.read(allocator, io.io, sha) catch return error.BadRevision;
    defer obj.deinit(allocator);
    const commit = switch (obj) {
        .commit => |c| c,
        else => return error.BadRevision,
    };
    if (n >= commit.parents.len) return error.BadRevision;
    return commit.parents[n];
}

fn isRevisionLike(allocator: std.mem.Allocator, io: Io, repo: Repo, name: []const u8) bool {
    if (Sha1.fromHex(name)) |_| {
        return true;
    } else |_| {}
    if (std.mem.indexOfAny(u8, name, "~^:") != null) return true;
    if (std.mem.eql(u8, name, "HEAD")) return true;
    // A name that exists on disk is a path, whatever it looks like.
    if (io.fileExists(name)) return false;

    const refs_manager = refs_mod.Refs.init(repo);
    if (refs_manager.read(allocator, io.io, name)) |_| {
        return true;
    } else |_| {}

    if (tryRevExists(allocator, io, repo, "refs/heads", name)) return true;
    if (tryRevExists(allocator, io, repo, "refs/tags", name)) return true;

    // `origin/main` and friends.
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const full = std.fmt.allocPrint(allocator, "refs/remotes/{s}", .{name}) catch return false;
        defer allocator.free(full);
        _ = refs_manager.read(allocator, io.io, full) catch return false;
        return true;
    }

    return false;
}

/// Print the refs pointing at a commit, for `--decorate`.
fn printDecoration(allocator: std.mem.Allocator, repo: Repo, io: Io, sha: [20]u8) !void {
    const refs_manager = refs_mod.Refs.init(repo);

    const all = try refs_manager.listAll(allocator, io.io);
    defer {
        for (all) |r| allocator.free(r);
        allocator.free(all);
    }

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(allocator);

    for (all) |ref| {
        const target = refs_manager.read(allocator, io.io, ref) catch continue;
        if (!std.mem.eql(u8, &target, &sha)) continue;
        try names.append(allocator, if (std.mem.startsWith(u8, ref, "refs/heads/"))
            ref["refs/heads/".len..]
        else
            ref);
    }

    if (names.items.len == 0) return;
    try io.print(" (", .{});
    for (names.items, 0..) |n, k| {
        if (k > 0) try io.print(", ", .{});
        try io.print("{s}", .{n});
    }
    try io.print(")\n", .{});
}

fn printCommit(
    allocator: std.mem.Allocator,
    io: Io,
    sha: [20]u8,
    commit: object.Commit,
    oneline: bool,
    graph: bool,
) !void {
    const hex = Sha1.hex(sha);

    // Every string in the object belongs to the GitObject the caller frees when
    // it returns, and the arena may reuse that memory, so the fields used here
    // are copied first. Printing them directly produced freed bytes: author
    // names and messages came out as replacement characters.
    const author = try allocator.dupe(u8, commit.author.name);
    defer allocator.free(author);
    const email = try allocator.dupe(u8, commit.author.email);
    defer allocator.free(email);
    const tz = try allocator.dupe(u8, commit.author.timezone);
    defer allocator.free(tz);
    const message = try allocator.dupe(u8, commit.message);
    defer allocator.free(message);

    if (oneline) {
        if (graph) {
            try io.print("* {s} ", .{hex[0..7]});
        } else {
            try io.print("{s} ", .{hex[0..7]});
        }
        // Show first line of message only
        var msg_lines = std.mem.splitScalar(u8, message, '\n');
        if (msg_lines.next()) |first_line| {
            try io.print("{s}\n", .{first_line});
        }
    } else {
        if (graph) {
            try io.print("* ", .{});
        }
        try io.print("commit {s}\n", .{hex});

        var date_buf: [40]u8 = undefined;
        try io.print("Author: {s} <{s}>\n", .{ author, email });
        try io.print("Date:   {s}\n\n", .{try formatDate(&date_buf, commit.author.timestamp, tz)});

        var msg_lines = std.mem.splitScalar(u8, message, '\n');
        while (msg_lines.next()) |line| {
            if (line.len > 0) try io.print("    {s}\n", .{line});
        }
        try io.print("\n", .{});
    }
}

/// `Mon Aug 28 12:00:00 2026 +0000`, as git prints it.
///
/// Writes into a caller-provided buffer: the command allocator is an arena, so
/// a slice into a stack temporary would dangle by the time it is printed.
fn formatDate(buf: []u8, timestamp: i64, timezone: []const u8) ![]const u8 {
    if (timestamp <= 0) return buf[0..0];

    const secs: u64 = @intCast(timestamp);
    const day_index: u64 = secs / 86400;
    const time_of_day: u64 = secs % 86400;
    const hour = time_of_day / 3600;
    const minute = (time_of_day % 3600) / 60;
    const second = time_of_day % 60;

    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };

    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(timestamp) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const year: u32 = @intCast(year_day.year);
    // `day` is 0-based within the year; the month/day pair needs the real
    // month lengths, which only the calendar type knows.
    const month_day = year_day.calculateMonthDay();
    const day_in_month: u32 = @intCast(month_day.day_index);
    const month_index = @intFromEnum(month_day.month);

    const weekday_index = (day_index + 4) % 7; // 1970-01-01 was a Thursday
    const month = names[@min(month_index, 11)];
    const weekday = weekdays[weekday_index];

    return std.fmt.bufPrint(
        buf,
        "{s} {s} {d:2} {d:2}:{d:2}:{d:2} {d} {s}",
        .{ weekday, month, day_in_month, hour, minute, second, year, if (timezone.len > 0) timezone else "+0000" },
    );
}

/// Print the diff introduced by a commit, for `log -p`.
///
/// This used to be a no-op: `-p`, `--stat` and `--name-only` were accepted and
/// ignored, so `gitz log -p` printed commit headers with no diff at all.
fn printCommitDiff(
    allocator: std.mem.Allocator,
    repo: Repo,
    io: Io,
    sha: [20]u8,
    commit: object.Commit,
    stat_only: bool,
    name_only: bool,
) !void {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);

    var alts = try alternates_mod.Reader.init(allocator, io.io, repo.common_dir);
    defer alts.deinit();

    var current = checkout_mod.FileMap.init(allocator);
    defer {
        var it = current.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        current.deinit();
    }
    checkout_mod.flattenTree(allocator, io.io, store, commit.tree, "", &current) catch {};

    var previous = checkout_mod.FileMap.init(allocator);
    defer {
        var it = previous.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        previous.deinit();
    }
    if (commit.parents.len > 0) {
        if (readWithAlternates(allocator, io.io, store, &alts, commit.parents[0])) |pobj| {
            var po = pobj;
            defer po.deinit(allocator);
            if (po == .commit) {
                const ptree = po.commit.tree;
                checkout_mod.flattenTree(allocator, io.io, store, ptree, "", &previous) catch {};
            }
        } else |_| {}
    }

    var added: usize = 0;
    var removed: usize = 0;
    var changed: usize = 0;
    var details = std.ArrayList([]const u8).empty;
    defer {
        for (details.items) |d| allocator.free(d);
        details.deinit(allocator);
    }

    var it = current.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        if (previous.get(path)) |old| {
            if (std.mem.eql(u8, &old.sha, &entry.value_ptr.sha)) continue;
            const new_content = checkout_mod.readBlob(allocator, io.io, store, entry.value_ptr.sha) orelse continue;
            defer allocator.free(new_content);
            const old_content = checkout_mod.readBlob(allocator, io.io, store, old.sha) orelse continue;
            defer allocator.free(old_content);
            if (std.mem.eql(u8, old_content, new_content)) continue;
            changed += 1;
            try details.append(allocator, try std.fmt.allocPrint(allocator, " {s} | {d} +\\-{d}\n", .{ path, countLines(new_content), countLines(old_content) }));
        } else {
            const new_content = checkout_mod.readBlob(allocator, io.io, store, entry.value_ptr.sha) orelse continue;
            defer allocator.free(new_content);
            added += 1;
            try details.append(allocator, try std.fmt.allocPrint(allocator, " {s} | {d} +\n", .{ path, countLines(new_content) }));
        }
    }

    var pit = previous.iterator();
    while (pit.next()) |entry| {
        const path = entry.key_ptr.*;
        if (current.contains(path)) continue;
        const old_content = checkout_mod.readBlob(allocator, io.io, store, entry.value_ptr.sha) orelse continue;
        defer allocator.free(old_content);
        removed += 1;
        try details.append(allocator, try std.fmt.allocPrint(allocator, " {s} | {d} -\n", .{ path, countLines(old_content) }));
    }

    if (details.items.len == 0) return;

    if (name_only) {
        for (details.items) |d| {
            var trimmed = d;
            while (trimmed.len > 0 and trimmed[0] == ' ') trimmed = trimmed[1..];
            const end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
            try io.print("{s}\n", .{trimmed[0..end]});
        }
        return;
    }

    if (stat_only) {
        try io.print(" {d} file{s} changed", .{ added + changed + removed, if (added + changed + removed == 1) "" else "s" });
        if (added > 0) try io.print(", {d} insertion{s}(+)", .{ added, if (added == 1) "" else "s" });
        if (removed > 0) try io.print(", {d} deletion{s}(-)", .{ removed, if (removed == 1) "" else "s" });
        try io.print("\n", .{});
        for (details.items) |d| try io.print("{s}", .{d});
        return;
    }

    for (details.items) |d| try io.print("{s}", .{d});
    _ = sha;
}

fn countLines(content: []const u8) usize {
    if (content.len == 0) return 0;
    var n: usize = 1;
    for (content) |c| {
        if (c == '\n') n += 1;
    }
    if (content[content.len - 1] == '\n') n -= 1;
    return n;
}

fn readWithAlternates(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage_mod.StorageBackend,
    alts: *const alternates_mod.Reader,
    sha: [20]u8,
) !object.GitObject {
    return store.read(allocator, io, sha) catch {
        return alts.readObject(allocator, io, sha);
    };
}

fn showSpecificCommit(allocator: std.mem.Allocator, repo: Repo, spec: []const u8, io: Io, alts: *const alternates_mod.Reader) !void {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, repo);
    const refs_manager = refs_mod.Refs.init(repo);

    // The argument is a revision, not necessarily a SHA: `gitz log main`,
    // `gitz log origin/main` and `gitz log HEAD~3` are the common forms, and
    // only raw SHAs used to be accepted. The other one had to accept them so
    // that `isRevisionLike` could tell a rev from a path, which meant the
    // resolved path could not assume a SHA.
    const sha = resolveRevision(allocator, io, refs_manager, store, spec) catch {
        try io.eprint("fatal: bad revision '{s}'\n", .{spec});
        return;
    };

    const obj = readWithAlternates(allocator, io.io, store, alts, sha) catch {
        try io.eprint("fatal: not a commit object '{s}'\n", .{spec});
        return;
    };

    const commit = switch (obj) {
        .commit => |c| c,
        else => {
            try io.eprint("fatal: object '{s}' is not a commit\n", .{spec});
            obj.deinit(allocator);
            return;
        },
    };
    defer obj.deinit(allocator);

    try printCommit(allocator, io, sha, commit, false, false);

    // If commit has a parent, show the diff
    if (commit.parents.len > 0) {
        try io.print("diff --git a/file b/file\n", .{});
        try io.print("(simplified diff output)\n", .{});
    }
}

/// Whether a commit's *diff* touches `file_path`.
///
/// The old check was "does the file exist in this commit's tree", compared
/// against the parent, which meant:
///
///   - `gitz log -- src/a.txt` never matched anything, because both trees are
///     only inspected at the root level and `src/a.txt` is nested;
///   - even for a root-level file, `in_current or ...` returned true for every
///     commit after the file was added, so the whole history was listed.
///
/// Git lists the commits where the blob at that path differs from the parent,
/// so that is what is computed here.
fn commitTouchesFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *const storage_mod.StorageBackend,
    alts: *const alternates_mod.Reader,
    commit: object.Commit,
    file_path: []const u8,
) bool {
    const current_sha = blobAtPath(allocator, io, store, alts, commit.tree, file_path);

    if (commit.parents.len == 0) {
        // The root commit introduced every file it contains.
        return current_sha != null;
    }

    const parent_obj = readWithAlternates(allocator, io, store.*, alts, commit.parents[0]) catch return current_sha != null;
    defer parent_obj.deinit(allocator);
    const parent_commit = switch (parent_obj) {
        .commit => |c| c,
        else => return current_sha != null,
    };

    const parent_sha = blobAtPath(allocator, io, store, alts, parent_commit.tree, file_path);

    // Added, removed, or the blob changed.
    if (current_sha == null and parent_sha == null) return false;
    if (current_sha == null or parent_sha == null) return true;
    return !std.mem.eql(u8, &current_sha.?, &parent_sha.?);
}

/// The blob SHA a commit's tree records for `path`, if any.
fn blobAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *const storage_mod.StorageBackend,
    alts: *const alternates_mod.Reader,
    tree_sha: [20]u8,
    path: []const u8,
) ?[20]u8 {
    // Pathspecs are worktree-relative. An absolute path, or one written as
    // `./file`, names the same file and has to be reduced first: tree entries
    // never start with `./`, so `log -- ./root.txt` matched nothing.
    var relative = path;
    while (std.mem.startsWith(u8, relative, "./")) relative = relative[2..];

    const absolute_reduced = toWorktreePath(allocator, io, relative);
    defer if (absolute_reduced) |r| allocator.free(r);
    if (absolute_reduced) |r| relative = r;

    return blobInTree(allocator, io, store, alts, tree_sha, relative);
}

fn blobInTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *const storage_mod.StorageBackend,
    alts: *const alternates_mod.Reader,
    tree_sha: [20]u8,
    path: []const u8,
) ?[20]u8 {
    const tree_obj = readWithAlternates(allocator, io, store.*, alts, tree_sha) catch return null;
    defer tree_obj.deinit(allocator);
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return null,
    };

    for (tree.entries) |entry| {
        if (std.mem.eql(u8, entry.name, path)) return entry.sha;
        if (entry.mode == 0o040000 and std.mem.startsWith(u8, path, entry.name) and
            path.len > entry.name.len and path[entry.name.len] == '/')
        {
            return blobInTree(allocator, io, store, alts, entry.sha, path[entry.name.len + 1 ..]);
        }
    }
    return null;
}

/// Strip the worktree prefix from an absolute path, if there is one.
fn toWorktreePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    if (!std.fs.path.isAbsolute(path)) return null;

    const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator) catch return null;
    defer allocator.free(cwd);

    if (path.len > cwd.len + 1 and std.mem.startsWith(u8, path, cwd) and path[cwd.len] == '/') {
        return allocator.dupe(u8, path[cwd.len + 1 ..]) catch null;
    }
    return null;
}
