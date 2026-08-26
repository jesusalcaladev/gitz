const std = @import("std");
const testing = std.testing;

/// Integration tests for GitZ new commands: show, diff branch, clean, shortlog, worktree
const GitzTest = struct {
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    gitz_bin: []const u8,

    fn init(allocator: std.mem.Allocator, test_name: []const u8) !GitzTest {
        const dir_path = try std.fmt.allocPrint(allocator, "/tmp/gitz_e2e_{s}", .{test_name});
        std.posix.mkdir(dir_path, 0o755) catch {};
        return .{
            .allocator = allocator,
            .dir_path = dir_path,
            .gitz_bin = "zig-out/bin/gitz",
        };
    }

    fn deinit(self: *GitzTest) void {
        self.removeTree(self.dir_path) catch {};
        self.allocator.free(self.dir_path);
    }

    fn removeTree(self: *GitzTest, path: []const u8) !void {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "rm", "-rf", path },
            .cwd = "/",
        });
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
    }

    fn run(self: *GitzTest, args: []const []const u8) !struct { stdout: []const u8, stderr: []const u8, term: std.process.Child.Term } {
        var argv = std.ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.append(self.gitz_bin);
        for (args) |arg| {
            try argv.append(arg);
        }
        return try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
            .cwd = self.dir_path,
        });
    }

    fn writeFile(self: *GitzTest, path: []const u8, content: []const u8) !void {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir_path, path });
        defer self.allocator.free(full_path);
        const file = try std.fs.cwd().createFile(full_path, .{});
        defer file.close();
        try file.writeAll(content);
    }
};

// ============================================================
// gitz show tests
// ============================================================

test "show: displays commit details" {
    var t = try GitzTest.init(testing.allocator, "show_commit");
    defer t.deinit();
    _ = try t.run(&.{ "init" });
    try t.writeFile("test.txt", "hello world");
    _ = try t.run(&.{ "add", "test.txt" });
    const result = try t.run(&.{ "commit", "-m", "initial commit" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    // Verify commit message appears
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "initial commit"));
}

test "show: displays HEAD by default" {
    var t = try GitzTest.init(testing.allocator, "show_head");
    defer t.deinit();
    _ = try t.run(&.{ "init" });
    try t.writeFile("file.txt", "content");
    _ = try t.run(&.{ "add", "file.txt" });
    _ = try t.run(&.{ "commit", "-m", "first" });
    const result = try t.run(&.{ "show" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "first"));
}

test "show: --stat shows file stats" {
    var t = try GitzTest.init(testing.allocator, "show_stat");
    defer t.deinit();
    _ = try t.run(&.{ "init" });
    try t.writeFile("code.zig", "const x = 1;\n");
    _ = try t.run(&.{ "add", "code.zig" });
    _ = try t.run(&.{ "commit", "-m", "add code" });
    const result = try t.run(&.{ "show", "--stat" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "code.zig"));
}

// ============================================================
// gitz diff branch tests
// ============================================================

test "diff: branch to branch comparison" {
    var t = try GitzTest.init(testing.allocator, "diff_branch");
    defer t.deinit();
    _ = try t.run(&.{ "init" });
    try t.writeFile("base.txt", "base content\n");
    _ = try t.run(&.{ "add", "base.txt" });
    _ = try t.run(&.{ "commit", "-m", "base commit" });
    _ = try t.run(&.{ "switch", "-c", "feature" });
    try t.writeFile("feature.txt", "feature content\n");
    _ = try t.run(&.{ "add", "feature.txt" });
    _ = try t.run(&.{ "commit", "-m", "feature commit" });
    _ = try t.run(&.{ "switch", "main" });
    const result = try t.run(&.{ "diff", "main..feature" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    // Should show the new file
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "feature.txt"));
}

