const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const config_cmd = @import("config.zig");
const refs_mod = @import("../../core/refs.zig");
const errors = @import("../errors.zig");

/// How the fetched commits are integrated.
const Mode = enum {
    /// git's historical default.
    merge,
    rebase,
    ff_only,
};

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var mode: Mode = .merge;
    var remote_name: ?[]const u8 = null;
    var branch_name: ?[]const u8 = null;
    var use_git = false;
    var rebase_merges = false;
    var ff = false;
    var no_ff = false;
    var quiet = false;
    var positional: usize = 0;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--merge") or std.mem.eql(u8, arg, "-m")) {
            mode = .merge;
        } else if (std.mem.eql(u8, arg, "--rebase") or std.mem.eql(u8, arg, "-r")) {
            mode = .rebase;
        } else if (std.mem.eql(u8, arg, "--ff-only")) {
            mode = .ff_only;
        } else if (std.mem.eql(u8, arg, "--rebase-merges") or std.mem.eql(u8, arg, "--no-rebase-merges")) {
            rebase_merges = true;
        } else if (std.mem.eql(u8, arg, "--ff")) {
            ff = true;
        } else if (std.mem.eql(u8, arg, "--no-ff")) {
            no_ff = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--git") or std.mem.eql(u8, arg, "-g")) {
            use_git = true;
        } else if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--no-autostash") or
            std.mem.eql(u8, arg, "--autostash"))
        {
            // Accepted; there is no autostash to perform.
        } else if (std.mem.startsWith(u8, arg, "-")) {
            errors.errorf(io, "unknown option '{s}'", .{arg});
        } else if (positional == 0) {
            remote_name = arg;
            positional = 1;
        } else if (positional == 1) {
            // `git pull <remote> <branch>` names both explicitly.
            branch_name = arg;
            positional = 2;
        } else {
            errors.errorf(io, "too many arguments", .{});
        }
    }
    // `--rebase-merges`, `--ff` and `--no-ff` are accepted and inert: merges are
    // replayed as-is and the mode is chosen by --merge/--rebase/--ff-only.

    const name = remote_name orelse blk: {
        // Without an explicit remote, use the one the current branch tracks
        // (`branch.<name>.remote`), then fall back to "origin".
        if (branchName(allocator, git_dir, io)) |b| {
            const key = try std.fmt.allocPrint(allocator, "branch.{s}.remote", .{b});
            defer allocator.free(key);
            if (configValue(allocator, git_dir, io, key)) |r| {
                defer allocator.free(r);
                if (r.len > 0 and !std.mem.eql(u8, r, ".")) break :blk try allocator.dupe(u8, r);
            }
        }
        break :blk "origin";
    };

    // The upstream to integrate. `<remote>/<branch>` was hardcoded, so
    // `gitz pull` on a feature branch integrated origin/main and lost the
    // divergence it was meant to resolve. The current branch (or the one given)
    // is used now, which is what git does.
    const current = branchName(allocator, git_dir, io) orelse
        errors.fatal(io, "You are not currently on a branch", .{});
    defer allocator.free(current);
    const upstream_branch = branch_name orelse blk: {
        const merge_key = try std.fmt.allocPrint(allocator, "branch.{s}.merge", .{current});
        defer allocator.free(merge_key);
        if (configValue(allocator, git_dir, io, merge_key)) |m| {
            defer allocator.free(m);
            if (std.mem.startsWith(u8, m, "refs/heads/")) {
                break :blk try allocator.dupe(u8, m["refs/heads/".len..]);
            }
        }
        break :blk current;
    };
    const upstream = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ name, upstream_branch });
    defer allocator.free(upstream);

    if (use_git) {
        try pullViaGit(allocator, git_dir, name, mode, io);
        return;
    }

    // Step 1: Fetch. A failure has to stop the command, not be followed by a
    // rebase against nothing.
    if (!quiet) try io.print("Fetching {s}\n", .{name});
    const fetch_args = [_][]const u8{name};
    @import("fetch.zig").execute(allocator, git_dir, &fetch_args, io) catch
        errors.fatal(io, "could not fetch from {s}", .{name});

    // Step 2: Integrate the remote-tracking ref.
    //
    // `gitz merge <remote>/<branch>` looked for `refs/heads/origin/main`,
    // which never exists, so `--merge` always failed. The remote-tracking ref is
    // passed to the merge command, which resolves it as a revision.
    switch (mode) {
        .rebase => {
            if (!quiet) try io.print("Rebasing onto {s}...\n", .{upstream});
            const rebase_args = [_][]const u8{upstream};
            @import("rebase.zig").execute(allocator, git_dir, &rebase_args, io) catch |err| {
                try io.eprint("error: could not rebase onto {s}: {s}\n", .{ upstream, @errorName(err) });
                std.process.exit(errors.ExitFailure);
            };
        },
        .merge, .ff_only => {
            if (!quiet) try io.print("Merging {s} into the current branch...\n", .{upstream});
            const merge_args = [_][]const u8{upstream};
            @import("merge.zig").execute(allocator, git_dir, &merge_args, io) catch |err| {
                try io.eprint("error: could not merge {s}: {s}\n", .{ upstream, @errorName(err) });
                std.process.exit(errors.ExitFailure);
            };
        },
    }

}

/// The branch HEAD points at, or null when detached or unborn.
///
/// The name is copied out before the `HeadInfo` is released: returning the
/// `ArrayList` member left a dangling pointer, and the name came out as garbage
/// bytes that were then used as the remote branch to pull.
fn branchName(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) ?[]const u8 {
    const refs_manager = refs_mod.Refs.init(git_dir);
    var head = refs_manager.head(allocator, io.io) catch return null;
    defer head.deinit(allocator);

    const name = head.branchOf() orelse return null;
    return allocator.dupe(u8, name) catch null;
}

/// Read a config value, returning null when it is absent.
fn configValue(allocator: std.mem.Allocator, git_dir: []const u8, io: Io, key: []const u8) ?[]const u8 {
    var flat = config_cmd.readFlatMap(allocator, git_dir, io) catch return null;
    defer config_cmd.freeFlatMap(allocator, &flat);

    const found = flat.get(key) orelse return null;
    return allocator.dupe(u8, found) catch null;
}

/// Pull using system git as fallback.
///
/// The remote name came from argv and was pasted into an `sh -c` string, so
/// `gitz pull 'origin; id' --git` executed the injected command. git is now
/// invoked with a plain argv and an explicit environment.
fn pullViaGit(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    remote_name: []const u8,
    mode: Mode,
    io: Io,
) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "pull");
    switch (mode) {
        .rebase => try argv.append(allocator, "--rebase"),
        .ff_only => try argv.append(allocator, "--ff-only"),
        .merge => {},
    }
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
        errors.fatal(io, "git pull failed: {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stdout.len > 0) try io.print("{s}", .{result.stdout});
    if (result.stderr.len > 0) try io.eprint("{s}", .{result.stderr});

    const exited: u8 = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };
    if (exited != 0) std.process.exit(exited);
}
