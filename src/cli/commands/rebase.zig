const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const loose = @import("../../core/loose.zig");
const object = @import("../../core/object.zig");
const refs_mod = @import("../../core/refs.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var abort_mode = false;
    var interactive = false;
    var continue_mode = false;
    var upstream: ?[]const u8 = null;
    var onto: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--abort")) {
            abort_mode = true;
        } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c")) {
            continue_mode = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, arg, "--onto") and i + 1 < args.len) {
            i += 1;
            onto = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (upstream == null) upstream = arg;
        }
    }

    if (abort_mode) {
        try abortRebase(allocator, git_dir, io);
        return;
    }
    if (continue_mode) {
        try io.print("No rebase in progress.\n", .{});
        return;
    }

    const branch = upstream orelse {
        try io.eprint("usage: gitz rebase [-i] [--abort] [--onto <base>] <upstream>\n", .{});
        std.process.exit(1);
    };

    const refs_manager = refs_mod.Refs.init(git_dir);
    const store = loose.LooseStore.init(git_dir);

    var head_info = refs_manager.head(allocator, io.io) catch {
        try io.eprint("fatal: not a gitz repository\n", .{});
        return;
    };
    defer head_info.deinit(allocator);

    const current_sha = switch (head_info) {
        .branch => |b| b.sha,
        .detached => |d| d.sha,
    };

    const upstream_sha = resolveRef(allocator, io.io, refs_manager, store, branch) catch {
        try io.eprint("error: branch '{s}' not found\n", .{branch});
        return;
    };

    const onto_sha = if (onto) |o|
        resolveRef(allocator, io.io, refs_manager, store, o) catch upstream_sha
    else
        upstream_sha;

    if (std.mem.eql(u8, &current_sha, &onto_sha)) {
        try io.print("Already up to date.\n", .{});
        return;
    }

    // Collect commits to replay
    var shas_to_replay = std.ArrayList([20]u8){ .items = &.{}, .capacity = 0 };
    defer shas_to_replay.deinit(allocator);
    var commits_to_replay = std.ArrayList(object.Commit){ .items = &.{}, .capacity = 0 };
    defer commits_to_replay.deinit(allocator);

    var cur = current_sha;
    while (true) {
        if (std.mem.eql(u8, &cur, &onto_sha)) break;
        const obj = store.read(allocator, io.io, cur) catch break;
        const commit = switch (obj) {
            .commit => |c| c,
            else => break,
        };
        const parents_copy = try allocator.alloc([20]u8, commit.parents.len);
        @memcpy(parents_copy, commit.parents);
        try shas_to_replay.append(allocator, cur);
        try commits_to_replay.append(allocator, .{
            .tree = commit.tree,
            .parents = parents_copy,
            .author = commit.author,
            .committer = commit.committer,
            .message = commit.message,
        });
        if (commit.parents.len == 0) break;
        cur = commit.parents[0];
    }

    if (commits_to_replay.items.len == 0) {
        try io.print("Nothing to do.\n", .{});
        return;
    }

    if (interactive) {
        try interactiveRebase(allocator, git_dir, io, &store, &refs_manager, &shas_to_replay, &commits_to_replay, onto_sha, &head_info);
        return;
    }

    try replayCommits(allocator, git_dir, io, &store, &refs_manager, &commits_to_replay, onto_sha, &head_info);
    try io.print("Successfully rebased and updated refs/heads/{s}.\n", .{switch (head_info) {
        .branch => |b| b.name.items,
        .detached => "(detached)",
    }});
}

