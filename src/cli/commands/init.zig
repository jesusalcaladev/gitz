const std = @import("std");
const Io = @import("../../util/io.zig").Io;

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, io: Io) !void {
    var bare = false;
    var target_dir: []const u8 = ".";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--bare")) {
            bare = true;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            try io.eprint("error: unknown option '{s}'\n", .{args[i]});
            std.process.exit(1);
        } else {
            target_dir = args[i];
        }
    }

    // Create all required directories
    const dirs = [_][]const u8{
        ".gitz/objects",
        ".gitz/refs/heads",
        ".gitz/refs/tags",
        ".gitz/refs/remotes",
        ".gitz/info",
        ".gitz/hooks",
    };
    for (dirs) |d| {
        const path = if (std.mem.eql(u8, target_dir, "."))
            d
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ target_dir, d });
        defer if (!std.mem.eql(u8, target_dir, ".")) allocator.free(path);
        try io.makeDir(path);
    }

    // HEAD
    const head_path = if (std.mem.eql(u8, target_dir, "."))
        ".gitz/HEAD"
    else
        try std.fmt.allocPrint(allocator, "{s}/.gitz/HEAD", .{target_dir});
    defer if (!std.mem.eql(u8, target_dir, ".")) allocator.free(head_path);
    try io.writeFile(head_path, "ref: refs/heads/main\n");

    // config
    const config_path = if (std.mem.eql(u8, target_dir, "."))
        ".gitz/config"
    else
        try std.fmt.allocPrint(allocator, "{s}/.gitz/config", .{target_dir});
    defer if (!std.mem.eql(u8, target_dir, ".")) allocator.free(config_path);
    try io.writeFile(config_path, "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n");

    // index (empty)
    const index_path = if (std.mem.eql(u8, target_dir, "."))
        ".gitz/index"
    else
        try std.fmt.allocPrint(allocator, "{s}/.gitz/index", .{target_dir});
    defer if (!std.mem.eql(u8, target_dir, ".")) allocator.free(index_path);

    var f = try io.createFile(index_path);
    defer f.close(io.io);
    try std.Io.File.writeStreamingAll(f, io.io, "DIRC");
    // Write version (2) and count (0) as big-endian u32
    try std.Io.File.writeStreamingAll(f, io.io, &[_]u8{ 0, 0, 0, 2 });
    try std.Io.File.writeStreamingAll(f, io.io, &[_]u8{ 0, 0, 0, 0 });

    // description
    const desc_path = if (std.mem.eql(u8, target_dir, "."))
        ".gitz/description"
    else
        try std.fmt.allocPrint(allocator, "{s}/.gitz/description", .{target_dir});
    defer if (!std.mem.eql(u8, target_dir, ".")) allocator.free(desc_path);
    try io.writeFile(desc_path, "Unnamed repository\n");

    // exclude
    const exclude_path = if (std.mem.eql(u8, target_dir, "."))
        ".gitz/info/exclude"
    else
        try std.fmt.allocPrint(allocator, "{s}/.gitz/info/exclude", .{target_dir});
    defer if (!std.mem.eql(u8, target_dir, ".")) allocator.free(exclude_path);
    try io.writeFile(exclude_path, "*.o\n*.a\n*.so\n*.dylib\n.DS_Store\nnode_modules/\n");

    try io.print("Initialized empty Git repository in {s}/.gitz/\n", .{target_dir});
}
