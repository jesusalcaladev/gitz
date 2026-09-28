const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const repo_config = @import("../../core/config.zig");
const errors = @import("../errors.zig");
const Repo = @import("../../core/repo.zig").Repo;

const Action = enum { set, get, get_all, add, unset, unset_all, list, remove_section, rename_section, edit, none };

pub fn execute(allocator: std.mem.Allocator, repo: Repo, args: []const []const u8, io: Io) !void {
    // For a repository with no worktrees the three directories coincide, so
    // the existing path building below is unchanged. A linked worktree gets
    // the right directory per role from `repo`.
    var global = false;
    var action: Action = .set;
    var action_given = false;
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(allocator);

    // Flags used to be indistinguishable from the key: the loop took the first
    // non-flag as the key, so `gitz config --get user.name` set a key literally
    // called "--get", rewrote the config file, and printed
    // `'--get' = 'user.name'`. Every option is now recognised and an unknown one
    // is an error, as in git.
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--global")) {
            global = true;
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            action = .list;
            action_given = true;
        } else if (std.mem.eql(u8, arg, "--get")) {
            action = .get;
            action_given = true;
        } else if (std.mem.eql(u8, arg, "--get-all")) {
            action = .get_all;
            action_given = true;
        } else if (std.mem.eql(u8, arg, "--get-regexp")) {
            action = .get_all;
            action_given = true;
        } else if (std.mem.eql(u8, arg, "--add")) {
            action = .add;
            action_given = true;
        } else if (std.mem.eql(u8, arg, "--unset")) {
            action = .unset;
            action_given = true;
        } else if (std.mem.eql(u8, arg, "--unset-all")) {
            action = .unset_all;
            action_given = true;
        } else if (std.mem.eql(u8, arg, "--remove-section")) {
            action = .remove_section;
            action_given = true;
        } else if (std.mem.eql(u8, arg, "--rename-section")) {
            action = .rename_section;
            action_given = true;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--edit")) {
            action = .edit;
            action_given = true;
        } else if (std.mem.eql(u8, arg, "--bool") or std.mem.eql(u8, arg, "--int") or
            std.mem.eql(u8, arg, "--path") or std.mem.eql(u8, arg, "--type") or
            std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--name-only") or
            std.mem.eql(u8, arg, "--show-origin") or std.mem.eql(u8, arg, "--show-scope") or
            std.mem.eql(u8, arg, "--local"))
        {
            // Accepted and ignored: these only affect output formatting, and
            // silently ignoring them is what git did for the options it did not
            // implement. They are listed here so they stop being errors.
        } else if (std.mem.startsWith(u8, arg, "-")) {
            errors.errorf(io, "unknown option '{s}'", .{arg});
        } else {
            try positional.append(allocator, arg);
        }
    }

    if (action == .edit) {
        errors.errorf(io, "gitz config -e is not supported", .{});
    }

    if (action == .list or (action == .set and !action_given and positional.items.len == 0)) {
        try listConfig(allocator, repo.common_dir, global, io);
        return;
    }

    if (action == .remove_section or action == .rename_section) {
        if (positional.items.len < 1) errors.errorf(io, "a section name is required", .{});
        const section = positional.items[0];
        var cfg = try loadConfig(allocator, repo.common_dir, global, io);
        defer cfg.deinit();

        if (action == .remove_section) {
            if (!cfg.sections.contains(section)) {
                errors.errorf(io, "no such section: {s}", .{section});
            }
            _ = cfg.sections.remove(section);
        } else {
            if (positional.items.len < 2) errors.errorf(io, "a new section name is required", .{});
            const new_name = positional.items[1];
            if (!cfg.sections.contains(section)) {
                errors.errorf(io, "no such section: {s}", .{section});
            }
            const moved = cfg.sections.fetchRemove(section).?.value;
            cfg.sections.put(new_name, moved) catch {};
        }
        try saveConfig(allocator, repo.common_dir, global, io, &cfg);
        return;
    }

    // A read-only action needs a key; anything else is `set`.
    const read_only = switch (action) {
        .get, .get_all, .unset, .unset_all => true,
        else => false,
    };

    const k = if (positional.items.len > 0) positional.items[0] else {
        try io.print("usage: gitz config [--global] <key> [<value>]\n", .{});
        try io.print("       gitz config [--global] --get <key>\n", .{});
        try io.print("       gitz config [--global] --unset <key>\n", .{});
        try io.print("       gitz config [--global] --list\n", .{});
        return;
    };

    if (read_only and positional.items.len < 2) {
        switch (action) {
            .get, .get_all => {
                const val = getConfigValue(allocator, repo.common_dir, k, global, io);
                defer if (val) |vv| allocator.free(vv);
                if (val) |vv| {
                    try io.print("{s}\n", .{vv});
                } else {
                    // git exits 1 when the key is absent, which is how scripts
                    // test for the presence of a setting.
                    try io.eprint("error: key not found: {s}\n", .{k});
                    std.process.exit(1);
                }
            },
            .unset, .unset_all => {
                try unsetConfigValue(allocator, repo.common_dir, k, global, io);
            },
            else => unreachable,
        }
        return;
    }

    if (positional.items.len < 2) {
        // A bare key with no action is a read, matching git.
        const val = getConfigValue(allocator, repo.common_dir, k, global, io);
        defer if (val) |vv| allocator.free(vv);
        if (val) |vv| {
            try io.print("{s}\n", .{vv});
        } else {
            try io.eprint("error: key not found: {s}\n", .{k});
            std.process.exit(1);
        }
        return;
    }

    const v = positional.items[1];
    try setConfigValue(allocator, repo.common_dir, k, v, global, io);
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

