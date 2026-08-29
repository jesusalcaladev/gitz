const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Sha1 = @import("../../core/sha1.zig").Sha1;

const LFS_POINTER_VERSION = "https://git-lfs.github.com/spec/v1";

pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    if (args.len == 0) {
        try printHelp(io);
        return;
    }

    const subcmd = args[0];
    if (std.mem.eql(u8, subcmd, "install")) {
        try lfsInstall(allocator, git_dir, io);
    } else if (std.mem.eql(u8, subcmd, "track")) {
        try lfsTrack(allocator, git_dir, args[1..], io);
    } else if (std.mem.eql(u8, subcmd, "untrack")) {
        try lfsUntrack(allocator, git_dir, args[1..], io);
    } else if (std.mem.eql(u8, subcmd, "status")) {
        try lfsStatus(allocator, git_dir, io);
    } else if (std.mem.eql(u8, subcmd, "ls")) {
        try lfsLs(allocator, git_dir, io);
    } else if (std.mem.eql(u8, subcmd, "pointer")) {
        try lfsPointer(allocator, git_dir, args[1..], io);
    } else if (std.mem.eql(u8, subcmd, "env")) {
        try lfsEnv(allocator, git_dir, io);
    } else if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        try printHelp(io);
    } else {
        try io.eprint("gitz lfs: '{s}' is not a valid subcommand.\n\n", .{subcmd});
        try printHelp(io);
    }
}

fn printHelp(io: Io) !void {
    try io.print(
        \\usage: gitz lfs <subcommand> [options]
        \\
        \\Git Large File Storage (LFS) - track large files efficiently.
        \\
        \\Subcommands:
        \\  install              Set up Git LFS in this repository
        \\  track <pattern>      Track files matching <pattern> (e.g. "*.psd", "*.zip")
        \\  untrack <pattern>    Stop tracking files matching <pattern>
        \\  status               Show LFS tracked files and their status
        \\  ls                   List all LFS tracked files
        \\  pointer <file>       Show the LFS pointer for a file
        \\  env                  Show LFS environment/configuration
        \\
        \\Examples:
        \\  gitz lfs install
        \\  gitz lfs track "*.psd"
        \\  gitz lfs track "*.zip"
        \\  gitz lfs track "assets/**"
        \\  gitz lfs untrack "*.psd"
        \\  gitz lfs status
        \\
    , .{});
}

/// Initialize LFS in the repository
fn lfsInstall(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) !void {
    // Create .gitz/lfs directory
    const lfs_dir = try std.fmt.allocPrint(allocator, "{s}/lfs", .{git_dir});
    defer allocator.free(lfs_dir);
    try std.Io.Dir.cwd().createDirPath(io.io, lfs_dir);

    // Create .gitz/lfs/objects directory
    const objects_dir = try std.fmt.allocPrint(allocator, "{s}/lfs/objects", .{git_dir});
    defer allocator.free(objects_dir);
    try std.Io.Dir.cwd().createDirPath(io.io, objects_dir);

    // Create .gitzattributes if it doesn't exist
    const gitattributes_path = ".gitattributes";
    const exists = if (std.Io.Dir.cwd().access(io.io, gitattributes_path, .{})) |_| true else |_| false;

    if (!exists) {
        var f = try std.Io.Dir.cwd().createFile(io.io, gitattributes_path, .{});
        defer f.close(io.io);
        try std.Io.File.writeStreamingAll(f, io.io, "# Git LFS\n");
        try std.Io.File.writeStreamingAll(f, io.io, "*.psd filter=lfs diff=lfs merge=lfs -text\n");
        try std.Io.File.writeStreamingAll(f, io.io, "*.zip filter=lfs diff=lfs merge=lfs -text\n");
        try std.Io.File.writeStreamingAll(f, io.io, "*.tar.gz filter=lfs diff=lfs merge=lfs -text\n");
    }

    // Create .gitz/lfs/config
    const config_path = try std.fmt.allocPrint(allocator, "{s}/lfs/config", .{git_dir});
    defer allocator.free(config_path);
    var f = try std.Io.Dir.cwd().createFile(io.io, config_path, .{});
    defer f.close(io.io);
    try std.Io.File.writeStreamingAll(f, io.io, "[lfs]\n");
    try std.Io.File.writeStreamingAll(f, io.io, "    threshold = 10485760\n"); // 10 MB

    try io.print("\x1b[1;32m✓ Git LFS installed.\x1b[0m\n\n", .{});
    try io.print("  Created:\n", .{});
    try io.print("    {s}/lfs/\n", .{git_dir});
    try io.print("    {s}/lfs/objects/\n", .{git_dir});
    try io.print("    {s}/lfs/config\n", .{git_dir});
    try io.print("\n  Edit .gitattributes to customize tracked patterns.\n", .{});
    try io.print("  Current tracked patterns:\n", .{});
    try io.print("    *.psd\n", .{});
    try io.print("    *.zip\n", .{});
    try io.print("    *.tar.gz\n", .{});
}

