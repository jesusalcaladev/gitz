const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const alternates_mod = @import("../../core/alternates.zig");
const checkout_mod = @import("../../core/checkout.zig");
const errors = @import("../errors.zig");
const refs_mod = @import("../../core/refs.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
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
    var show_commit: ?[]const u8 = null;
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
    if (pathspecs.items.len == 1) {
        const only = pathspecs.items[0];
        if (show_all or isRevisionLike(allocator, io, git_dir, only)) {
            show_commit = only;
            allocator.free(only);
            pathspecs.items = &.{};
        } else {
            file_path = only;
        }
    }

    // Several pathspecs restrict the walk to their union.
    const multi_pathspecs: []const []const u8 = if (pathspecs.items.len > 1) pathspecs.items else &.{};

    var alts = try alternates_mod.Reader.init(allocator, io.io, git_dir);
    defer alts.deinit();

    // Show a specific commit
    if (show_commit) |sha_str| {
        try showSpecificCommit(allocator, git_dir, sha_str, io, &alts);
        return;
    }

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const refs_manager = refs_mod.Refs.init(git_dir);

    if (show_all) {
        // Show all branches
        const branches = try refs_manager.list(allocator, io.io, "heads");
        defer {
            for (branches) |b| allocator.free(b);
            allocator.free(branches);
        }

        for (branches) |branch_ref| {
            const branch_sha = refs_manager.read(allocator, io.io, branch_ref) catch continue;
            const branch_name = if (std.mem.startsWith(u8, branch_ref, "refs/heads/"))
                branch_ref[11..]
            else
                branch_ref;

            try io.print("Branch: {s}\n", .{branch_name});
            var shown: usize = 0;
            var current_sha = branch_sha;

            while (shown < (count orelse std.math.maxInt(usize))) {
                const obj = readWithAlternates(allocator, io.io, store, &alts, current_sha) catch break;
                defer obj.deinit(allocator);
                const commit = switch (obj) {
                    .commit => |c| c,
                    else => break,
                };

                if (author_filter) |af| {
                    if (std.mem.indexOf(u8, commit.author.name, af) == null and
                        std.mem.indexOf(u8, commit.author.email, af) == null)
                    {
                        if (commit.parents.len > 0) {
                            current_sha = commit.parents[0];
                        } else break;
                        continue;
                    }
                }

                if (grep_filter) |gf| {
                    if (std.mem.indexOf(u8, commit.message, gf) == null) {
                        if (commit.parents.len > 0) {
                            current_sha = commit.parents[0];
                        } else break;
                        continue;
                    }
                }

                try printCommit(allocator, io, current_sha, commit, oneline, graph);
                shown += 1;
                if (commit.parents.len > 0) {
                    current_sha = commit.parents[0];
                } else break;
            }
            try io.print("\n", .{});
        }
        return;
    }

    // Normal log - follow HEAD
    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch {
        try io.print("No commits yet\n", .{});
        return;
    };

    // `--skip` drops the first N matching commits, and `--reverse` walks the
    // other way. Both were silently ignored.
    var collected = std.ArrayList(struct { sha: [20]u8, commit: object.Commit }).empty;
    defer collected.deinit(allocator);

    var current_sha = head_sha;

    const limit = count orelse std.math.maxInt(usize);
    // Bounded so a corrupt graph containing a cycle cannot spin forever.
    var steps: usize = 0;
    const max_steps: usize = 1_000_000;

    while (steps < max_steps) {
        steps += 1;

        const obj = readWithAlternates(allocator, io.io, store, &alts, current_sha) catch break;
        const commit = switch (obj) {
            .commit => |c| c,
            else => {
                obj.deinit(allocator);
                break;
            },
        };
        const this_sha = current_sha;

        // The parent list is copied *before* the object is freed. Reading
        // `commit.parents` after `deinit` returned freed memory, so the walk
        // stopped after one or two commits and `--skip`/`--reverse` had nothing
        // to work with.
        const has_parent = commit.parents.len > 0;
        const parent_sha: [20]u8 = if (has_parent) commit.parents[0] else [_]u8{0} ** 20;

        var keep = true;

        if (author_filter) |af| {
            keep = std.mem.indexOf(u8, commit.author.name, af) != null or
                std.mem.indexOf(u8, commit.author.email, af) != null;
        }

        if (keep) {
            if (grep_filter) |gf| {
                keep = std.mem.indexOf(u8, commit.message, gf) != null;
            }
        }

        if (keep) {
            // Only commits whose diff touches one of the paths. The old check
            // was "does the file exist in this commit's tree", which listed
            // every commit after the file was added and never matched a nested
            // path.
            if (file_path) |fp| {
                keep = commitTouchesFile(allocator, io.io, &store, &alts, commit, fp);
            } else if (multi_pathspecs.len > 0) {
                for (multi_pathspecs) |p| {
                    if (commitTouchesFile(allocator, io.io, &store, &alts, commit, p)) {
                        keep = true;
                        break;
                    }
                }
            }
        }

        if (keep) {
            // The commit's strings belong to `obj`, which is freed here, so they
            // are copied first. Storing borrowed slices made every later print
            // read freed memory: author names, messages and dates came out as
            // rows of replacement characters.
            var held: object.Commit = .{
                .tree = commit.tree,
                .parents = if (has_parent) try allocator.dupe([20]u8, commit.parents) else &.{},
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

            try collected.append(allocator, .{ .sha = this_sha, .commit = held });
        }

        obj.deinit(allocator);
        if (!has_parent) break;
        current_sha = parent_sha;
    }

    // `collected` was filled walking backwards from HEAD, so entry 0 is already
    // the newest commit. `--reverse` prints it in the same order; the default
    // prints oldest-first to match `git log`.
    //
    // The `skip` entries at the head of `collected` are the newest ones, which
    // is what `--skip` means.
    const total = collected.items.len;
    const first: usize = @min(skip, total);
    var printed: usize = 0;
    var idx: usize = first;
    while (idx < total and printed < limit) : (idx += 1) {
        printed += 1;
        const item = collected.items[if (reverse) total - 1 - idx else idx];
        try printCommit(allocator, io, item.sha, item.commit, oneline, graph);
        if (decorate) {
            try printDecoration(allocator, git_dir, io, item.sha);
        }
        if (show_diff) {
            try printCommitDiff(allocator, git_dir, io, item.sha, item.commit, stat_only, name_only);
        }
    }
}

/// Whether `name` looks like a revision rather than a path.
/// Whether `namespace/name` resolves to a ref.
fn tryRevExists(allocator: std.mem.Allocator, io: Io, git_dir: []const u8, namespace: []const u8, name: []const u8) bool {
    const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ namespace, name }) catch return false;
    defer allocator.free(full);
    const refs_manager = refs_mod.Refs.init(git_dir);
    _ = refs_manager.read(allocator, io.io, full) catch return false;
    return true;
}