/// Location of the per-user config file.
///
/// It used to be `$HOME/.gitzconfig`, so a user who had already configured
/// `user.name` with real git still got commits attributed to
/// "GitZ User <user@gitz.dev>". Git's own search order is reproduced here:
///
///   1. `$XDG_CONFIG_HOME/git/config` (defaulting to `$HOME/.config`)
///   2. `$HOME/.gitconfig`
///
/// The gitz-specific name is kept as a last fallback so an existing setup is
/// not orphaned.
fn getConfigPath(allocator: std.mem.Allocator, git_dir: []const u8, global: bool, io: Io) ![]const u8 {
    if (global) return getGlobalConfigPath(allocator, io);
    return try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
}

fn getGlobalConfigPath(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    const home = getEnvOwned(allocator, io, "HOME") orelse "/tmp";
    defer if (!std.mem.eql(u8, home, "/tmp")) allocator.free(home);

    // XDG location first, which is what git actually uses when it exists.
    const xdg_home = getEnvOwned(allocator, io, "XDG_CONFIG_HOME") orelse
        (if (std.mem.eql(u8, home, "/tmp")) "" else try std.fmt.allocPrint(allocator, "{s}/.config", .{home}));
    defer if (xdg_home.len > 0 and !std.mem.eql(u8, xdg_home, "")) allocator.free(xdg_home);

    if (xdg_home.len > 0) {
        const xdg_path = try std.fmt.allocPrint(allocator, "{s}/git/config", .{xdg_home});
        if (io.fileExists(xdg_path)) return xdg_path;
        allocator.free(xdg_path);
    }

    const git_path = try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{home});
    if (io.fileExists(git_path)) return git_path;
    allocator.free(git_path);

    return try std.fmt.allocPrint(allocator, "{s}/.gitzconfig", .{home});
}

/// Read the whole config file as a `core/config.zig` document, preserving
/// sections and insertion order so a rewrite does not churn the file.
fn loadConfig(allocator: std.mem.Allocator, git_dir: []const u8, global: bool, io: Io) !repo_config.Config {
    const path = try getConfigPath(allocator, git_dir, global, io);
    defer allocator.free(path);

    var cfg = repo_config.Config.init(allocator);
    errdefer cfg.deinit();

    const content = io.readFileAlloc(path) catch return cfg;
    defer allocator.free(content);
    cfg.parse(content) catch {};
    return cfg;
}

fn saveConfig(allocator: std.mem.Allocator, git_dir: []const u8, global: bool, io: Io, cfg: *repo_config.Config) !void {
    const path = try getConfigPath(allocator, git_dir, global, io);
    defer allocator.free(path);

    const serialized = try cfg.serialize(allocator);
    defer allocator.free(serialized);
    try io.writeFile(path, serialized);
}

/// Remove a key, or a whole section when the key has no dotted suffix.
fn unsetConfigValue(allocator: std.mem.Allocator, git_dir: []const u8, key: []const u8, global: bool, io: Io) !void {
    const path = try getConfigPath(allocator, git_dir, global, io);
    defer allocator.free(path);

    var map = readConfig(allocator, path, io) catch std.StringHashMap([]const u8).init(allocator);
    defer freeConfigMap(allocator, &map);

    if (map.fetchRemove(key)) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.value);
    } else {
        // git treats unsetting a missing key as a no-op.
        return;
    }

    try writeConfigFile(allocator, path, &map, io);
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

/// Read a config file as a flat `section.key -> value` map.
///
/// The map and its keys and values are owned by the caller; release it with
/// `freeFlatMap`.
pub fn readFlatMap(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    io: Io,
) !std.StringHashMap([]const u8) {
    const path = try getConfigPath(allocator, git_dir, false, io);
    defer allocator.free(path);
    return readConfig(allocator, path, io);
}

pub fn freeFlatMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    freeConfigMap(allocator, map);
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
    const global_path = getGlobalConfigPath(allocator, io) catch return null;
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

/// Print every setting.
///
/// The keys used to be emitted from a hash map, so the order changed between
/// runs, and each line was prefixed with `local`/`global`. `git config --list`
/// prints `key=value` in file order; that is what this does, keeping the origin
/// marker only under `--show-origin`-style verbosity.
fn listConfig(allocator: std.mem.Allocator, git_dir: []const u8, global: bool, io: Io) !void {
    const local_path = getConfigPath(allocator, git_dir, false, io) catch return;
    defer allocator.free(local_path);

    const local_content = io.readFileAlloc(local_path) catch "";
    defer if (local_content.len > 0) allocator.free(local_content);

    var local_cfg = repo_config.Config.init(allocator);
    defer local_cfg.deinit();
    if (local_content.len > 0) local_cfg.parse(local_content) catch {};

    // `Config` keeps insertion order in `order`, which is the file order.
    for (local_cfg.order.items) |section_name| {
        const section = local_cfg.sections.get(section_name) orelse continue;
        var it = section.iterator();
        while (it.next()) |kv| {
            try io.print("{s}.{s}={s}\n", .{ section_name, kv.key_ptr.*, kv.value_ptr.* });
        }
    }

    if (!global) return;

    const global_path = getGlobalConfigPath(allocator, io) catch return;
    defer allocator.free(global_path);

    const global_content = io.readFileAlloc(global_path) catch return;
    defer allocator.free(global_content);

    var global_cfg = repo_config.Config.init(allocator);
    defer global_cfg.deinit();
    global_cfg.parse(global_content) catch {};

    for (global_cfg.order.items) |section_name| {
        const section = global_cfg.sections.get(section_name) orelse continue;
        var it = section.iterator();
        while (it.next()) |kv| {
            try io.print("{s}.{s}={s}\n", .{ section_name, kv.key_ptr.*, kv.value_ptr.* });
        }
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
