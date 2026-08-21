const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const zlib_mod = @import("../../core/zlib.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, io: Io) !void {
    if (args.len == 0) {
        try io.eprint("usage: gitz clone <url> [directory]\n", .{});
        std.process.exit(1);
    }

    const url = args[0];

    const dest = if (args.len > 1) args[1] else dest: {
        const last_slash = std.mem.lastIndexOf(u8, url, "/") orelse url.len;
        var name = url[last_slash..];
        if (name.len > 0 and name[0] == '/') name = name[1..];
        if (std.mem.lastIndexOf(u8, name, ":")) |colon_pos| {
            name = name[colon_pos + 1 ..];
        }
        if (std.mem.endsWith(u8, name, ".git")) {
            name = name[0 .. name.len - 4];
        }
        break :dest name;
    };

    try io.print("Cloning into '{s}'...\n", .{dest});

    // Use git clone --bare into a temp directory
    const tmp_dir = ".gitz_tmp_clone";
    std.Io.Dir.cwd().deleteTree(io.io, tmp_dir) catch {};

    var child_argv = [_][]const u8{ "git", "clone", "--bare", url, tmp_dir };

    var child = std.process.spawn(io.io, .{
        .argv = &child_argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        try io.eprint("fatal: 'git' is required for clone (install git first)\n", .{});
        return;
    };

    drainChild(&child, io);
    const term = child.wait(io.io) catch {
        try io.eprint("fatal: git clone failed\n", .{});
        return;
    };

    if (term != .exited or term.exited != 0) {
        try io.eprint("fatal: git clone failed\n", .{});
        std.Io.Dir.cwd().deleteTree(io.io, tmp_dir) catch {};
        return;
    }

    // Import objects and refs from the bare clone
    var object_count: u32 = 0;

    // Use git pack-objects or just copy objects directly
    // The simplest approach: copy the entire objects directory
    copyObjects(allocator, io, tmp_dir, dest, &object_count) catch {};

    // Copy refs using git show-ref
    const ref_count = copyRefs(allocator, io, tmp_dir, dest) catch 0;

    // Write HEAD
    const head_src = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{tmp_dir});
    defer allocator.free(head_src);
    if (readFile(io, head_src)) |h| {
        defer allocator.free(h);
        io.makeDir(try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dest})) catch {};
        io.writeFile(try std.fmt.allocPrint(allocator, "{s}/.gitz/HEAD", .{dest}), h) catch {};
    }

    // Write remote
    io.makeDir(try std.fmt.allocPrint(allocator, "{s}/.gitz/remotes", .{dest})) catch {};
    io.writeFile(try std.fmt.allocPrint(allocator, "{s}/.gitz/remotes/origin", .{dest}), url) catch {};

    // Cleanup
    std.Io.Dir.cwd().deleteTree(io.io, tmp_dir) catch {};

    try io.print("Cloned into '{s}'\n", .{dest});
    try io.print("  {d} refs, {d} objects\n", .{ ref_count, object_count });
}