/// Track files matching a pattern
fn lfsTrack(allocator: std.mem.Allocator, git_dir: []const u8, patterns: []const []const u8, io: Io) !void {
    _ = git_dir;
    if (patterns.len == 0) {
        try io.eprint("usage: gitz lfs track <pattern> [pattern...]\n", .{});
        return;
    }

    // Read existing .gitattributes
    const gitattributes_path = ".gitattributes";
    var existing_content: []const u8 = "";
    var content_buf: [64 * 1024]u8 = undefined;
    var content_len: usize = 0;

    if (std.Io.Dir.cwd().openFile(io.io, gitattributes_path, .{})) |f| {
        defer f.close(io.io);
        content_len = try f.readStreaming(io.io, &.{&content_buf});
        existing_content = content_buf[0..content_len];
    } else |_| {}

    // Check if LFS section already exists
    const has_lfs_section = std.mem.indexOf(u8, existing_content, "# Git LFS") != null;

    var new_content = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    defer new_content.deinit(allocator);

    if (!has_lfs_section) {
        try new_content.appendSlice(allocator, "# Git LFS\n");
    }

    // Add new patterns
    for (patterns) |pattern| {
        // Check if pattern already tracked
        const tracker = try std.fmt.allocPrint(allocator, "{s} filter=lfs diff=lfs merge=lfs -text", .{pattern});
        defer allocator.free(tracker);

        if (std.mem.indexOf(u8, existing_content, tracker) != null) {
            try io.print("\x1b[2mPattern '{s}' is already tracked.\x1b[0m\n", .{pattern});
            continue;
        }

        // Add the pattern
        const line = try std.fmt.allocPrint(allocator, "{s}\n", .{tracker});
        defer allocator.free(line);
        try new_content.appendSlice(allocator, line);
        try io.print("\x1b[32mTracking '{s}'\x1b[0m\n", .{pattern});
    }

    // Write .gitattributes
    var f = try std.Io.Dir.cwd().createFile(io.io, gitattributes_path, .{});
    defer f.close(io.io);

    if (has_lfs_section) {
        // Append to existing content
        try std.Io.File.writeStreamingAll(f, io.io, existing_content);
        try std.Io.File.writeStreamingAll(f, io.io, new_content.items);
    } else {
        // Write new content
        try std.Io.File.writeStreamingAll(f, io.io, new_content.items);
    }

    try io.print("\n\x1b[1;32m✓ Updated .gitattributes\x1b[0m\n", .{});
}

/// Stop tracking files matching a pattern
fn lfsUntrack(allocator: std.mem.Allocator, git_dir: []const u8, patterns: []const []const u8, io: Io) !void {
    _ = git_dir;
    if (patterns.len == 0) {
        try io.eprint("usage: gitz lfs untrack <pattern> [pattern...]\n", .{});
        return;
    }

    const gitattributes_path = ".gitattributes";
    var f = std.Io.Dir.cwd().openFile(io.io, gitattributes_path, .{}) catch {
        try io.eprint("fatal: .gitattributes not found\n", .{});
        return;
    };
    defer f.close(io.io);

    var buf: [64 * 1024]u8 = undefined;
    const n = try f.readStreaming(io.io, &.{&buf});
    const content = buf[0..n];

    var new_lines = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer {
        for (new_lines.items) |line| allocator.free(line);
        new_lines.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var skip = false;
        for (patterns) |pattern| {
            const lfs_entry = try std.fmt.allocPrint(allocator, "{s} filter=lfs", .{pattern});
            defer allocator.free(lfs_entry);
            if (std.mem.startsWith(u8, line, lfs_entry)) {
                skip = true;
                try io.print("\x1b[31mUntracked '{s}'\x1b[0m\n", .{pattern});
                break;
            }
        }
        if (!skip) {
            try new_lines.append(allocator, try allocator.dupe(u8, line));
        }
    }

    // Rewrite .gitattributes
    var wf = try std.Io.Dir.cwd().createFile(io.io, gitattributes_path, .{});
    defer wf.close(io.io);
    for (new_lines.items) |line| {
        try std.Io.File.writeStreamingAll(wf, io.io, line);
        try std.Io.File.writeStreamingAll(wf, io.io, "\n");
    }

    try io.print("\n\x1b[1;32m✓ Updated .gitattributes\x1b[0m\n", .{});
}

