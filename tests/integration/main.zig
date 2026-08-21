const std = @import("std");
const testing = std.testing;

/// Integration tests for GitZ core workflow.
/// Each test creates a temp directory, runs gitz commands, and verifies results.
const GitzTest = struct {
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    gitz_bin: []const u8,

    fn init(allocator: std.mem.Allocator, test_name: []const u8) !GitzTest {
        const dir_path = try std.fmt.allocPrint(allocator, "/tmp/gitz_test_{s}", .{test_name});

        // Create temp directory
        std.posix.mkdir(dir_path, 0o755) catch {};

        return .{
            .allocator = allocator,
            .dir_path = dir_path,
            .gitz_bin = "zig-out/bin/gitz",
        };
    }

    fn deinit(self: *GitzTest) void {
        // Clean up: remove temp directory
        self.removeTree(self.dir_path) catch {};
        self.allocator.free(self.dir_path);
    }

    fn removeTree(self: *GitzTest, path: []const u8) !void {
        // Use system rm -rf for simplicity
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

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
            .cwd = self.dir_path,
        });

        return result;
    }

    fn writeFile(self: *GitzTest, path: []const u8, content: []const u8) !void {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir_path, path });
        defer self.allocator.free(full_path);

        const file = try std.fs.cwd().createFile(full_path, .{});
        defer file.close();

        try file.writeAll(content);
    }

    fn readFile(self: *GitzTest, path: []const u8) ![]const u8 {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir_path, path });
        defer self.allocator.free(full_path);

        const file = try std.fs.cwd().openFile(full_path, .{});
        defer file.close();

        return try file.readToEndAlloc(self.allocator, 1024 * 1024);
    }
};

test "init creates .gitz directory" {
    var t = try GitzTest.init(testing.allocator, "init");
    defer t.deinit();

    const result = try t.run(&.{"init"});
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }

    // Check that .gitz directory exists
    const gitz_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.gitz", .{t.dir_path});
    defer testing.allocator.free(gitz_dir);

    const stat = std.fs.cwd().statFile(gitz_dir) catch {
        try testing.expect(false); // .gitz directory should exist
        return;
    };
    try testing.expect(stat.kind == .directory);
}

test "add and commit" {
    var t = try GitzTest.init(testing.allocator, "add_commit");
    defer t.deinit();

    // Init
    var result = try t.run(&.{"init"});
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }

    // Create file
    try t.writeFile("test.txt", "hello world");

    // Add file
    result = try t.run(&.{ "add", "test.txt" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "add: test.txt"));

    // Commit
    result = try t.run(&.{ "commit", "-m", "initial commit" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "initial commit"));
}

test "log shows commits" {
    var t = try GitzTest.init(testing.allocator, "log");
    defer t.deinit();

    // Init, add, commit
    _ = try t.run(&.{"init"});
    try t.writeFile("test.txt", "hello");
    _ = try t.run(&.{ "add", "test.txt" });
    _ = try t.run(&.{ "commit", "-m", "first commit" });

    // Log
    const result = try t.run(&.{ "log", "--oneline" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }

    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "first commit"));
}

test "branch create and list" {
    var t = try GitzTest.init(testing.allocator, "branch");
    defer t.deinit();

    // Init, add, commit
    _ = try t.run(&.{"init"});
    try t.writeFile("test.txt", "hello");
    _ = try t.run(&.{ "add", "test.txt" });
    _ = try t.run(&.{ "commit", "-m", "initial" });

    // Create branch
    var result = try t.run(&.{ "branch", "feature" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Created branch 'feature'"));

    // List branches
    result = try t.run(&.{"branch"});
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "feature"));
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "main"));
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "*")); // Current branch marker
}

test "switch creates and switches branch" {
    var t = try GitzTest.init(testing.allocator, "switch");
    defer t.deinit();

    // Init, add, commit
    _ = try t.run(&.{"init"});
    try t.writeFile("test.txt", "hello");
    _ = try t.run(&.{ "add", "test.txt" });
    _ = try t.run(&.{ "commit", "-m", "initial" });

    // Switch to new branch
    const result = try t.run(&.{ "switch", "-c", "my-branch" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Switched to a new branch 'my-branch'"));

    // Verify current branch
    const status = try t.run(&.{"status"});
    defer {
        testing.allocator.free(status.stdout);
        testing.allocator.free(status.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, status.stdout, 1, "my-branch"));
}

test "diff shows unstaged changes" {
    var t = try GitzTest.init(testing.allocator, "diff");
    defer t.deinit();

    // Init, add, commit
    _ = try t.run(&.{"init"});
    try t.writeFile("test.txt", "original content");
    _ = try t.run(&.{ "add", "test.txt" });
    _ = try t.run(&.{ "commit", "-m", "initial" });

    // Modify file
    try t.writeFile("test.txt", "modified content");

    // Diff
    const result = try t.run(&.{"diff"});
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }

    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "diff a/test.txt"));
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "-original content"));
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "+modified content"));
}

test "tag create and list" {
    var t = try GitzTest.init(testing.allocator, "tag");
    defer t.deinit();

    // Init, add, commit
    _ = try t.run(&.{"init"});
    try t.writeFile("test.txt", "hello");
    _ = try t.run(&.{ "add", "test.txt" });
    _ = try t.run(&.{ "commit", "-m", "initial" });

    // Create tag
    var result = try t.run(&.{ "tag", "v1.0" });
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Created tag 'v1.0'"));

    // List tags
    result = try t.run(&.{"tag"});
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "v1.0"));
}

test "full workflow" {
    var t = try GitzTest.init(testing.allocator, "full_workflow");
    defer t.deinit();

    // Init
    _ = try t.run(&.{"init"});

    // Create files
    try t.writeFile("hello.txt", "hello world");
    try t.writeFile("readme.md", "# My Project");

    // Add all
    const add_result = try t.run(&.{ "add", "." });
    defer {
        testing.allocator.free(add_result.stdout);
        testing.allocator.free(add_result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, add_result.stdout, 1, "add:"));

    // Commit
    _ = try t.run(&.{ "commit", "-m", "initial commit" });

    // Verify log
    const log_result = try t.run(&.{ "log", "--oneline" });
    defer {
        testing.allocator.free(log_result.stdout);
        testing.allocator.free(log_result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, log_result.stdout, 1, "initial commit"));

    // Create branch and switch
    _ = try t.run(&.{ "switch", "-c", "feature" });

    // Modify file
    try t.writeFile("hello.txt", "hello modified");

    // Diff
    const diff_result = try t.run(&.{"diff"});
    defer {
        testing.allocator.free(diff_result.stdout);
        testing.allocator.free(diff_result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, diff_result.stdout, 1, "+hello modified"));

    // Add and commit on feature branch
    _ = try t.run(&.{ "add", "hello.txt" });
    _ = try t.run(&.{ "commit", "-m", "feature commit" });

    // Tag
    _ = try t.run(&.{ "tag", "v1.0.0" });

    // Verify everything
    const final_log = try t.run(&.{ "log", "--oneline" });
    defer {
        testing.allocator.free(final_log.stdout);
        testing.allocator.free(final_log.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, final_log.stdout, 1, "feature commit"));
    try testing.expect(std.mem.containsAtLeast(u8, final_log.stdout, 1, "initial commit"));

    const tag_result = try t.run(&.{"tag"});
    defer {
        testing.allocator.free(tag_result.stdout);
        testing.allocator.free(tag_result.stderr);
    }
    try testing.expect(std.mem.containsAtLeast(u8, tag_result.stdout, 1, "v1.0.0"));
}
