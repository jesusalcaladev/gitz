const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const refs = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const alternates_mod = @import("../../core/alternates.zig");
const object = @import("../../core/object.zig");
const index_mod = @import("../../core/index.zig");
const ignore_mod = @import("../../core/ignore.zig");
const errors = @import("../errors.zig");

/// Whether stdout is a terminal.
///
/// Colour is only meaningful there. Emitting escape sequences into a pipe is
/// what made `gitz diff > p.patch` produce a patch `git apply` could not read.
fn isTerminal(io: Io) bool {
    return io.isTty;
}

/// Machine-readable output, as `git status --porcelain` produces it.
///
/// Every argument used to be discarded, so `--porcelain`, `-s`, `-b` and
/// `--ignored` printed the human TUI and exited 0. Any script doing
/// `[ -n "$(gitz status --porcelain)" ]` therefore saw a non-empty string for a
/// clean tree.
const Porcelain = enum { human, v1, long };

/// What to report about untracked files.
const UntrackedMode = enum { normal, no, all };

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io_in: Io) !void {
    var io = io_in;
    var porcelain: Porcelain = .human;
    var show_branch_header = false;
    var untracked_mode: UntrackedMode = .normal;
    var no_color = false;
    var pathspecs = std.ArrayList([]const u8).empty;
    defer {
        for (pathspecs.items) |p| allocator.free(p);
        pathspecs.deinit(allocator);
    }

    var after_separator = false;
    for (args) |arg| {
        if (after_separator) {
            try pathspecs.append(allocator, try io.rebasePath(arg));
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            after_separator = true;
        } else if (std.mem.eql(u8, arg, "--porcelain") or std.mem.eql(u8, arg, "-s") or
            std.mem.eql(u8, arg, "--short"))
        {
            porcelain = .v1;
        } else if (std.mem.startsWith(u8, arg, "--porcelain=")) {
            porcelain = .v1;
        } else if (std.mem.eql(u8, arg, "--long")) {
            porcelain = .long;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--branch")) {
            show_branch_header = true;
        } else if (std.mem.eql(u8, arg, "-uno") or std.mem.eql(u8, arg, "--untracked-files=no")) {
            untracked_mode = .no;
        } else if (std.mem.eql(u8, arg, "-uall") or std.mem.eql(u8, arg, "--untracked-files=all")) {
            untracked_mode = .all;
        } else if (std.mem.startsWith(u8, arg, "--untracked-files=") or std.mem.startsWith(u8, arg, "-u")) {
            untracked_mode = .all;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            no_color = true;
        } else if (std.mem.eql(u8, arg, "--color") or std.mem.startsWith(u8, arg, "--color=")) {
            no_color = false;
        } else if (std.mem.startsWith(u8, arg, "--ignored")) {
            // Accepted for compatibility; ignored-file reporting is unchanged.
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try pathspecs.append(allocator, try io.rebasePath(arg));
        } else {
            errors.errorf(io, "unknown option '{s}'", .{arg});
        }
    }

    // Machine-readable output is never styled, and neither is redirected
    // output: git colours only a terminal, so `gitz diff > patch` used to
    // produce a patch full of escape sequences that `git apply` rejected.
    if (no_color) io.color = false;
    if (porcelain == .v1) io.color = false;
    if (!isTerminal(io)) io.color = false;

    const refs_manager = refs.Refs.init(git_dir);

    var head_info = refs_manager.head(allocator, io.io) catch {
        try io.print("\x1b[1;33m⚠\x1b[0m \x1b[1mNo commits yet\x1b[0m\n", .{});
        return;
    };
    defer head_info.deinit(allocator);

    // ── Branch header ──
    // The human header is decoration; it must not appear in machine-readable
    // output, where a script parses each line.
    if (porcelain != .v1) switch (head_info) {
        .branch => |b| {
            try io.print("\x1b[1;36m●\x1b[0m On branch \x1b[1;33m{s}\x1b[0m\n", .{b.name.items});
        },
        .detached => |d| {
            const hex = Sha1.hex(d.sha);
            try io.print("\x1b[1;31m●\x1b[0m HEAD detached at \x1b[1;33m{s}\x1b[0m\n", .{hex[0..7]});
        },
        // A branch with no commits is not a detached HEAD: report it the way
        // git does instead of "HEAD detached at 0000000".
        .unborn => |u| {
            try io.print("\x1b[1;36m●\x1b[0m On branch \x1b[1;33m{s}\x1b[0m\n", .{u.name.items});
            try io.print("\n  \x1b[1;33mNo commits yet\x1b[0m\n", .{});
        },
    };

    var idx = try index_mod.Index.readFromFile(allocator, git_dir, io.io);
    defer idx.deinit(allocator);

    // Build flat map of HEAD tree entries: full_path -> SHA
    var head_shas = std.StringHashMap([20]u8).init(allocator);
    defer {
        var iter = head_shas.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        head_shas.deinit();
    }

    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io.io, git_dir);
    var alts = try alternates_mod.Reader.init(allocator, io.io, git_dir);
    defer alts.deinit();

    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch null;
    if (head_sha) |sha| {
        const commit_obj = readWithAlternates(allocator, io.io, &store, &alts, sha) catch null;
        if (commit_obj) |obj| {
            defer obj.deinit(allocator);
            const commit = switch (obj) {
                .commit => |c| c,
                else => null,
            };
            if (commit) |c| {
                const tree_obj = readWithAlternates(allocator, io.io, &store, &alts, c.tree) catch null;
                if (tree_obj) |tobj| {
                    defer tobj.deinit(allocator);
                    const tree = switch (tobj) {
                        .tree => |t| t,
                        else => null,
                    };
                    if (tree) |t| {
                        try flattenTreeSha(&store, &alts, allocator, io.io, t, "", &head_shas);
                    }
                }
            }
        }
    }

    var ignore_stack = ignore_mod.IgnoreStack.init(allocator);
    defer ignore_stack.deinit();
    ignore_stack.loadFile(io.io, ".gitignore") catch {};
    // `gitz init` writes defaults into info/exclude (*.o, node_modules/,
    // .DS_Store) that nothing read, so those files were reported as untracked
    // and `gitz add .` committed them.
    const exclude_path = try std.fmt.allocPrint(allocator, "{s}/info/exclude", .{git_dir});
    defer allocator.free(exclude_path);
    ignore_stack.loadFile(io.io, exclude_path) catch {};

    var working_files = std.ArrayList(WorkingFile){ .items = &.{}, .capacity = 0 };
    defer {
        for (working_files.items) |*f| {
            allocator.free(f.path);
            allocator.free(f.content);
        }
        working_files.deinit(allocator);
    }

    try collectWorkingTree(allocator, io.io, ".", &working_files, &ignore_stack);

    var staged_added = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer staged_added.deinit(allocator);
    var staged_modified = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer staged_modified.deinit(allocator);
    var staged_deleted = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer staged_deleted.deinit(allocator);
    var unstaged_modified = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer unstaged_modified.deinit(allocator);
    var unstaged_deleted = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer unstaged_deleted.deinit(allocator);
    var untracked_list = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer untracked_list.deinit(allocator);

    // Build tracked names set from HEAD tree + index
    var tracked_names = std.StringHashMap(void).init(allocator);
    defer tracked_names.deinit();
    {
        var ht_iter = head_shas.iterator();
        while (ht_iter.next()) |entry| {
            try tracked_names.put(entry.key_ptr.*, {});
        }
    }
    for (idx.entries.items) |entry| {
        const clean = if (std.mem.startsWith(u8, entry.name, "./")) entry.name[2..] else entry.name;
        try tracked_names.put(clean, {});
    }

    // Check staged files: compare index vs HEAD tree
    for (idx.entries.items) |entry| {
        const clean_name = if (std.mem.startsWith(u8, entry.name, "./"))
            entry.name[2..]
        else
            entry.name;

        if (head_shas.get(clean_name)) |head_sha_val| {
            if (!std.mem.eql(u8, &entry.sha, &head_sha_val)) {
                try staged_modified.append(allocator, clean_name);
            }
        } else {
            try staged_added.append(allocator, clean_name);
        }
    }

    // Check for unstaged changes and untracked files
    for (working_files.items) |wf| {
        const clean_name = if (std.mem.startsWith(u8, wf.path, "./"))
            wf.path[2..]
        else
            wf.path;

        const in_head = head_shas.get(clean_name) != null;
        const in_index = findIndexEntry(&idx, clean_name) != null;

        if (in_head or in_index) {
            // The unstaged comparison is against the *index*, not against HEAD.
            // Comparing with HEAD meant:
            //  - a staged-new file that was then edited was skipped entirely
            //    (`orelse continue`), so it appeared nowhere;
            //  - a staged file that was edited again was suppressed by
            //    `already_staged`, hiding the second modification, which then
            //    stayed uncommitted with no indication.
            const index_entry = findIndexEntry(&idx, clean_name);
            const base_sha = if (index_entry) |ie| ie.sha else head_shas.get(clean_name).?;

            const header = std.fmt.allocPrint(allocator, "blob {d}\x00", .{wf.content.len}) catch continue;
            defer allocator.free(header);
            const full = try std.mem.concat(allocator, u8, &.{ header, wf.content });
            defer allocator.free(full);
            const work_sha = Sha1.hash(full);
            if (!std.mem.eql(u8, &work_sha, &base_sha)) {
                // Suppress the entry only when the *index* already holds this
                // exact worktree content, which means there is nothing further
                // to record.
                const index_has_worktree = if (index_entry) |ie| std.mem.eql(u8, &ie.sha, &work_sha) else false;
                if (!index_has_worktree) {
                    try unstaged_modified.append(allocator, clean_name);
                }
            }
        } else {
            try untracked_list.append(allocator, clean_name);
        }
    }

    // Deletions. A HEAD file missing from the working tree is a deletion; if
    // it is also gone from the index the deletion has already been staged.
    //
    // This used to skip any name present in `tracked_names`, which by
    // construction contains every HEAD file — so a deleted file was never
    // reported and `status` said "working tree clean".
    var ht_iter = head_shas.iterator();
    while (ht_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (findWorkingFile(working_files.items, name) != null) continue;
        if (findIndexEntry(&idx, name) != null) {
            try unstaged_deleted.append(allocator, name);
        } else {
            try staged_deleted.append(allocator, name);
        }
    }

    // ── Machine-readable output ──
    if (porcelain == .v1) {
        if (show_branch_header) {
            switch (head_info) {
                .branch => |b| try io.print("## {s}\n", .{b.name.items}),
                .unborn => |u| try io.print("## No commits yet on {s}\n", .{u.name.items}),
                .detached => |d| {
                    const hex = Sha1.hex(d.sha);
                    try io.print("## HEAD (no branch)\n", .{});
                    _ = hex;
                },
            }
        }

        // One line per path, with the staged state in column one and the
        // working-tree state in column two. A path is emitted once, and the
        // unstaged section only supplies the second column for paths that are
        // also staged, so the output matches `git status --porcelain` exactly.
        for (staged_added.items) |name| {
            if (isUnstagedModified(unstaged_modified.items, name)) {
                try io.print("AM {s}\n", .{name});
            } else {
                try io.print("A  {s}\n", .{name});
            }
        }
        for (staged_modified.items) |name| {
            if (isUnstagedModified(unstaged_modified.items, name)) {
                try io.print("MM {s}\n", .{name});
            } else {
                try io.print("M  {s}\n", .{name});
            }
        }
        for (staged_deleted.items) |name| try io.print("D  {s}\n", .{name});
        for (unstaged_modified.items) |name| {
            // Only paths with nothing staged: the combined lines above already
            // cover the rest.
            var staged = false;
            for (staged_modified.items) |s| {
                if (std.mem.eql(u8, s, name)) staged = true;
            }
            for (staged_added.items) |s| {
                if (std.mem.eql(u8, s, name)) staged = true;
            }
            if (!staged) try io.print(" M {s}\n", .{name});
        }
        for (unstaged_deleted.items) |name| {
            var staged_col = " ";
            for (staged_modified.items) |s| {
                if (std.mem.eql(u8, s, name)) staged_col = "M";
            }
            // Column two is padded like every other porcelain line.
            try io.print("{s} D {s}\n", .{ staged_col, name });
        }
        if (untracked_mode != .no) {
            for (untracked_list.items) |name| try io.print("?? {s}\n", .{name});
        }
        return;
    }

    // ── Summary line ──
    const n_staged = staged_added.items.len + staged_modified.items.len + staged_deleted.items.len;
    const n_unstaged = unstaged_modified.items.len + unstaged_deleted.items.len;
    const n_untracked = if (untracked_mode == .no) 0 else untracked_list.items.len;

    if (n_staged == 0 and n_unstaged == 0 and n_untracked == 0) {
        try io.print("\n  \x1b[1;32m✓\x1b[0m \x1b[2mWorking tree clean\x1b[0m\n", .{});
        return;
    }

    try io.print("\n", .{});

    // ── Staged changes ──
    if (n_staged > 0) {
        try io.print("  \x1b[1;32mStaged\x1b[0m  ", .{});
        try io.print("\x1b[2m({d} file{s})\x1b[0m\n", .{ n_staged, if (n_staged > 1) "s" else "" });
        for (staged_added.items) |name| {
            try io.print("    \x1b[32m+\x1b[0m \x1b[32m{s}\x1b[0m\n", .{name});
        }
        for (staged_modified.items) |name| {
            try io.print("    \x1b[33m~\x1b[0m \x1b[33m{s}\x1b[0m\n", .{name});
        }
        for (staged_deleted.items) |name| {
            try io.print("    \x1b[31m-\x1b[0m \x1b[31m{s}\x1b[0m\n", .{name});
        }
        try io.print("\n", .{});
    }

    // ── Unstaged changes ──
    if (n_unstaged > 0) {
        try io.print("  \x1b[1;33mModified\x1b[0m", .{});
        try io.print("  \x1b[2m({d} file{s})\x1b[0m\n", .{ n_unstaged, if (n_unstaged > 1) "s" else "" });
        for (unstaged_modified.items) |name| {
            try io.print("    \x1b[33m~\x1b[0m {s}\n", .{name});
        }
        for (unstaged_deleted.items) |name| {
            try io.print("    \x1b[31m-\x1b[0m \x1b[31m{s} (deleted)\x1b[0m\n", .{name});
        }
        try io.print("\n", .{});
    }

    // ── Untracked files ──
    if (n_untracked > 0) {
        try io.print("  \x1b[1;36mUntracked\x1b[0m", .{});
        try io.print(" \x1b[2m({d} file{s})\x1b[0m\n", .{ n_untracked, if (n_untracked > 1) "s" else "" });
        for (untracked_list.items) |name| {
            try io.print("    \x1b[2m?\x1b[0m {s}\n", .{name});
        }
        try io.print("\n", .{});
    }

    // ── Quick actions ──
    if (n_staged > 0) {
        try io.print("  \x1b[2mgitz commit -m \"...\"\x1b[0m\n", .{});
    }
    if (n_unstaged > 0 or n_untracked > 0) {
        try io.print("  \x1b[2mgitz add .\x1b[0m\n", .{});
    }
}

