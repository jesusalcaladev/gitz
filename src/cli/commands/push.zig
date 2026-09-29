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
    var force = false;
    var use_git = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--git") or std.mem.eql(u8, arg, "-g")) {
            use_git = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (remote_name == null) {
                remote_name = arg;
            } else if (refspec == null) {
                refspec = arg;
            }
        }
    }

    const name = remote_name orelse "origin";
    const ref = refspec orelse refspec: {
        // Get current branch name
        const refs_manager = refs_mod.Refs.init(repo);
        var head_info = refs_manager.head(allocator, io.io) catch {
            errors.fatal(io, "not a gitz repository", .{});
        };
        defer head_info.deinit(allocator);
        break :refspec switch (head_info) {
            .branch => |b| try allocator.dupe(u8, b.name.items),
            .unborn => |u| try allocator.dupe(u8, u.name.items),
            .detached => {
                errors.fatal(io, "not on a branch", .{});
            },
        };
    };
    defer if (refspec == null) allocator.free(ref);

    // Get remote URL
    const url = remote_cmd.getRemoteUrl(allocator, git_dir, name, io);
    defer if (url) |u| allocator.free(u);

    if (url == null) {
        errors.fatal(io, "'{s}' does not appear to be a git repository", .{name});
    }

    // Get the commit SHA to push
    const refs_manager = refs_mod.Refs.init(repo);
    const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{ref});
    defer allocator.free(ref_name);

    const push_sha = refs_manager.read(allocator, io.io, ref_name) catch {
        errors.errorf(io, "src refspec '{s}' does not match any", .{ref});
    };

    // Force git fallback if requested
    if (use_git) {
        try pushViaGit(allocator, git_dir, name, ref, force, io);
        return;
    }

    // The remote's previous value for the ref, so the summary can show the real
    // old and new instead of the new one twice.
    var pushed_old: ?[20]u8 = null;

    // Try appropriate transport based on URL
    const is_ssh = ssh_mod.isSshUrl(url.?);

    if (is_ssh) {
        // Use SSH transport
        var ssh_transport = ssh_cmd.SshTransport.init(allocator, io.io, url.?) catch {
            try io.print("Note: SSH transport failed, falling back to git\n", .{});
            try pushViaGit(allocator, git_dir, name, ref, force, io);
            return;
        };
        defer ssh_transport.deinit();

        // Discover remote SHA for the ref
        var old_sha: ?[20]u8 = null;
        const remote_refs = ssh_transport.discoverRefs() catch &.{};
        defer {
            for (remote_refs) |r| allocator.free(r.name);
            allocator.free(remote_refs);
        }
        const full_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{ref});
        defer allocator.free(full_ref);
        for (remote_refs) |r| {
            if (std.mem.eql(u8, r.name, full_ref)) {
                old_sha = r.sha;
                break;
            }
        }

        // A transport failure is retried through real git, but a transport that
        // *succeeded* and was told by the server that the ref was rejected is a
        // rejection, not a failure to try harder. Falling back there is what
        // made `gitz push` report success for a push that never happened.
        const pushed = ssh_transport.push(repo, ref, push_sha, old_sha);
        if (pushed) |_| {
            pushed_old = old_sha;
        } else |err| {
            if (err != error.PushRejected) {
                try io.print("Note: SSH push failed ({s}), falling back to git\n", .{@errorName(err)});
                try pushViaGit(allocator, git_dir, name, ref, force, io);
                return reportSuccess(io, url.?, old_sha, push_sha, ref);
            }
            // The server said no. Printing "To <url>" after that is a lie.
            try io.eprint("error: push rejected by {s}\n", .{url.?});
            std.process.exit(errors.ExitFailure);
        }
    } else {
        // Use HTTP transport
        var transport = http.HttpTransport.init(allocator, io.io, url.?) catch {
            try io.print("Note: HTTP transport failed, falling back to git\n", .{});
            try pushViaGit(allocator, git_dir, name, ref, force, io);
            return;
        };
        defer transport.deinit();

        const pushed = transport.push(repo, ref, push_sha);
        if (pushed) |_| {
            pushed_old = null;
        } else |err| {
            if (err != error.PushRejected) {
                try io.print("Note: HTTP push failed ({s}), falling back to git\n", .{@errorName(err)});
                try pushViaGit(allocator, git_dir, name, ref, force, io);
                return reportSuccess(io, url.?, null, push_sha, ref);
            }
            try io.eprint("error: push rejected by {s}\n", .{url.?});
            std.process.exit(errors.ExitFailure);
        }
    }

    try reportSuccess(io, url.?, pushed_old, push_sha, ref);
}

/// Report the ref update the way git does, with the real old and new values.
///
/// The old line printed `hex..hex` -- the same SHA on both sides -- because it
/// reused the new SHA for the old one, so a force-push and a normal push looked
/// identical.
fn reportSuccess(io: Io, url: []const u8, old_sha: ?[20]u8, new_sha: [20]u8, ref: []const u8) !void {
    const new_hex = Sha1.hex(new_sha);
    const old_hex: [40]u8 = if (old_sha) |o| Sha1.hex(o) else ([_]u8{'0'} ** 40);

    try io.print("To {s}\n", .{url});
    try io.print("   {s}..{s}  {s} -> {s}\n", .{ old_hex[0..7], new_hex[0..7], ref, ref });
}

/// Push using system git as fallback.
///
/// The remote name and ref come straight from argv. Assembling a shell string
/// out of them and running `sh -c` meant `gitz push 'origin; id' --git` (or any
/// transport failure that triggers the automatic fallback) executed arbitrary
/// commands. The environment is now passed through `std.process.run`'s `env_map`
/// and the command runs as a plain argv, with no shell involved.
fn pushViaGit(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    remote_name: []const u8,
    ref: []const u8,
    force: bool,
    io: Io,
) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "push");
    if (force) try argv.append(allocator, "--force-with-lease");
    try argv.append(allocator, remote_name);
    try argv.append(allocator, ref);

    // GIT_INDEX_FILE=/dev/null keeps git from reading gitz's index while it
    // negotiates over the native protocol.
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
        errors.fatal(io, "git push failed: {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stdout.len > 0) {
        try io.print("{s}", .{result.stdout});
    }
    if (result.stderr.len > 0) {
        try io.eprint("{s}", .{result.stderr});
    }

    const exited: u8 = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };
    // Propagate the failure. Returning here reported success for a rejected or
    // unreachable push, so any CI job gating on `gitz push` was green.
    if (exited != 0) {
        std.process.exit(if (exited == 0) 1 else exited);
    }
}