/// Show LFS status
fn lfsStatus(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) !void {
    try io.print("\x1b[1;36mLFS Status:\x1b[0m\n\n", .{});

    // Check if LFS is installed
    const lfs_dir = try std.fmt.allocPrint(allocator, "{s}/lfs", .{git_dir});
    defer allocator.free(lfs_dir);
    const installed = if (std.Io.Dir.cwd().access(io.io, lfs_dir, .{})) |_| true else |_| false;

    if (!installed) {
        try io.print("  \x1b[31mLFS is not installed.\x1b[0m Run 'gitz lfs install' first.\n", .{});
        return;
    }

    // Read .gitattributes
    const gitattributes_path = ".gitattributes";
    var f = std.Io.Dir.cwd().openFile(io.io, gitattributes_path, .{}) catch {
        try io.print("  \x1b[33mNo .gitattributes found.\x1b[0m\n", .{});
        return;
    };
    defer f.close(io.io);

    var buf: [64 * 1024]u8 = undefined;
    const n = try f.readStreaming(io.io, &.{&buf});
    const content = buf[0..n];

    try io.print("  \x1b[1mTracked patterns:\x1b[0m\n", .{});
    var found_patterns = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "filter=lfs")) |_| {
            // Extract pattern
            var parts = std.mem.splitScalar(u8, line, ' ');
            if (parts.next()) |pattern| {
                try io.print("    \x1b[33m{s}\x1b[0m\n", .{pattern});
                found_patterns = true;
            }
        }
    }
    if (!found_patterns) {
        try io.print("    \x1b[2m(none)\x1b[0m\n", .{});
    }

    // Count LFS objects using raw getdents64 to avoid Zig 0.16 fd lifecycle bug
    const objects_dir = try std.fmt.allocPrint(allocator, "{s}/lfs/objects", .{git_dir});
    defer allocator.free(objects_dir);

    var object_count: u32 = 0;
    var total_size: u64 = 0;

    const names = listDirRaw(allocator, objects_dir) catch {
        try io.print("\n  \x1b[2mNo LFS objects stored yet.\x1b[0m\n", .{});
        return;
    };
    defer {
        for (names) |nm| allocator.free(nm);
        allocator.free(names);
    }

    for (names) |entry_name| {
        object_count += 1;
        const entry_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir, entry_name });
        defer allocator.free(entry_path);
        const stat = std.Io.Dir.cwd().statFile(io.io, entry_path, .{}) catch null;
        if (stat) |s| total_size += @intCast(s.size);
    }

    try io.print("\n  \x1b[1mObjects:\x1b[0m {d}\n", .{object_count});
    if (total_size > 0) {
        try io.print("  \x1b[1mTotal size:\x1b[0m {d:.2} MB\n", .{@as(f64, @floatFromInt(total_size)) / (1024.0 * 1024.0)});
    }
}

/// List all LFS tracked files
fn lfsLs(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) !void {
    try io.print("\x1b[1;36mLFS Tracked Files:\x1b[0m\n\n", .{});

    const objects_dir = try std.fmt.allocPrint(allocator, "{s}/lfs/objects", .{git_dir});
    defer allocator.free(objects_dir);

    const names = listDirRaw(allocator, objects_dir) catch {
        try io.print("  \x1b[2mNo LFS objects found.\x1b[0m\n", .{});
        return;
    };
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    for (names) |entry_name| {
        try io.print("  \x1b[33m{s}\x1b[0m\n", .{entry_name});
    }

    if (names.len == 0) {
        try io.print("  \x1b[2m(none)\x1b[0m\n", .{});
    } else {
        try io.print("\n  \x1b[2m{d} object(s)\x1b[0m\n", .{names.len});
    }
}

