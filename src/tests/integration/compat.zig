const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;

/// Integration tests for GitZ ↔ Git compatibility.
const GitzTest = struct {
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    gitz_bin: []const u8,

    fn init(allocator: std.mem.Allocator, test_name: []const u8) !GitzTest {
        const dir_path = try std.fmt.allocPrint(allocator, "/tmp/gitz_compat_{s}", .{test_name});
        _ = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "rm", "-rf", dir_path },
        }) catch .{ .stdout = &.{}, .stderr = &.{}, .term = .{ .Exited = 0 } };
        _ = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "mkdir", "-p", dir_path },
        }) catch .{ .stdout = &.{}, .stderr = &.{}, .term = .{ .Exited = 0 } };
        return .{
            .allocator = allocator,
            .dir_path = dir_path,
            .gitz_bin = "zig-out/bin/gitz",
        };
    }

    fn deinit(self: *GitzTest) void {
        _ = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "rm", "-rf", self.dir_path },
        }) catch {};
        self.allocator.free(self.dir_path);
    }

    fn run(self: *GitzTest, args: []const []const u8) !struct { stdout: []u8, stderr: []u8, exit_code: u32 } {
        var argv = std.ArrayList([]const u8).empty;
        try argv.append(self.allocator, self.gitz_bin);
        for (args) |arg| try argv.append(self.allocator, arg);
        defer argv.deinit(self.allocator);

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
            .cwd = self.dir_path,
        }) catch return .{ .stdout = &.{}, .stderr = &.{}, .exit_code = 1 };

        const exit_code: u32 = switch (result.term) {
            .Exited => |code| code,
            else => 1,
        };

        return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = exit_code };
    }

    fn runGit(self: *GitzTest, args: []const []const u8) !struct { stdout: []u8, stderr: []u8, exit_code: u32 } {
        var argv = std.ArrayList([]const u8).empty;
        try argv.append(self.allocator, "git");
        for (args) |arg| try argv.append(self.allocator, arg);
        defer argv.deinit(self.allocator);

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
            .cwd = self.dir_path,
        }) catch return .{ .stdout = &.{}, .stderr = &.{}, .exit_code = 1 };

        const exit_code: u32 = switch (result.term) {
            .Exited => |code| code,
            else => 1,
        };

        return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = exit_code };
    }

    fn writeFile(self: *GitzTest, path: []const u8, content: []const u8) !void {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir_path, path });
        defer self.allocator.free(full_path);
        const fd = try std.posix.openat(std.posix.AT.FDCWD, full_path, .{ .ACCMODE = .WRONLY, .CREAT = .{}, .TRUNC = .{} }, 0o644);
        defer _ = linux.close(@intCast(fd));
        var remaining = content;
        while (remaining.len > 0) {
            const n = linux.write(@intCast(fd), remaining.ptr, remaining.len);
            if (n == 0 or n > remaining.len) break;
            remaining = remaining[n..];
        }
    }
};
