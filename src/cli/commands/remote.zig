const std = @import("std");
const Io = @import("../../util/io.zig").Io;

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var verbose = false;
    var subcmd: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var url: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (subcmd == null) {
            subcmd = arg;
        } else if (name == null) {
            name = arg;
        } else if (url == null) {
            url = arg;
        }
    }

    const action = subcmd orelse "show";

    if (std.mem.eql(u8, action, "add")) {
        try remoteAdd(allocator, git_dir, name orelse "", url orelse "", io);
    } else if (std.mem.eql(u8, action, "remove") or std.mem.eql(u8, action, "rm")) {
        try remoteRemove(allocator, git_dir, name orelse "", io);
    } else if (std.mem.eql(u8, action, "set-url")) {
        try remoteSetUrl(allocator, git_dir, name orelse "", url orelse "", io);
    } else if (std.mem.eql(u8, action, "rename")) {
        try remoteRename(allocator, git_dir, name orelse "", url orelse "", io);
    } else if (std.mem.eql(u8, action, "get-url")) {
        if (name) |n| {
            const u = getRemoteUrl(allocator, git_dir, n, io);
            defer if (u) |uu| allocator.free(uu);
            if (u) |uu| {
                try io.print("{s}\n", .{uu});
            } else {
                try io.eprint("error: remote '{s}' not found\n", .{n});
            }
        }
    } else {
        try remoteList(allocator, git_dir, verbose, io);
    }
}

fn remoteAdd(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8, url: []const u8, io: Io) !void {
    if (name.len == 0 or url.len == 0) {
        try io.eprint("usage: gitz remote add <name> <url>\n", .{});
        return;
    }
    // Check if exists
    const existing = getRemoteUrl(allocator, git_dir, name, io);
    defer if (existing) |e| allocator.free(e);
    if (existing != null) {
        try io.eprint("error: remote '{s}' already exists\n", .{name});
        return;
    }
    try writeRemote(allocator, git_dir, name, url, io);
    try io.print("remote {s} added\n", .{name});
}

fn remoteRemove(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8, io: Io) !void {
    const existing = getRemoteUrl(allocator, git_dir, name, io);
    defer if (existing) |e| allocator.free(e);
    if (existing == null) {
        try io.eprint("error: remote '{s}' not found\n", .{name});
        return;
    }
    const file_path = try std.fmt.allocPrint(allocator, "{s}/remotes/{s}", .{ git_dir, name });
    defer allocator.free(file_path);
    io.removeFile(file_path) catch {};
    try io.print("remote {s} removed\n", .{name});
}

fn remoteSetUrl(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8, url: []const u8, io: Io) !void {
    const existing = getRemoteUrl(allocator, git_dir, name, io);
    defer if (existing) |e| allocator.free(e);
    if (existing == null) {
        try io.eprint("error: remote '{s}' not found\n", .{name});
        return;
    }
    try writeRemote(allocator, git_dir, name, url, io);
}

fn remoteRename(allocator: std.mem.Allocator, git_dir: []const u8, old: []const u8, new: []const u8, io: Io) !void {
    const url_val = getRemoteUrl(allocator, git_dir, old, io);
    defer if (url_val) |u| allocator.free(u);
    if (url_val == null) {
        try io.eprint("error: remote '{s}' not found\n", .{old});
        return;
    }
    // Delete old, create new
    const old_path = try std.fmt.allocPrint(allocator, "{s}/remotes/{s}", .{ git_dir, old });
    defer allocator.free(old_path);
    io.removeFile(old_path) catch {};
    try writeRemote(allocator, git_dir, new, url_val.?, io);
}

fn remoteList(allocator: std.mem.Allocator, git_dir: []const u8, verbose: bool, io: Io) !void {
    const remotes_dir = try std.fmt.allocPrint(allocator, "{s}/remotes", .{git_dir});
    defer allocator.free(remotes_dir);

    // Use raw getdents64 to list remotes directory
    const dir_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{remotes_dir}, 0);
    defer allocator.free(dir_z);

    const fd = std.posix.openat(std.posix.AT.FDCWD, dir_z, std.posix.O{ .ACCMODE = .RDONLY }, 0) catch return;
    defer { _ = std.os.linux.close(@intCast(fd)); }

    var buf: [4096]u8 align(@alignOf(usize)) = undefined;
    while (true) {
        const rc = std.os.linux.getdents64(@intCast(fd), &buf, buf.len);
        const n: usize = if (rc > 0) @intCast(rc) else break;
        if (n == 0) break;

        var pos: usize = 0;
        while (pos < n) {
            const direntry: *align(1) const std.os.linux.dirent64 = @ptrCast(&buf[pos]);
            const rname: []const u8 = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&direntry.name)), 0);
            if (rname.len > 0 and rname[0] != '.') {
                if (verbose) {
                    const u = getRemoteUrl(allocator, git_dir, rname, io);
                    defer if (u) |uu| allocator.free(uu);
                    if (u) |uu| {
                        try io.print("{s}\t{s}\n", .{ rname, uu });
                    } else {
                        try io.print("{s}\n", .{rname});
                    }
                } else {
                    try io.print("{s}\n", .{rname});
                }
            }
            pos += direntry.reclen;
        }
    }
}

fn writeRemote(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8, url: []const u8, io: Io) !void {
    const remotes_dir = try std.fmt.allocPrint(allocator, "{s}/remotes", .{git_dir});
    defer allocator.free(remotes_dir);
    io.makeDir(remotes_dir) catch {};

    const file_path = try std.fmt.allocPrint(allocator, "{s}/remotes/{s}", .{ git_dir, name });
    defer allocator.free(file_path);

    try io.writeFile(file_path, url);
}

pub fn getRemoteUrl(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8, io: Io) ?[]const u8 {
    const file_path = std.fmt.allocPrint(allocator, "{s}/remotes/{s}", .{ git_dir, name }) catch return null;
    defer allocator.free(file_path);

    const content = io.readFileAlloc(file_path) catch return null;
    return std.mem.trim(u8, content, &[_]u8{ '\n', '\r', ' ' });
}