fn replayCommits(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: Io,
    store: *const loose.LooseStore,
    refs_manager: *const refs_mod.Refs,
    commits: *std.ArrayList(object.Commit),
    new_base: [20]u8,
    head_info: *const refs_mod.HeadInfo,
) !void {
    var current_parent = new_base;
    var i: usize = commits.items.len;
    while (i > 0) {
        i -= 1;
        const commit = commits.items[i];
        var parents_buf: [1][20]u8 = .{current_parent};
        const parents = parents_buf[0..1];
        const now_ts = std.Io.Timestamp.now(io.io, .real);
        const now: i64 = @intCast(@divTrunc(now_ts.nanoseconds, std.time.ns_per_s));
        const new_commit = object.Commit{
            .tree = commit.tree,
            .parents = parents,
            .author = commit.author,
            .committer = .{ .name = "GitZ User", .email = "user@gitz.dev", .timestamp = now, .timezone = "+0000" },
            .message = commit.message,
        };
        current_parent = try store.write(allocator, io.io, object.GitObject{ .commit = new_commit });
    }

    switch (head_info.*) {
        .branch => |b| {
            const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{b.name.items});
            defer allocator.free(ref_name);
            try refs_manager.write(allocator, io.io, ref_name, current_parent);
        },
        .detached => {
            const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
            defer allocator.free(head_path);
            var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
            defer hf.close(io.io);
            const hex = Sha1.hex(current_parent);
            var wbuf: [42]u8 = undefined;
            const wline = try std.fmt.bufPrint(&wbuf, "{s}\n", .{&hex});
            try std.Io.File.writeStreamingAll(hf, io.io, wline);
        },
    }
}

/// Interactive rebase TUI with arrow key navigation
fn interactiveRebase(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: Io,
    store: *const loose.LooseStore,
    refs_manager: *const refs_mod.Refs,
    shas: *std.ArrayList([20]u8),
    commits: *std.ArrayList(object.Commit),
    onto: [20]u8,
    head_info: *const refs_mod.HeadInfo,
) !void {
    const Action = enum { pick, squash, reword, edit, drop };

    const n = commits.items.len;
    var actions = try allocator.alloc(Action, n);
    defer allocator.free(actions);
    for (actions) |*a| a.* = .pick;

    // Clear screen
    try io.print("\x1b[2J\x1b[H", .{});
    try io.print("\x1b[1;36m=== Interactive Rebase ===\x1b[0m onto \x1b[1;33m{s}\x1b[0m\n\n", .{Sha1.hex(onto)[0..7]});
    try io.print("\x1b[2m[p]ick  [s]quash  [r]eword  [e]dit  [d]rop | [j/k] nav | [Enter] confirm | [q] abort\x1b[0m\n\n", .{});

    var cursor: usize = 0;

    // Main loop
    while (true) {
        // Move cursor to list area and redraw
        try io.print("\x1b[5;1H", .{});

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const display_idx = n - 1 - i; // newest first
            const commit = commits.items[display_idx];
            const sha = shas.items[display_idx];
            const hex = Sha1.hex(sha);
            var msg_lines = std.mem.splitScalar(u8, commit.message, '\n');
            const first_line = msg_lines.next() orelse "";

            const action_str = switch (actions[display_idx]) {
                .pick => "pick   ",
                .squash => "squash ",
                .reword => "reword ",
                .edit => "edit   ",
                .drop => "drop   ",
            };

            // Cursor indicator + colored action
            if (display_idx == cursor) {
                try io.print("\x1b[1;7m> {s}\x1b[0m {s} {s}\x1b[0m\n", .{ action_str, hex[0..7], first_line });
            } else {
                try io.print("  {s} {s} {s}\n", .{ action_str, hex[0..7], first_line });
            }
        }

        // Read one byte from stdin
        var stdin = std.Io.File.stdin();
        var input_buf: [1]u8 = undefined;
        const n_read = stdin.readStreaming(io.io, &.{&input_buf}) catch 0;
        if (n_read == 0) break;

        const c = input_buf[0];
        if (c == 'q' or c == 0x1b) {
            try io.print("\x1b[2J\x1b[H", .{});
            try io.print("Rebase aborted.\n", .{});
            return;
        }
        if (c == '\n' or c == '\r') break;
        if (c == 'j' or c == 'B') { // down
            if (cursor > 0) cursor -= 1;
        } else if (c == 'k' or c == 'A') { // up
            if (cursor < n - 1) cursor += 1;
        } else {
            actions[cursor] = switch (c) {
                'p' => .pick,
                's' => .squash,
                'r' => .reword,
                'e' => .edit,
                'd' => .drop,
                else => actions[cursor],
            };
        }
    }

    try io.print("\x1b[2J\x1b[H", .{});

    // Execute rebase based on actions (oldest first = index n-1 down to 0)
    var current_parent = onto;
    var rebased: u32 = 0;
    var dropped: u32 = 0;

    var ri: usize = n;
    while (ri > 0) {
        ri -= 1;
        const action = actions[ri];
        const commit = commits.items[ri];

        if (action == .drop) {
            dropped += 1;
            continue;
        }

        var parents_buf: [1][20]u8 = .{current_parent};
        const parents = parents_buf[0..1];
        const now_ts = std.Io.Timestamp.now(io.io, .real);
        const now: i64 = @intCast(@divTrunc(now_ts.nanoseconds, std.time.ns_per_s));

        const new_commit = object.Commit{
            .tree = commit.tree,
            .parents = parents,
            .author = commit.author,
            .committer = .{ .name = "GitZ User", .email = "user@gitz.dev", .timestamp = now, .timezone = "+0000" },
            .message = commit.message,
        };
        current_parent = try store.write(allocator, io.io, object.GitObject{ .commit = new_commit });
        rebased += 1;
    }

    switch (head_info.*) {
        .branch => |b| {
            const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{b.name.items});
            defer allocator.free(ref_name);
            try refs_manager.write(allocator, io.io, ref_name, current_parent);
        },
        .detached => {
            const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
            defer allocator.free(head_path);
            var hf = try std.Io.Dir.cwd().createFile(io.io, head_path, .{});
            defer hf.close(io.io);
            const hex = Sha1.hex(current_parent);
            var wbuf: [42]u8 = undefined;
            const wline = try std.fmt.bufPrint(&wbuf, "{s}\n", .{&hex});
            try std.Io.File.writeStreamingAll(hf, io.io, wline);
        },
    }

    try io.print("Successfully rebased ({d} rebased, {d} dropped).\n", .{ rebased, dropped });
}

