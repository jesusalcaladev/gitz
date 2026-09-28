const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const errors = @import("../errors.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, io: Io) !void {
    var bare = false;
    var quiet = false;
    var initial_branch: []const u8 = "main";
    var target_dir: []const u8 = ".";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--bare")) {
            bare = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            // Single-dash flags used to fall through to `target_dir`, so
            // `gitz init -q` created a repository inside a directory literally
            // named "-q".
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--initial-branch") or
            std.mem.eql(u8, arg, "-b=") or std.mem.eql(u8, arg, "--initial-branch="))
        {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                initial_branch = arg[eq + 1 ..];
            } else {
                if (i + 1 >= args.len) errors.errorf(io, "option '{s}' requires a value", .{arg});
                i += 1;
                initial_branch = args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // Rejecting unknown options is what git does; silently treating
            // them as a directory name is how `-q` created a stray folder.
            errors.errorf(io, "unknown option '{s}'", .{arg});
        } else if (std.mem.eql(u8, target_dir, ".")) {
            target_dir = arg;
        } else {
            errors.errorf(io, "too many arguments", .{});
        }
    }

    if (std.mem.eql(u8, initial_branch, "")) errors.errorf(io, "invalid initial branch name ''", .{});

    // A bare repository keeps the git dir itself at the destination instead of
    // nesting it under `.gitz/`. `--bare` used to be parsed and then ignored,
    // producing a worktree-shaped repository that could not be used as a bare
    // one.
    const dir_root = if (bare) target_dir else null;
    const path_in = struct {
        fn build(gpa: std.mem.Allocator, root: ?[]const u8, rel: []const u8) ![]const u8 {
            const r = root orelse return rel;
            return std.fmt.allocPrint(gpa, "{s}/{s}", .{ r, rel });
        }
    }.build;

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
        const rel = if (dir_root) |r|
            (if (std.mem.eql(u8, r, ".")) d[".gitz/".len..] else blk: {
                break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ r, d[".gitz/".len..] });
            })
        else
            d;
        defer if (dir_root != null) allocator.free(rel);
        try io.makeDir(rel);
    }

    // HEAD
    const head_rel = if (dir_root) |r|
        (if (std.mem.eql(u8, r, ".")) "HEAD" else try std.fmt.allocPrint(allocator, "{s}/HEAD", .{r}))
    else
        ".gitz/HEAD";
    defer if (dir_root != null) allocator.free(head_rel);
    const head_content = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{initial_branch});
    defer allocator.free(head_content);
    try io.writeFile(head_rel, head_content);

    // config
    const config_rel = if (dir_root) |r|
        (if (std.mem.eql(u8, r, ".")) "config" else try std.fmt.allocPrint(allocator, "{s}/config", .{r}))
    else
        ".gitz/config";
    defer if (dir_root != null) allocator.free(config_rel);
    const config_content = try std.fmt.allocPrint(
        allocator,
        "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = {s}\n\tlogallrefupdates = true\n",
        .{if (bare) "true" else "false"},
    );
    defer allocator.free(config_content);
    try io.writeFile(config_rel, config_content);

    // index (empty): "DIRC", version 2, entry count 0, then the trailing
    // SHA-1 over those twelve bytes. A zero trailer made real git reject the
    // file.
    const index_rel = if (dir_root) |r|
        (if (std.mem.eql(u8, r, ".")) "index" else try std.fmt.allocPrint(allocator, "{s}/index", .{r}))
    else
        ".gitz/index";
    defer if (dir_root != null) allocator.free(index_rel);

    var f = try io.createFile(index_rel);
    defer f.close(io.io);
    const empty_index = "DIRC\x00\x00\x00\x02\x00\x00\x00\x00";
    try std.Io.File.writeStreamingAll(f, io.io, empty_index);
    var trailer: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(empty_index, &trailer, .{});
    try std.Io.File.writeStreamingAll(f, io.io, &trailer);

    // description
    const desc_rel = if (dir_root) |r|
        (if (std.mem.eql(u8, r, ".")) "description" else try std.fmt.allocPrint(allocator, "{s}/description", .{r}))
    else
        ".gitz/description";
    defer if (dir_root != null) allocator.free(desc_rel);
    try io.writeFile(desc_rel, "Unnamed repository\n");

    // exclude
    const exclude_rel = if (dir_root) |r|
        (if (std.mem.eql(u8, r, ".")) "info/exclude" else try std.fmt.allocPrint(allocator, "{s}/info/exclude", .{r}))
    else
        ".gitz/info/exclude";
    defer if (dir_root != null) allocator.free(exclude_rel);
    try io.writeFile(exclude_rel, "*.o\n*.a\n*.so\n*.dylib\n.DS_Store\nnode_modules/\n");

    _ = path_in;

    if (quiet) return;
    if (bare) {
        try io.print("Initialized empty Git repository in {s}/\n", .{target_dir});
    } else {
        try io.print("Initialized empty Git repository in {s}/.gitz/\n", .{target_dir});
    }
}