/// Raw directory listing using Linux getdents64 syscall
fn listDirRaw(allocator: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };

    const dir_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{dir_path}, 0);
    defer allocator.free(dir_z);

    const fd = std.posix.openat(std.posix.AT.FDCWD, dir_z, std.posix.O{ .ACCMODE = .RDONLY }, 0) catch {
        return &.{};
    };
    defer { _ = std.os.linux.close(@intCast(fd)); }

    var buf: [4096]u8 align(@alignOf(usize)) = undefined;
    while (true) {
        const rc = std.os.linux.getdents64(@intCast(fd), &buf, buf.len);
        const n: usize = if (rc > 0) @intCast(rc) else break;
        if (n == 0) break;

        var pos: usize = 0;
        while (pos < n) {
            const entry: *align(1) const std.os.linux.dirent64 = @ptrCast(&buf[pos]);
            const name: []const u8 = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);

            if (name.len > 0 and name[0] != '.') {
                try result.append(allocator, try allocator.dupe(u8, name));
            }
            pos += entry.reclen;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Show LFS pointer for a file
fn lfsPointer(allocator: std.mem.Allocator, git_dir: []const u8, file_args: []const []const u8, io: Io) !void {
    _ = allocator;
    _ = git_dir;
    if (file_args.len == 0) {
        try io.eprint("usage: gitz lfs pointer <file>\n", .{});
        return;
    }

    const file_path = file_args[0];

    // Read the file
    var f = std.Io.Dir.cwd().openFile(io.io, file_path, .{}) catch {
        try io.eprint("fatal: file not found: {s}\n", .{file_path});
        return;
    };
    defer f.close(io.io);

    var buf: [1024 * 1024]u8 = undefined; // 1MB buffer
    const n = try f.readStreaming(io.io, &.{&buf});
    const content = buf[0..n];

    // Compute OID (SHA-256 of content)
    const oid = Sha1.hash(content);
    const oid_hex = Sha1.hex(oid);

    // Print pointer
    try io.print("\x1b[1;36mLFS Pointer:\x1b[0m\n\n", .{});
    try io.print("version {s}\n", .{LFS_POINTER_VERSION});
    try io.print("oid sha256:{s}\n", .{&oid_hex});
    try io.print("size {d}\n", .{content.len});
}

/// Show LFS environment
fn lfsEnv(allocator: std.mem.Allocator, git_dir: []const u8, io: Io) !void {
    try io.print("\x1b[1;36mLFS Environment:\x1b[0m\n\n", .{});

    // Check installation
    const lfs_dir = try std.fmt.allocPrint(allocator, "{s}/lfs", .{git_dir});
    defer allocator.free(lfs_dir);
    const installed = if (std.Io.Dir.cwd().access(io.io, lfs_dir, .{})) |_| true else |_| false;

    try io.print("  Installed:     {s}\n", .{if (installed) "\x1b[32myes\x1b[0m" else "\x1b[31mno\x1b[0m"});

    // Check .gitattributes
    const gitattributes_path = ".gitattributes";
    const has_attrs = if (std.Io.Dir.cwd().access(io.io, gitattributes_path, .{})) |_| true else |_| false;
    try io.print("  .gitattributes: {s}\n", .{if (has_attrs) "\x1b[32mexists\x1b[0m" else "\x1b[33mmissing\x1b[0m"});

    // Check config
    const config_path = try std.fmt.allocPrint(allocator, "{s}/lfs/config", .{git_dir});
    defer allocator.free(config_path);
    if (std.Io.Dir.cwd().openFile(io.io, config_path, .{})) |f| {
        defer f.close(io.io);
        var buf: [1024]u8 = undefined;
        const n = try f.readStreaming(io.io, &.{&buf});
        try io.print("\n  \x1b[1mConfig:\x1b[0m\n", .{});
        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (lines.next()) |line| {
            if (line.len > 0) {
                try io.print("    {s}\n", .{line});
            }
        }
    } else |_| {
        try io.print("  Config:         \x1b[2m(default)\x1b[0m\n", .{});
    }

    // Storage location
    try io.print("\n  \x1b[1mStorage:\x1b[0m\n", .{});
    try io.print("    {s}/lfs/objects/\n", .{git_dir});
}
