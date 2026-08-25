const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const refs_mod = @import("../../core/refs.zig");
const http = @import("../../transport/http.zig");
const remote_cmd = @import("remote.zig");
const ui = @import("../../util/ui.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var remote_name: ?[]const u8 = null;
    var refspec: ?[]const u8 = null;

    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            if (remote_name == null) {
                remote_name = arg;
            } else {
                refspec = arg;
            }
        }
    }

    const name = remote_name orelse "origin";

    // Get remote URL from config
    const url = remote_cmd.getRemoteUrl(allocator, git_dir, name, io);
    defer if (url) |u| allocator.free(u);

    if (url == null) {
        try io.eprint("fatal: '{s}' does not appear to be a git repository\n", .{name});
        try io.eprint("fatal: could not read from remote repository.\n\n", .{});
        try io.eprint("Please make sure you have the correct access rights\n", .{});
        try io.eprint("and the repository exists.\n", .{});
        return;
    }

    try io.print("{s}{s}Fetching{s} {s}{s}\n", .{ ui.c.bold, ui.c.bcyan, ui.c.reset, ui.c.bold, name });

    var transport = try http.HttpTransport.init(allocator, io.io, url.?);
    defer transport.deinit();

    // Discover remote refs
    const refs = try transport.discoverRefs();
    defer {
        for (refs) |r| allocator.free(r.name);
        allocator.free(refs);
    }

    // Get local HEAD for have lines
    const refs_manager = refs_mod.Refs.init(git_dir);
    const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch null;

    var have_list: [1][20]u8 = undefined;
    var have_slice: []const [20]u8 = &.{};
    if (head_sha) |sha| {
        have_list[0] = sha;
        have_slice = &have_list;
    }

    // Filter by refspec if provided
    var filtered_refs = refs;
    if (refspec) |spec| {
        var temp = std.ArrayList(http.RemoteRef){ .items = &.{}, .capacity = 0 };
        for (refs) |ref| {
            if (std.mem.startsWith(u8, ref.name, spec)) {
                try temp.append(allocator, ref);
            }
        }
        filtered_refs = try temp.toOwnedSlice(allocator);
    }

    try transport.fetch(git_dir, filtered_refs, have_slice);

    // Update remote-tracking branches
    for (refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ name, ref.name[11..] });
            defer allocator.free(remote_ref);

            // Ensure directory exists
            const dir_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}", .{ git_dir, name });
            defer allocator.free(dir_path);
            std.Io.Dir.cwd().createDirPath(io.io, dir_path) catch {};

            try refs_manager.write(allocator, io.io, remote_ref, ref.sha);
        }
    }

    // Update HEAD if fetching the current branch
    var head_info = refs_manager.head(allocator, io.io) catch null;
    defer if (head_info) |*h| h.deinit(allocator);

    if (head_info) |hi| {
        switch (hi) {
            .branch => |b| {
                const current_branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{b.name.items});
                defer allocator.free(current_branch_ref);

            },
            .detached => {},
        }
    }

    try io.print("{s}From {s}{s}\n", .{ ui.c.dim, url.?, ui.c.reset });
    for (refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            const branch_name = ref.name[11..];
            const hex = Sha1.hex(ref.sha);
            try io.print("   {s}{s}{s} {s}{s} -> {s}/{s}\n", .{
                ui.c.yellow,
                hex[0..7],
                ui.c.reset,
                ui.sym.arrow,
                branch_name,
                name,
                branch_name,
            });
        }
    }
}
