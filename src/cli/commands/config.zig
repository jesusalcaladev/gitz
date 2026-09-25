const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const repo_config = @import("../../core/config.zig");

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    var global = false;
    var list_mode = false;
    var key: ?[]const u8 = null;
    var value: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--global")) {
            global = true;
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            list_mode = true;
        } else if (key == null) {
            key = arg;
        } else if (value == null) {
            value = arg;
        }
    }

    if (list_mode) {
        try listConfig(allocator, git_dir, global, io);
        return;
    }

    const k = key orelse {
        try io.print("usage: gitz config [--global] <key> <value>\n", .{});
        try io.print("       gitz config --list\n", .{});
        return;
    };

    const v = value orelse {
        const val = getConfigValue(allocator, git_dir, k, global, io);
        defer if (val) |vv| allocator.free(vv);
        if (val) |vv| {
            try io.print("{s}\n", .{vv});
        } else {
            try io.eprint("error: key not found: {s}\n", .{k});
        }
        return;
    };

    try setConfigValue(allocator, git_dir, k, v, global, io);
}

/// Read env var from /proc/self/environ (Linux, no libc needed)
fn getEnvOwned(allocator: std.mem.Allocator, io: Io, name: []const u8) ?[]const u8 {
    var f = io.openFile("/proc/self/environ") catch return null;
    defer f.close(io.io);

    var buf: [64 * 1024]u8 = undefined;
    const n = f.readStreaming(io.io, &.{&buf}) catch return null;
    if (n == 0) return null;

    const environ_data = buf[0..n];
    var entries = std.mem.splitScalar(u8, environ_data, 0);
    while (entries.next()) |entry| {
        if (std.mem.startsWith(u8, entry, name) and entry.len > name.len and entry[name.len] == '=') {
            return allocator.dupe(u8, entry[name.len + 1 ..]) catch null;
        }
    }
    return null;
}

fn getConfigPath(allocator: std.mem.Allocator, git_dir: []const u8, global: bool, io: Io) ![]const u8 {
    if (global) {
        const home = getEnvOwned(allocator, io, "HOME") orelse "/tmp";
        defer if (!std.mem.eql(u8, home, "/tmp")) allocator.free(home);
        return try std.fmt.allocPrint(allocator, "{s}/.gitzconfig", .{home});
    }
    return try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
}

fn readConfig(allocator: std.mem.Allocator, path: []const u8, io: Io) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);

    const content = io.readFileAlloc(path) catch return map;
    defer allocator.free(content);

    // One parser for the whole codebase: `core/config.zig` understands real
    // git config syntax, including `[section "subsection"]` headers.
    var parsed = repo_config.Config.init(allocator);
    defer parsed.deinit();
    parsed.parse(content) catch return map;

    var it = parsed.sections.iterator();
    while (it.next()) |section| {
        var vals = section.value_ptr.iterator();
        while (vals.next()) |kv| {
            const full_key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ section.key_ptr.*, kv.key_ptr.* });
            errdefer allocator.free(full_key);
            const owned_value = try allocator.dupe(u8, kv.value_ptr.*);
            errdefer allocator.free(owned_value);
            if (map.getPtr(full_key)) |old| {
                allocator.free(old.*);
                old.* = owned_value;
            } else {
                try map.put(full_key, owned_value);
            }
        }
    }

    return map;
}

/// Write `map` (flat `section.key = value` form) back as a git config file
/// that real git accepts.
///
/// The previous version emitted `core.repositoryformatversion = 0` with no
/// `[core]` header, which git rejects outright:
/// `fatal: bad config line 1 in file .gitz/config`. Sections are reconstructed
/// from the dotted keys, and the values already in the file keep their original
/// order so that unrelated rewrites do not churn the config.
fn writeConfigFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    map: *const std.StringHashMap([]const u8),
    io: Io,
) !void {
    var parsed = repo_config.Config.init(allocator);
    defer parsed.deinit();

    var it = map.iterator();
    while (it.next()) |entry| {
        const dot = std.mem.indexOfScalar(u8, entry.key_ptr.*, '.') orelse continue;
        try parsed.set(entry.key_ptr.*[0..dot], entry.key_ptr.*[dot + 1 ..], entry.value_ptr.*);
    }

    const serialized = try parsed.serialize(allocator);
    defer allocator.free(serialized);
    try io.writeFile(path, serialized);
}