fn abortRebase(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) !void {
    const rebase_merge = try std.fmt.allocPrint(allocator, "{s}/rebase-merge", .{git_dir});
    defer allocator.free(rebase_merge);
    const rebase_apply = try std.fmt.allocPrint(allocator, "{s}/rebase-apply", .{git_dir});
    defer allocator.free(rebase_apply);

    const has_merge = if (std.Io.Dir.cwd().access(io.io, rebase_merge, .{})) |_| true else |_| false;
    const has_apply = if (std.Io.Dir.cwd().access(io.io, rebase_apply, .{})) |_| true else |_| false;

    if (!has_merge and !has_apply) {
        try io.eprint("fatal: No rebase in progress?\n", .{});
        return;
    }

    std.Io.Dir.cwd().deleteTree(io.io, rebase_merge) catch {};
    std.Io.Dir.cwd().deleteTree(io.io, rebase_apply) catch {};
    try io.print("Successfully aborted.\n", .{});
}

fn resolveRef(
    allocator: std.mem.Allocator,
    io: std.Io,
    refs_manager: refs_mod.Refs,
    store: loose.LooseStore,
    ref: []const u8,
) ![20]u8 {
    const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{ref});
    defer allocator.free(branch_ref);
    if (refs_manager.read(allocator, io, branch_ref)) |sha| return sha else |_| {}

    const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{ref});
    defer allocator.free(tag_ref);
    if (refs_manager.read(allocator, io, tag_ref)) |sha| return sha else |_| {}

    if (refs_manager.read(allocator, io, ref)) |sha| return sha else |_| {}
    if (Sha1.fromHex(ref)) |sha| return sha else |_| {}

    if (std.mem.startsWith(u8, ref, "HEAD~")) {
        const count = std.fmt.parseInt(usize, ref[5..], 10) catch 1;
        var cur = try refs_manager.read(allocator, io, "HEAD");
        for (0..count) |_| {
            const obj = store.read(allocator, io, cur) catch break;
            const c = switch (obj) {
                .commit => |cc| cc,
                else => break,
            };
            if (c.parents.len == 0) break;
            cur = c.parents[0];
        }
        return cur;
    }

    return error.InvalidRef;
}