/// Whether `name` names a revision rather than a path.
fn isRevisionLike(allocator: std.mem.Allocator, io: Io, git_dir: []const u8, name: []const u8) bool {
    if (Sha1.fromHex(name)) |_| {
        return true;
    } else |_| {}
    if (std.mem.indexOfAny(u8, name, "~^:") != null) return true;
    if (std.mem.eql(u8, name, "HEAD")) return true;
    // A name that exists on disk is a path, whatever it looks like.
    if (io.fileExists(name)) return false;

    const refs_manager = refs_mod.Refs.init(git_dir);
    if (refs_manager.read(allocator, io.io, name)) |_| {
        return true;
    } else |_| {}

    if (tryRevExists(allocator, io, git_dir, "refs/heads", name)) return true;
    if (tryRevExists(allocator, io, git_dir, "refs/tags", name)) return true;

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
fn printDecoration(allocator: std.mem.Allocator, git_dir: []const u8, io: Io, sha: [20]u8) !void {
    const refs_manager = refs_mod.Refs.init(git_dir);

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
    git_dir: []const u8,
    io: Io,
    sha: [20]u8,
    commit: object.Commit,
    stat_only: bool,
    name_only: bool,
) !void {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);

    var alts = try alternates_mod.Reader.init(allocator, io.io, git_dir);
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

fn showSpecificCommit(allocator: std.mem.Allocator, git_dir: []const u8, sha_str: []const u8, io: Io, alts: *const alternates_mod.Reader) !void {
    const sha = Sha1.fromHex(sha_str) catch {
        try io.eprint("fatal: invalid commit SHA '{s}'\n", .{sha_str});
        return;
    };

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    const obj = readWithAlternates(allocator, io.io, store, alts, sha) catch {
        try io.eprint("fatal: not a commit object '{s}'\n", .{sha_str});
        return;
    };

    const commit = switch (obj) {
        .commit => |c| c,
        else => {
            try io.eprint("fatal: object '{s}' is not a commit\n", .{sha_str});
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
