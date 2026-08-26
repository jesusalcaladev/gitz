const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const refs = @import("../../core/refs.zig");
const storage_mod = @import("../../core/storage.zig");
const object = @import("../../core/object.zig");
const index_mod = @import("../../core/index.zig");
const ignore_mod = @import("../../core/ignore.zig");
const ui = @import("../../util/ui.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    _ = args;
    const refs_manager = refs.Refs.init(git_dir);

    var head_info = refs_manager.head(allocator, io.io) catch {
        try io.print("No commits yet\n", .{});
        return;
    };
    defer head_info.deinit(allocator);

    switch (head_info) {
        .branch => |b| {
            try io.print("{s}On branch {s}{s}{s}\n", .{ ui.c.bold, ui.c.bcyan, b.name.items, ui.c.reset });
        },
        .detached => |d| {
            const hex = Sha1.hex(d.sha);
            try io.print("{s}HEAD detached at {s}{s}{s}\n", .{ ui.c.dim, ui.c.yellow, hex[0..7], ui.c.reset });
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
            // File is tracked — compare working tree vs HEAD tree SHA
            const base_sha = head_shas.get(clean_name) orelse continue;

            const header = std.fmt.allocPrint(allocator, "blob {d}\x00", .{wf.content.len}) catch continue;
            defer allocator.free(header);
            const full = try std.mem.concat(allocator, u8, &.{ header, wf.content });
            defer allocator.free(full);
            const work_sha = Sha1.hash(full);
            if (!std.mem.eql(u8, &work_sha, &base_sha)) {
                var already_staged = false;
                for (staged_modified.items) |s| {
                    if (std.mem.eql(u8, s, clean_name)) { already_staged = true; break; }
                }
                for (staged_added.items) |s| {
                    if (std.mem.eql(u8, s, clean_name)) { already_staged = true; break; }
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

    const has_staged = staged_added.items.len > 0 or staged_modified.items.len > 0 or staged_deleted.items.len > 0;
    const has_unstaged = unstaged_modified.items.len > 0 or unstaged_deleted.items.len > 0;

    if (!has_staged and !has_unstaged and untracked.items.len == 0) {
        try io.print("{s}{s}nothing to commit, working tree clean{s}\n", .{ ui.c.bgreen, ui.c.reset, ui.c.reset });
        return;
    }

    if (has_staged) {
        try io.print("{s}{s}Changes to be committed:{s}\n", .{ ui.c.bold, ui.c.green, ui.c.reset });
        try io.print("  {s}(use \"gitz restore --staged <file>...\" to unstage){s}\n", .{ ui.c.dim, ui.c.reset });
        for (staged_added.items) |name| {
            try io.print("\t{s}new file:   {s}{s}{s}\n", .{ ui.c.green, ui.c.bold, name, ui.c.reset });
        }
        for (staged_modified.items) |name| {
            try io.print("\t{s}modified:   {s}{s}{s}\n", .{ ui.c.green, ui.c.bold, name, ui.c.reset });
        }
        for (staged_deleted.items) |name| {
            try io.print("\t{s}deleted:    {s}{s}{s}\n", .{ ui.c.red, ui.c.bold, name, ui.c.reset });
        }
        try io.print("\n", .{});
    }

    if (has_unstaged) {
        try io.print("{s}{s}Changes not staged for commit:{s}\n", .{ ui.c.bold, ui.c.yellow, ui.c.reset });
        try io.print("  {s}(use \"gitz add <file>...\" to update what will be committed){s}\n", .{ ui.c.dim, ui.c.reset });
        for (unstaged_modified.items) |name| {
            try io.print("\t{s}modified:   {s}{s}{s}\n", .{ ui.c.yellow, ui.c.bold, name, ui.c.reset });
        }
        for (unstaged_deleted.items) |name| {
            try io.print("\t{s}deleted:    {s}{s}{s}\n", .{ ui.c.red, ui.c.bold, name, ui.c.reset });
        }
        try io.print("\n", .{});
    }

    if (untracked.items.len > 0) {
        try io.print("{s}{s}Untracked files:{s}\n", .{ ui.c.bold, ui.c.red, ui.c.reset });
        try io.print("  {s}(use \"gitz add <file>...\" to include in what will be committed){s}\n", .{ ui.c.dim, ui.c.reset });
        for (untracked.items) |name| {
            try io.print("\t{s}{s}{s}\n", .{ ui.c.red, name, ui.c.reset });
        }
        try io.print("\n", .{});
    }

    // Summary line
    var summary_parts = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer summary_parts.deinit(allocator);

    if (staged_added.items.len + staged_modified.items.len + staged_deleted.items.len > 0) {
        const part = try std.fmt.allocPrint(allocator, "{s}{s}{s}staged{s}", .{
            ui.c.green,
            if (staged_added.items.len + staged_modified.items.len + staged_deleted.items.len > 0) ui.sym.ok else "",
            ui.c.reset, ui.c.reset,
        });
        try summary_parts.append(allocator, part);
    }
    if (unstaged_modified.items.len + unstaged_deleted.items.len > 0) {
        const part = try std.fmt.allocPrint(allocator, "{s}{s}{s}unstaged{s}", .{
            ui.c.yellow,
            if (unstaged_modified.items.len + unstaged_deleted.items.len > 0) ui.sym.warn else "",
            ui.c.reset, ui.c.reset,
        });
        try summary_parts.append(allocator, part);
    }
    if (untracked.items.len > 0) {
        const part = try std.fmt.allocPrint(allocator, "{s}{d}{s} untracked", .{
            ui.c.red, untracked.items.len, ui.c.reset,
        });
        try summary_parts.append(allocator, part);
    }

    if (summary_parts.items.len > 0) {
        try io.print("{s}{s}{s}", .{ ui.c.dim, ui.sym.arrow, ui.c.reset });
        for (summary_parts.items, 0..) |part, idx2| {
            if (idx2 > 0) {
                try io.print("{s} · {s}", .{ ui.c.dim, ui.c.reset });
            }
            try io.print("{s}", .{part});
        }
        try io.print("\n", .{});
    }

    // Free summary parts
    for (summary_parts.items) |part| {
        allocator.free(part);
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
