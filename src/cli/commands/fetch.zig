const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const refs_mod = @import("../../core/refs.zig");
const http = @import("../../transport/http.zig");
const ssh_cmd = @import("../../transport/ssh_cmd.zig");
const ssh_mod = @import("../../transport/ssh.zig");
const remote_cmd = @import("remote.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var remote_name: ?[]const u8 = null;
    var refspec: ?[]const u8 = null;
    var use_git = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--git") or std.mem.eql(u8, arg, "-g")) {
            use_git = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (remote_name == null) {
                remote_name = arg;
            } else {
                refspec = arg;
            }
        }
    }

    const name = remote_name orelse "origin";

    // Force git fallback if requested
    if (use_git) {
        try fetchViaGit(allocator, git_dir, name, io);
        return;
    }

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

    try io.print("Fetching {s}\n", .{name});

    // Try appropriate transport based on URL
    const is_ssh = ssh_mod.isSshUrl(url.?);

    if (is_ssh) {
        // Use SSH transport
        var ssh_transport = ssh_cmd.SshTransport.init(allocator, io.io, url.?) catch {
            try io.print("Note: SSH transport failed, falling back to git\n", .{});
            try fetchViaGit(allocator, git_dir, name, io);
            return;
        };
        defer ssh_transport.deinit();

        // Get local HEAD for have lines
        const refs_manager = refs_mod.Refs.init(git_dir);
        const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch null;

        var have_list: [1][20]u8 = undefined;
        var have_slice: []const [20]u8 = &.{};
        if (head_sha) |sha| {
            have_list[0] = sha;
            have_slice = &have_list;
        }

        // Discover and fetch refs
        const refs = ssh_transport.discoverRefs() catch {
            try io.print("Note: SSH discover failed, falling back to git\n", .{});
            try fetchViaGit(allocator, git_dir, name, io);
            return;
        };
        defer {
            for (refs) |r| allocator.free(r.name);
            allocator.free(refs);
        }

        ssh_transport.fetch(git_dir, refs, have_slice) catch {
            try io.print("Note: SSH fetch failed, falling back to git\n", .{});
            try fetchViaGit(allocator, git_dir, name, io);
            return;
        };

        // Update remote-tracking branches
        for (refs) |ref| {
            if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
                const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ name, ref.name[11..] });
                defer allocator.free(remote_ref);
                const dir_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}", .{ git_dir, name });
                defer allocator.free(dir_path);
                std.Io.Dir.cwd().createDirPath(io.io, dir_path) catch {};
                try refs_manager.write(allocator, io.io, remote_ref, ref.sha);
            }
        }

        try io.print("From {s}\n", .{url.?});
        for (refs) |ref| {
            if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
                const branch_name = ref.name[11..];
                const hex = Sha1.hex(ref.sha);
                try io.print(" * branch              {s} -> {s}\n", .{ hex[0..7], branch_name });
            }
        }
    } else {
        // Use HTTP transport
        var transport = http.HttpTransport.init(allocator, io.io, url.?) catch {
            try io.print("Note: HTTP transport failed, falling back to git\n", .{});
            try fetchViaGit(allocator, git_dir, name, io);
            return;
        };
        defer transport.deinit();

        const refs = transport.discoverRefs() catch {
            try io.print("Note: HTTP discover failed, falling back to git\n", .{});
            try fetchViaGit(allocator, git_dir, name, io);
            return;
        };
        defer {
            for (refs) |r| allocator.free(r.name);
            allocator.free(refs);
        }

        const refs_manager = refs_mod.Refs.init(git_dir);
        const head_sha = refs_manager.read(allocator, io.io, "HEAD") catch null;

        var have_list: [1][20]u8 = undefined;
        var have_slice: []const [20]u8 = &.{};
        if (head_sha) |sha| {
            have_list[0] = sha;
            have_slice = &have_list;
        }

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

        transport.fetch(git_dir, filtered_refs, have_slice) catch {
            try io.print("Note: HTTP fetch failed, falling back to git\n", .{});
            try fetchViaGit(allocator, git_dir, name, io);
            return;
        };

        for (refs) |ref| {
            if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
                const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ name, ref.name[11..] });
                defer allocator.free(remote_ref);
                const dir_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}", .{ git_dir, name });
                defer allocator.free(dir_path);
                std.Io.Dir.cwd().createDirPath(io.io, dir_path) catch {};
                try refs_manager.write(allocator, io.io, remote_ref, ref.sha);
            }
        }

        try io.print("From {s}\n", .{url.?});
        for (refs) |ref| {
            if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
                const branch_name = ref.name[11..];
                const hex = Sha1.hex(ref.sha);
                try io.print(" * branch              {s} -> {s}\n", .{ hex[0..7], branch_name });
            }
        }
    }
}

/// Fetch using system git as fallback
fn fetchViaGit(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    remote_name: []const u8,
    io: Io,
) !void {
    var git_cmd = std.ArrayList(u8).empty;
    defer git_cmd.deinit(allocator);
    try git_cmd.appendSlice(allocator, "GIT_DIR=");
    try git_cmd.appendSlice(allocator, git_dir);
    try git_cmd.appendSlice(allocator, " GIT_INDEX_FILE=/dev/null git fetch ");
    try git_cmd.appendSlice(allocator, remote_name);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "sh");
    try argv.append(allocator, "-c");
    try argv.append(allocator, git_cmd.items);

    const result = std.process.run(allocator, io.io, .{
        .argv = argv.items,
    }) catch |err| {
        try io.eprint("error: git fetch failed: {}\n", .{err});
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stdout.len > 0) {
        try io.print("{s}", .{result.stdout});
    }
    if (result.stderr.len > 0) {
        try io.eprint("{s}", .{result.stderr});
    }
}
