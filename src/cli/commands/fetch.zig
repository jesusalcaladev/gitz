const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const refs_mod = @import("../../core/refs.zig");
const http = @import("../../transport/http.zig");
const ssh_cmd = @import("../../transport/ssh_cmd.zig");
const ssh_mod = @import("../../transport/ssh.zig");
const remote_cmd = @import("remote.zig");
const errors = @import("../errors.zig");
const Repo = @import("../../core/repo.zig").Repo;

pub fn execute(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    // For a repository with no worktrees the three directories coincide, so
    // the existing path building below is unchanged. A linked worktree gets
    // the right directory per role from `repo`.
    const git_dir = repo.worktree_dir;
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
        errors.fatal(io, "'{s}' does not appear to be a git repository", .{name});
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
        const refs_manager = refs_mod.Refs.init(repo);
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

        ssh_transport.fetch(repo, refs, have_slice) catch {
            try io.print("Note: SSH fetch failed, falling back to git\n", .{});
            try fetchViaGit(allocator, git_dir, name, io);
            return;
        };

        // Update remote-tracking branches
        for (refs) |ref| {
            if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
                const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ name, ref.name[11..] });
                defer allocator.free(remote_ref);
                const dir_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}", .{ repo.common_dir, name });
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

        const refs_manager = refs_mod.Refs.init(repo);
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

        transport.fetch(repo, filtered_refs, have_slice) catch {
            try io.print("Note: HTTP fetch failed, falling back to git\n", .{});
            try fetchViaGit(allocator, git_dir, name, io);
            return;
        };

        for (refs) |ref| {
            if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
                const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ name, ref.name[11..] });
                defer allocator.free(remote_ref);
                const dir_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}", .{ repo.common_dir, name });
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

/// Fetch using system git as fallback.
///
/// Like the push fallback, this used to build an `sh -c` string out of the
/// remote name, so a crafted remote executed arbitrary commands. The
/// environment is now passed as a map and git is invoked with a plain argv.
fn fetchViaGit(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    remote_name: []const u8,
    io: Io,
) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "fetch");
    try argv.append(allocator, remote_name);

    // git must not read gitz's index while it negotiates over the native
    // protocol. `/dev/null` was used, but git parses that file and aborts with
    // "index file smaller than expected", so every fallback to git failed. A
    // path that does not exist is an empty index as far as git is concerned.
    const null_index = try std.fmt.allocPrint(allocator, "{s}/gitz-null-index", .{git_dir});
    defer allocator.free(null_index);

    var env = try io.childEnviron(allocator, &.{
        .{ "GIT_DIR", git_dir },
        .{ "GIT_INDEX_FILE", null_index },
    });
    defer env.deinit();

    const result = std.process.run(allocator, io.io, .{
        .argv = argv.items,
        .environ_map = &env,
    }) catch |err| {
        errors.fatal(io, "git fetch failed: {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stdout.len > 0) {
        try io.print("{s}", .{result.stdout});
    }
    if (result.stderr.len > 0) {
        try io.eprint("{s}", .{result.stderr});
    }

    // A failed fetch used to be indistinguishable from a successful one, so
    // `gitz pull` went on to rebase against nothing and `gitz sync` printed
    // "Sync complete!".
    const exited: u8 = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };
    if (exited != 0) std.process.exit(exited);
}