fn freeConfigMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

fn getConfigValue(allocator: std.mem.Allocator, git_dir: []const u8, key: []const u8, global: bool, io: Io) ?[]const u8 {
    if (global) {
        const path = getConfigPath(allocator, git_dir, true, io) catch return null;
        defer allocator.free(path);
        var map = readConfig(allocator, path, io) catch return null;
        defer freeConfigMap(allocator, &map);
        const v = map.get(key) orelse return null;
        return allocator.dupe(u8, v) catch null;
    }

    // Try local config
    const local_path = getConfigPath(allocator, git_dir, false, io) catch return null;
    defer allocator.free(local_path);
    var local_map = readConfig(allocator, local_path, io) catch return null;
    defer freeConfigMap(allocator, &local_map);
    if (local_map.get(key)) |v| {
        return allocator.dupe(u8, v) catch null;
    }

    // Try global config
    const home = getEnvOwned(allocator, io, "HOME") orelse "/tmp";
    defer if (!std.mem.eql(u8, home, "/tmp")) allocator.free(home);
    const global_path = std.fmt.allocPrint(allocator, "{s}/.gitzconfig", .{home}) catch return null;
    defer allocator.free(global_path);
    var global_map = readConfig(allocator, global_path, io) catch return null;
    defer freeConfigMap(allocator, &global_map);
    const v = global_map.get(key) orelse return null;
    return allocator.dupe(u8, v) catch null;
}

fn setConfigValue(allocator: std.mem.Allocator, git_dir: []const u8, key: []const u8, value: []const u8, global: bool, io: Io) !void {
    const path = getConfigPath(allocator, git_dir, global, io) catch return;
    defer allocator.free(path);

    var map = readConfig(allocator, path, io) catch std.StringHashMap([]const u8).init(allocator);
    defer freeConfigMap(allocator, &map);

    const owned_key = try allocator.dupe(u8, key);
    const owned_value = try allocator.dupe(u8, value);

    if (map.getPtr(key)) |old| {
        allocator.free(old.*);
        old.* = owned_value;
    } else {
        try map.put(owned_key, owned_value);
    }

    try writeConfigFile(allocator, path, &map, io);
    try io.print("'{s}' = '{s}'\n", .{ key, value });
}

fn listConfig(allocator: std.mem.Allocator, git_dir: []const u8, global: bool, io: Io) !void {
    const local_path = getConfigPath(allocator, git_dir, false, io) catch return;
    defer allocator.free(local_path);
    var local_map = readConfig(allocator, local_path, io) catch return;
    defer freeConfigMap(allocator, &local_map);

    var local_iter = local_map.iterator();
    while (local_iter.next()) |entry| {
        try io.print("local\t{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    if (!global) return;

    const home = getEnvOwned(allocator, io, "HOME") orelse "/tmp";
    defer if (!std.mem.eql(u8, home, "/tmp")) allocator.free(home);
    const global_path = try std.fmt.allocPrint(allocator, "{s}/.gitzconfig", .{home});
    defer allocator.free(global_path);
    var global_map = readConfig(allocator, global_path, io) catch return;
    defer freeConfigMap(allocator, &global_map);

    var global_iter = global_map.iterator();
    while (global_iter.next()) |entry| {
        try io.print("global\t{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}

/// Get user name from config or environment
pub fn getUserName(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) []const u8 {
    if (getEnvOwned(allocator, io, "GIT_AUTHOR_NAME")) |name| return name;
    if (getConfigValue(allocator, git_dir, "user.name", false, io)) |name| return name;
    return "GitZ User";
}

/// Get user email from config or environment
pub fn getUserEmail(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) []const u8 {
    if (getEnvOwned(allocator, io, "GIT_AUTHOR_EMAIL")) |email| return email;
    if (getConfigValue(allocator, git_dir, "user.email", false, io)) |email| return email;
    return "user@gitz.dev";
}