test "diff: no changes shows message" {
    var t = try GitzTest.init(testing.allocator, "diff_no_change");
    defer t.deinit();
    _ = try t.run(&.{ "init" });
    try t.writeFile("file.txt", "content\n");
    _ = try t.run(&.{ "add", "file.txt" });
    _ = try t.run(&.{ "commit", "-m", "initial" });
    _ = try t.run(&.{ "switch", "-c", "other" });
    _ = try t.run(&.{ "switch", "main" });
    const result = try t.run(&.{ "diff", "main..other" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "No changes"));
}

// ============================================================
// gitz clean tests
// ============================================================

test "clean: dry run shows files" {
    var t = try GitzTest.init(testing.allocator, "clean_dryrun");
    defer t.deinit();
    _ = try t.run(&.{ "init" });
    try t.writeFile("tracked.txt", "tracked");
    _ = try t.run(&.{ "add", "tracked.txt" });
    _ = try t.run(&.{ "commit", "-m", "tracked" });
    try t.writeFile("untracked.txt", "untracked");
    const result = try t.run(&.{ "clean", "-n" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Would remove"));
}

test "clean: force removes files" {
    var t = try GitzTest.init(testing.allocator, "clean_force");
    defer t.deinit();
    _ = try t.run(&.{ "init" });
    try t.writeFile("tracked.txt", "tracked");
    _ = try t.run(&.{ "add", "tracked.txt" });
    _ = try t.run(&.{ "commit", "-m", "tracked" });
    try t.writeFile("junk.txt", "junk file");
    const result = try t.run(&.{ "clean", "-f" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    // Check file was removed
    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/junk.txt", .{t.dir_path});
    defer testing.allocator.free(full_path);
    const exists = if (std.fs.cwd().openFile(full_path, .{})) |f| {
        f.close();
        true;
    } else |_| false;
    try testing.expect(!exists);
}

// ============================================================
// gitz shortlog tests
// ============================================================

test "shortlog: shows author summary" {
    var t = try GitzTest.init(testing.allocator, "shortlog_basic");
    defer t.deinit();
    _ = try t.run(&.{ "init" });
    try t.writeFile("file1.txt", "content1");
    _ = try t.run(&.{ "add", "file1.txt" });
    _ = try t.run(&.{ "commit", "-m", "first commit" });
    try t.writeFile("file2.txt", "content2");
    _ = try t.run(&.{ "add", "file2.txt" });
    _ = try t.run(&.{ "commit", "-m", "second commit" });
    const result = try t.run(&.{ "shortlog" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    // Should show commit count
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "2"));
}

test "shortlog: -s shows summary only" {
    var t = try GitzTest.init(testing.allocator, "shortlog_summary");
    defer t.deinit();
    _ = try t.run(&.{ "init" });
    try t.writeFile("file.txt", "content");
    _ = try t.run(&.{ "add", "file.txt" });
    _ = try t.run(&.{ "commit", "-m", "commit message" });
    const result = try t.run(&.{ "shortlog", "-s" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    // Should have the count
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "1"));
}

// ============================================================
// gitz worktree tests
// ============================================================

test "worktree: add and list" {
    var t = try GitzTest.init(testing.allocator, "worktree_add");
    defer t.deinit();
    _ = try t.run(&.{ "init" });
    try t.writeFile("main.txt", "main content");
    _ = try t.run(&.{ "add", "main.txt" });
    _ = try t.run(&.{ "commit", "-m", "initial" });

    // Create worktree
    const add_result = try t.run(&.{ "worktree", "add", "feature-wt" });
    defer {
        testing.allocator.free(add_result.stdout);
        testing.allocator.free(add_result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, add_result.stdout, 1, "created"));

    // List worktrees
    const list_result = try t.run(&.{ "worktree", "list" });
    defer {
        testing.allocator.free(list_result.stdout);
        testing.allocator.free(list_result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, list_result.stdout, 1, "feature-wt"));
}

test "worktree: remove" {
    var t = try GitzTest.init(testing.allocator, "worktree_remove");
    defer t.deinit();
    _ = try t.run(&.{ "init" });
    try t.writeFile("main.txt", "main");
    _ = try t.run(&.{ "add", "main.txt" });
    _ = try t.run(&.{ "commit", "-m", "initial" });
    _ = try t.run(&.{ "worktree", "add", "temp-wt" });

    // Remove worktree
    const result = try t.run(&.{ "worktree", "remove", "temp-wt" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "removed"));
}

test "worktree: add with new branch" {
    var t = try GitzTest.init(testing.allocator, "worktree_branch");
    defer t.deinit();
    _ = try t.run(&.{ "init" });
    try t.writeFile("file.txt", "content");
    _ = try t.run(&.{ "add", "file.txt" });
    _ = try t.run(&.{ "commit", "-m", "initial" });

    // Create worktree with new branch
    const result = try t.run(&.{ "worktree", "add", "-b", "new-feature", "feature-dir" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Created branch"));
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "created"));
}

// ============================================================
// Monorepo support tests
// ============================================================

test "monorepo: works from subdirectory" {
    var t = try GitzTest.init(testing.allocator, "monorepo_subdir");
    defer t.deinit();
    _ = try t.run(&.{ "init" });
    try t.writeFile("root.txt", "root content");
    _ = try t.run(&.{ "add", "root.txt" });
    _ = try t.run(&.{ "commit", "-m", "root commit" });

    // Create subdirectory
    const sub_dir = try std.fmt.allocPrint(testing.allocator, "{s}/packages/app", .{t.dir_path});
    defer testing.allocator.free(sub_dir);
    std.posix.mkdir(sub_dir, 0o755) catch {};
    std.posix.mkdir(try std.fmt.allocPrint(testing.allocator, "{s}/packages", .{t.dir_path}), 0o755) catch {};
    std.posix.mkdir(sub_dir, 0o755) catch {};

    // Write file in subdirectory
    const sub_file = try std.fmt.allocPrint(testing.allocator, "{s}/app.txt", .{sub_dir});
    defer testing.allocator.free(sub_file);
    const file = try std.fs.cwd().createFile(sub_file, .{});
    defer file.close();
    try file.writeAll("app content");

    // Run gitz from subdirectory - should find .gitz in parent
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append(t.gitz_bin);
    try argv.append("status");

    const result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = argv.items,
        .cwd = sub_dir,
    });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }

    // Should find the repo and show status
    // (untracked file in subdirectory)
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Untracked"));
}

test "monorepo: multiple nested repos" {
    var t = try GitzTest.init(testing.allocator, "monorepo_nested");
    defer t.deinit();

    // Create main repo
    _ = try t.run(&.{ "init" });
    try t.writeFile("workspace.txt", "workspace");
    _ = try t.run(&.{ "add", "workspace.txt" });
    _ = try t.run(&.{ "commit", "-m", "workspace init" });

    // Create a nested package with its own .gitz
    const pkg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/packages/core", .{t.dir_path});
    defer testing.allocator.free(pkg_dir);
    std.posix.mkdir(try std.fmt.allocPrint(testing.allocator, "{s}/packages", .{t.dir_path}), 0o755) catch {};
    std.posix.mkdir(pkg_dir, 0o755) catch {};

    // Initialize nested repo
    var init_argv = std.ArrayList([]const u8).init(testing.allocator);
    defer init_argv.deinit();
    try init_argv.append(t.gitz_bin);
    try init_argv.append("init");

    const init_result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = init_argv.items,
        .cwd = pkg_dir,
    });
    defer {
        testing.allocator.free(init_result.stdout);
        testing.allocator.free(init_result.stderr);
    }

    // Should find nested .gitz
    const gitz_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.gitz", .{pkg_dir});
    defer testing.allocator.free(gitz_dir);
    const exists = if (std.fs.cwd().openDir(gitz_dir, .{})) |d| {
        d.close();
        true;
    } else |_| false;
    try testing.expect(exists);
}