const WorkingFile = struct {
    path: []const u8,
    content: []const u8,
};

fn isUnstagedModified(list: []const []const u8, name: []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

fn findIndexEntry(idx: *const index_mod.Index, name: []const u8) ?index_mod.IndexEntry {
    for (idx.entries.items) |entry| {
        const clean = if (std.mem.startsWith(u8, entry.name, "./")) entry.name[2..] else entry.name;
        if (std.mem.eql(u8, clean, name)) return entry;
    }
    return null;
}

fn findWorkingFile(files: []const WorkingFile, name: []const u8) ?WorkingFile {
    for (files) |f| {
        const clean = if (std.mem.startsWith(u8, f.path, "./")) f.path[2..] else f.path;
        if (std.mem.eql(u8, clean, name)) return f;
    }
    return null;
}

fn readWithAlternates(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *const storage_mod.StorageBackend,
    alts: *const alternates_mod.Reader,
    sha: [20]u8,
) !object.GitObject {
    return store.read(allocator, io, sha) catch {
        return alts.readObject(allocator, io, sha);
    };
}

/// Recursively flatten tree into SHA map with full paths
fn flattenTreeSha(store: *const storage_mod.StorageBackend, alts: *const alternates_mod.Reader, allocator: std.mem.Allocator, io: std.Io, tree: object.Tree, prefix: []const u8, map: *std.StringHashMap([20]u8)) !void {
    for (tree.entries) |entry| {
        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        if (entry.mode == 0o040000) {
            const sub_obj = readWithAlternates(allocator, io, store, alts, entry.sha) catch {
                allocator.free(full_path);
                continue;
            };
            defer sub_obj.deinit(allocator);
            const sub_tree = switch (sub_obj) {
                .tree => |t| t,
                else => {
                    allocator.free(full_path);
                    continue;
                },
            };
            try flattenTreeSha(store, alts, allocator, io, sub_tree, full_path, map);
            allocator.free(full_path);
        } else {
            try map.put(full_path, entry.sha);
        }
    }
}

fn collectWorkingTree(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, files: *std.ArrayList(WorkingFile), ignore: *ignore_mod.IgnoreStack) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (true) {
        const entry = iter.next(io) catch break;
        const e = entry orelse break;

        const full_path = if (std.mem.eql(u8, dir_path, "."))
            try std.fmt.allocPrint(allocator, "{s}", .{e.name})
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, e.name });

        if (e.kind == .directory) {
            // Both repository directories are skipped. Walking a real `.git`
            // reported every object, ref and index file as untracked, so a
            // repository that also had a git clone listed hundreds of entries
            // that are not the user's work.
            if (ignore.isIgnored(full_path, true) or
                std.mem.eql(u8, e.name, ".gitz") or
                std.mem.eql(u8, e.name, ".git"))
            {
                allocator.free(full_path);
                continue;
            }
            try collectWorkingTree(allocator, io, full_path, files, ignore);
            allocator.free(full_path);
        } else if (e.kind == .file) {
            if (ignore.isIgnored(full_path, false)) {
                allocator.free(full_path);
                continue;
            }
            const content = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .unlimited) catch {
                allocator.free(full_path);
                continue;
            };
            try files.append(allocator, .{ .path = full_path, .content = content });
        } else {
            allocator.free(full_path);
        }
    }
}