/// Copy all objects from git bare repo to gitz loose format
fn copyObjects(allocator: std.mem.Allocator, io: Io, bare_repo: []const u8, dest: []const u8, count: *u32) !void {
    io.makeDir(try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dest})) catch {};
    io.makeDir(try std.fmt.allocPrint(allocator, "{s}/.gitz/objects", .{dest})) catch {};

    // Get list of ALL objects with their types using git for-each-object or similar
    // Use: git --git-dir <bare> cat-file --batch-all-objects --batch-check
    // This outputs: "<sha> <type> <size>" for each object
    var batch_argv = [_][]const u8{ "git", "--git-dir", bare_repo, "cat-file", "--batch-all-objects", "--batch-check" };

    var batch_child = std.process.spawn(io.io, .{
        .argv = &batch_argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return;

    var batch_output = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    defer batch_output.deinit(allocator);
    readChildOutput(&batch_child, io, &batch_output, allocator);
    _ = batch_child.wait(io.io) catch {};

    // Parse each line: "<sha> <type> <size>"
    var lines = std.mem.splitScalar(u8, batch_output.items, '\n');
    while (lines.next()) |line| {
        if (line.len < 42) continue;

        // Find first space
        const first_space = std.mem.indexOf(u8, line, " ") orelse continue;
        const sha_hex = line[0..first_space];
        if (sha_hex.len != 40) continue;

        const rest = line[first_space + 1 ..];
        const second_space = std.mem.indexOf(u8, rest, " ") orelse continue;
        const obj_type = rest[0..second_space];

        // Now dump the raw object content
        var dump_argv = [_][]const u8{ "git", "--git-dir", bare_repo, "cat-file", obj_type, sha_hex };

        var dump_child = std.process.spawn(io.io, .{
            .argv = &dump_argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch continue;

        var raw_data = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        defer raw_data.deinit(allocator);
        readChildOutput(&dump_child, io, &raw_data, allocator);
        _ = dump_child.wait(io.io) catch {};

        if (raw_data.items.len == 0) continue;

        // Build the gitz loose object: "<type> <size>\0<content>"
        const size_str = std.fmt.allocPrint(allocator, "{d}", .{raw_data.items.len}) catch continue;
        defer allocator.free(size_str);

        var obj_content = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        defer obj_content.deinit(allocator);

        obj_content.appendSlice(allocator, obj_type) catch continue;
        obj_content.append(allocator, ' ') catch continue;
        obj_content.appendSlice(allocator, size_str) catch continue;
        obj_content.append(allocator, 0) catch continue; // null byte
        obj_content.appendSlice(allocator, raw_data.items) catch continue;

        // Compute SHA from the full object content (git-compatible)
        const sha = @import("../../core/sha1.zig").Sha1.hash(obj_content.items);
        const hex = @import("../../core/sha1.zig").Sha1.hex(sha);

        // Ensure parent directory exists
        const prefix_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/objects/{s}", .{ dest, hex[0..2] });
        defer allocator.free(prefix_dir);
        io.makeDir(prefix_dir) catch {};

        const obj_path = try std.fmt.allocPrint(allocator, "{s}/.gitz/objects/{s}/{s}", .{ dest, hex[0..2], hex[2..40] });
        defer allocator.free(obj_path);

        // Compress with zlib for git compatibility
        const compressed = zlib_mod.zlib.compress(allocator, obj_content.items) catch obj_content.items;
        defer if (compressed.ptr != obj_content.items.ptr) allocator.free(compressed);
        io.writeFile(obj_path, compressed) catch {};
        count.* += 1;
    }
}

/// Copy refs from git bare repo to gitz format
fn copyRefs(allocator: std.mem.Allocator, io: Io, bare_repo: []const u8, dest: []const u8) !u32 {
    io.makeDir(try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/heads", .{dest})) catch {};
    io.makeDir(try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/tags", .{dest})) catch {};
    io.makeDir(try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/remotes", .{dest})) catch {};

    var ref_argv = [_][]const u8{ "git", "--git-dir", bare_repo, "show-ref" };

    var ref_child = std.process.spawn(io.io, .{
        .argv = &ref_argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return 0;

    var ref_output = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    defer ref_output.deinit(allocator);
    readChildOutput(&ref_child, io, &ref_output, allocator);
    _ = ref_child.wait(io.io) catch {};

    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, ref_output.items, '\n');
    while (lines.next()) |line| {
        if (line.len < 41) continue;
        if (line[40] != ' ') continue;

        const sha_hex = line[0..40];
        const ref_name = std.mem.trim(u8, line[41..], " \n\r");

        if (std.mem.eql(u8, ref_name, "HEAD")) continue;

        const ref_path = try std.fmt.allocPrint(allocator, "{s}/.gitz/{s}", .{ dest, ref_name });
        defer allocator.free(ref_path);

        // Ensure parent directory exists
        if (std.mem.lastIndexOf(u8, ref_path, "/")) |slash_pos| {
            const parent = ref_path[0..slash_pos];
            io.makeDir(parent) catch {};
        }

        const content = try std.fmt.allocPrint(allocator, "{s}\n", .{sha_hex});
        defer allocator.free(content);
        io.writeFile(ref_path, content) catch {};
        count += 1;
    }

    return count;
}

fn readChildOutput(child: *std.process.Child, io: Io, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) void {
    while (child.stdout) |*s| {
        var read_buf: [65536]u8 = undefined;
        const n = s.readStreaming(io.io, &.{&read_buf}) catch 0;
        if (n == 0) {
            s.close(io.io);
            child.stdout = null;
            break;
        }
        buf.appendSlice(allocator, read_buf[0..n]) catch {};
    }
    while (child.stderr) |*s| {
        s.close(io.io);
        child.stderr = null;
    }
}

fn drainChild(child: *std.process.Child, io: Io) void {
    while (child.stdout) |*s| {
        var buf: [4096]u8 = undefined;
        const n = s.readStreaming(io.io, &.{&buf}) catch 0;
        if (n == 0) {
            s.close(io.io);
            child.stdout = null;
            break;
        }
    }
    while (child.stderr) |*s| {
        s.close(io.io);
        child.stderr = null;
    }
}

fn readFile(io: Io, path: []const u8) ?[]u8 {
    return io.readFileAlloc(path) catch null;
}
