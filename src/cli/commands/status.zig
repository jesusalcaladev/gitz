const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const refs = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const index_mod = @import("../../core/index.zig");
const ignore_mod = @import("../../core/ignore.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    _ = args;
    const refs_manager = refs.Refs.init(git_dir);

    var head_info = refs_manager.head(allocator, io.io) catch {
        try io.print("\x1b[1;33m⚠\x1b[0m \x1b[1mNo commits yet\x1b[0m\n", .{});
        return;
    };
    defer head_info.deinit(allocator);

    // ── Branch header ──
    switch (head_info) {
        .branch => |b| {
            try io.print("\x1b[1;36m●\x1b[0m On branch \x1b[1;33m{s}\x1b[0m\n", .{b.name.items});
        },
        .detached => |d| {
            const hex = Sha1.hex(d.sha);
            try io.print("\x1b[1;31m●\x1b[0m HEAD detached at \x1b[1;33m{s}\x1b[0m\n", .{hex[0..7]});
        },
    }

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

    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch null;
    if (head_sha) |sha| {
        const commit_obj = store.read(allocator, io.io, sha) catch null;
        if (commit_obj) |obj| {
            const commit = switch (obj) {
                .commit => |c| c,
                else => null,
            };
            if (commit) |c| {
                const tree_obj = store.read(allocator, io.io, c.tree) catch null;
                if (tree_obj) |tobj| {
                    const tree = switch (tobj) {
                        .tree => |t| t,
                        else => null,
                    };
                    if (tree) |t| {
                        try flattenTreeSha(store, allocator, io.io, t, "", &head_shas);
                    }
                }
            }
        }
    }

    var ignore_stack = ignore_mod.IgnoreStack.init(allocator);
    defer ignore_stack.deinit();
    ignore_stack.loadFile(io.io, ".gitignore") catch {};

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
    var untracked = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer untracked.deinit(allocator);

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
            const base_sha = head_shas.get(clean_name) orelse continue;

            const header = std.fmt.allocPrint(allocator, "blob {d}\x00", .{wf.content.len}) catch continue;
            defer allocator.free(header);
            const full = try std.mem.concat(allocator, u8, &.{ header, wf.content });
            defer allocator.free(full);
            const work_sha = Sha1.hash(full);
            if (!std.mem.eql(u8, &work_sha, &base_sha)) {
                var already_staged = false;
                for (staged_modified.items) |s| {
                    if (std.mem.eql(u8, s, clean_name)) {
                        already_staged = true;
                        break;
                    }
                }
                for (staged_added.items) |s| {
                    if (std.mem.eql(u8, s, clean_name)) {
                        already_staged = true;
                        break;
                    }
                }
                if (!already_staged) {
                    try unstaged_modified.append(allocator, clean_name);
                }
            }
        } else {
            try untracked.append(allocator, clean_name);
        }
    }

    // Check for deleted tracked files not in working tree
    var ht_iter = head_shas.iterator();
    while (ht_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (tracked_names.get(name) != null) continue;
        const in_working = findWorkingFile(working_files.items, name) != null;
        if (!in_working) {
            try unstaged_deleted.append(allocator, name);
        }
    }

    // ── Summary line ──
    const n_staged = staged_added.items.len + staged_modified.items.len + staged_deleted.items.len;
    const n_unstaged = unstaged_modified.items.len + unstaged_deleted.items.len;
    const n_untracked = untracked.items.len;

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
        for (untracked.items) |name| {
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

/// Recursively flatten tree into SHA map with full paths
fn flattenTreeSha(store: storage_mod.StorageBackend, allocator: std.mem.Allocator, io: std.Io, tree: object.Tree, prefix: []const u8, map: *std.StringHashMap([20]u8)) !void {
    for (tree.entries) |entry| {
        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        if (entry.mode == 0o040000) {
            const sub_obj = store.read(allocator, io, entry.sha) catch {
                allocator.free(full_path);
                continue;
            };
            const sub_tree = switch (sub_obj) {
                .tree => |t| t,
                else => {
                    allocator.free(full_path);
                    continue;
                },
            };
            try flattenTreeSha(store, allocator, io, sub_tree, full_path, map);
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
            if (ignore.isIgnored(full_path, true) or std.mem.eql(u8, e.name, ".gitz")) {
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
