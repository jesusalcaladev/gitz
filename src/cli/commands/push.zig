const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const refs_mod = @import("../../core/refs.zig");
const http = @import("../../transport/http.zig");
const ssh_cmd = @import("../../transport/ssh_cmd.zig");
const ssh_mod = @import("../../transport/ssh.zig");
const remote_cmd = @import("remote.zig");
const errors = @import("../errors.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
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
        const refs_manager = refs_mod.Refs.init(git_dir);
        var head_info = refs_manager.head(allocator, io.io) catch {
            errors.fatal(io, "not a gitz repository", .{});
        };
        defer head_info.deinit(allocator);
        break :refspec switch (head_info) {
            .branch => |b| try allocator.dupe(u8, b.name.items),
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
    const refs_manager = refs_mod.Refs.init(git_dir);
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

        ssh_transport.push(git_dir, ref, push_sha, old_sha) catch {
            try io.print("Note: SSH push failed, falling back to git\n", .{});
            try pushViaGit(allocator, git_dir, name, ref, force, io);
            return;
        };
    } else {
        // Use HTTP transport
        var transport = http.HttpTransport.init(allocator, io.io, url.?) catch {
            try io.print("Note: HTTP transport failed, falling back to git\n", .{});
            try pushViaGit(allocator, git_dir, name, ref, force, io);
            return;
        };
        defer transport.deinit();

        transport.push(git_dir, ref, push_sha) catch {
            try io.print("Note: HTTP push failed, falling back to git\n", .{});
            try pushViaGit(allocator, git_dir, name, ref, force, io);
            return;
        };
    }

    const hex = Sha1.hex(push_sha);
    try io.print("To {s}\n", .{url.?});
    try io.print("   {s}..{s}  {s} -> {s}\n", .{ hex[0..7], hex[0..7], ref, ref });
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
    var env = try io.childEnviron(allocator, &.{
        .{ "GIT_DIR", git_dir },
        .{ "GIT_INDEX_FILE", "/dev/null" },
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
