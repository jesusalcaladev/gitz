const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Config = @import("../../core/config.zig").Config;

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

fn loadConfig(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) !Config {
    var config = Config.init(allocator);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
    defer allocator.free(config_path);
    const content = std.Io.Dir.cwd().readFileAlloc(io.io, config_path, allocator, .unlimited) catch return config;
    defer allocator.free(content);
    try config.parse(content);
    return config;
}

fn saveConfig(allocator: std.mem.Allocator, git_dir: []const u8, config: Config, io: Io) !void {
    const serialized = try config.serialize(allocator);
    defer allocator.free(serialized);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
    defer allocator.free(config_path);
    try io.writeFile(config_path, serialized);
}

fn remoteAdd(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8, url: []const u8, io: Io) !void {
    if (name.len == 0 or url.len == 0) {
        try io.eprint("usage: gitz remote add <name> <url>\n", .{});
        return;
    }

    var config = try loadConfig(allocator, git_dir, io);
    defer config.deinit();

    // Check if remote already exists
    const section = try std.fmt.allocPrint(allocator, "remote \"{s}\"", .{name});
    defer allocator.free(section);
    if (config.get(section, "url")) |_| {
        try io.eprint("error: remote '{s}' already exists\n", .{name});
        return;
    }

    try config.set(section, "url", url);
    try saveConfig(allocator, git_dir, config, io);
    try io.print("remote {s} added\n", .{name});
}

fn remoteRemove(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8, io: Io) !void {
    var config = try loadConfig(allocator, git_dir, io);
    defer config.deinit();

    const section = try std.fmt.allocPrint(allocator, "remote \"{s}\"", .{name});
    defer allocator.free(section);
    if (config.get(section, "url") == null) {
        try io.eprint("error: remote '{s}' not found\n", .{name});
        return;
    }

    // Remove the section by re-serializing without it
    var new_config = Config.init(allocator);
    defer new_config.deinit();

    var section_iter = config.sections.iterator();
    while (section_iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, section)) {
            var val_iter = entry.value_ptr.iterator();
            while (val_iter.next()) |val| {
                const new_section = try allocator.dupe(u8, entry.key_ptr.*);
                if (!new_config.sections.contains(new_section)) {
                    _ = new_config.sections.remove(new_section);
                }
                try new_config.set(new_section, val.key_ptr.*, val.value_ptr.*);
            }
        }
    }

    try saveConfig(allocator, git_dir, new_config, io);
    try io.print("remote {s} removed\n", .{name});
}

fn remoteSetUrl(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8, url: []const u8, io: Io) !void {
    var config = try loadConfig(allocator, git_dir, io);
    defer config.deinit();

    const section = try std.fmt.allocPrint(allocator, "remote \"{s}\"", .{name});
    defer allocator.free(section);
    if (config.get(section, "url") == null) {
        try io.eprint("error: remote '{s}' not found\n", .{name});
        return;
    }

    try config.set(section, "url", url);
    try saveConfig(allocator, git_dir, config, io);
}

fn remoteRename(allocator: std.mem.Allocator, git_dir: []const u8, old: []const u8, new: []const u8, io: Io) !void {
    var config = try loadConfig(allocator, git_dir, io);
    defer config.deinit();

    const old_section = try std.fmt.allocPrint(allocator, "remote \"{s}\"", .{old});
    defer allocator.free(old_section);
    const url_val = config.get(old_section, "url");
    if (url_val == null) {
        try io.eprint("error: remote '{s}' not found\n", .{old});
        return;
    }

    const new_section = try std.fmt.allocPrint(allocator, "remote \"{s}\"", .{new});
    defer allocator.free(new_section);
    try config.set(new_section, "url", url_val.?);

    // Remove old section
    var new_config = Config.init(allocator);
    defer new_config.deinit();
    var section_iter = config.sections.iterator();
    while (section_iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, old_section)) {
            var val_iter = entry.value_ptr.iterator();
            while (val_iter.next()) |val| {
                try new_config.set(entry.key_ptr.*, val.key_ptr.*, val.value_ptr.*);
            }
        }
    }

    try saveConfig(allocator, git_dir, new_config, io);
    try io.print("remote {s} renamed to {s}\n", .{ old, new });
}

fn remoteList(allocator: std.mem.Allocator, git_dir: []const u8, verbose: bool, io: Io) !void {
    var config = try loadConfig(allocator, git_dir, io);
    defer config.deinit();

    // Iterate config sections to find remote sections
    var section_iter = config.sections.iterator();
    var found = false;
    while (section_iter.next()) |entry| {
        const section = entry.key_ptr.*;
        // Check if this is a "remote \"name\"" section
        if (std.mem.startsWith(u8, section, "remote \"")) {
            const rest = section[8..]; // skip 'remote "'
            if (rest.len > 0 and rest[rest.len - 1] == '"') {
                const remote_name = rest[0 .. rest.len - 1];
                found = true;
                if (verbose) {
                    if (config.get(section, "url")) |url| {
                        try io.print("{s}\t{s}\n", .{ remote_name, url });
                    } else {
                        try io.print("{s}\n", .{remote_name});
                    }
                } else {
                    try io.print("{s}\n", .{remote_name});
                }
            }
        }
    }

    if (!found) {
        try io.print("No remotes configured.\n", .{});
    }
}

pub fn getRemoteUrl(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8, io: Io) ?[]const u8 {
    // First try config file
    var config = loadConfig(allocator, git_dir, io) catch return null;
    defer config.deinit();

    const section = std.fmt.allocPrint(allocator, "remote \"{s}\"", .{name}) catch return null;
    defer allocator.free(section);

    if (config.get(section, "url")) |url| {
        return allocator.dupe(u8, url) catch null;
    }
    return null;
}
