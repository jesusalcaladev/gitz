const std = @import("std");
const testing = std.testing;
const Sha1 = @import("sha1.zig").Sha1;

const Allocator = std.mem.Allocator;

pub const StashEntry = struct {
    sha: [20]u8,
    message: []const u8,
    branch: []const u8,
    index: u32,
};

pub const Stash = struct {
    allocator: Allocator,
    git_dir: []const u8,
    io: std.Io,

    pub fn init(allocator: Allocator, git_dir: []const u8, io: std.Io) Stash {
        return .{
            .allocator = allocator,
            .git_dir = git_dir,
            .io = io,
        };
    }

    fn stashPath(self: Stash) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}/refs/stash", .{self.git_dir});
    }

    pub fn save(self: Stash, message: ?[]const u8) !StashEntry {
        const msg = if (message) |m|
            try self.allocator.dupe(u8, m)
        else
            try self.allocator.dupe(u8, "WIP on (no branch)");

        var sha_buf: [64]u8 = undefined;
        const ts_str = try std.fmt.bufPrint(&sha_buf, "stash:{s}", .{msg});
        const sha = Sha1.hash(ts_str);

        const stash_path = try self.stashPath();
        defer self.allocator.free(stash_path);

        // Write new entry
        var file = std.Io.Dir.cwd().createFile(self.io, stash_path, .{}) catch |e| {
            if (e == error.FileNotFound) {
                // Ensure dir exists
                std.Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(stash_path) orelse ".") catch {};
                var f = try std.Io.Dir.cwd().createFile(self.io, stash_path, .{});
                f.close(self.io);
                return self.save(message);
            }
            return e;
        };
        defer file.close(self.io);

        const hex = Sha1.hex(sha);
        var line_buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "{s} {s}\n", .{ &hex, msg });
        try std.Io.File.writeStreamingAll(file, self.io, line);

        return StashEntry{
            .sha = sha,
            .message = msg,
            .branch = try self.allocator.dupe(u8, "(no branch)"),
            .index = 0,
        };
    }

    pub fn list(self: Stash) ![]StashEntry {
        const stash_path = try self.stashPath();
        defer self.allocator.free(stash_path);

        const content = std.Io.Dir.cwd().readFileAlloc(self.io, stash_path, self.allocator, .unlimited) catch {
            return try self.allocator.alloc(StashEntry, 0);
        };
        defer self.allocator.free(content);

        var entries = std.ArrayList(StashEntry){ .items = &.{}, .capacity = 0 };
        errdefer {
            for (entries.items) |e| {
                self.allocator.free(e.message);
                self.allocator.free(e.branch);
            }
            entries.deinit(self.allocator);
        }

        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, content, "\n"), '\n');
        var index: u32 = 0;
        while (lines.next()) |line| {
            if (line.len < 41) continue;
            const hex = line[0..40];
            const sha = Sha1.fromHex(hex) catch continue;
            const msg = try self.allocator.dupe(u8, line[41..]);
            try entries.append(self.allocator, .{
                .sha = sha,
                .message = msg,
                .branch = try self.allocator.dupe(u8, "(no branch)"),
                .index = index,
            });
            index += 1;
        }

        std.mem.reverse(StashEntry, entries.items);
        for (entries.items, 0..) |*e, i| {
            e.index = @intCast(i);
        }

        return try entries.toOwnedSlice(self.allocator);
    }

    pub fn count(self: Stash) u32 {
        const entries = self.list() catch return 0;
        const c: u32 = @intCast(entries.len);
        for (entries) |e| {
            self.allocator.free(e.message);
            self.allocator.free(e.branch);
        }
        self.allocator.free(entries);
        return c;
    }

    pub fn drop(self: Stash, index: u32) !void {
        const entries = try self.list();
        defer {
            for (entries) |e| {
                self.allocator.free(e.message);
                self.allocator.free(e.branch);
            }
            self.allocator.free(entries);
        }

        if (index >= entries.len) return error.StashIndexInvalid;

        const stash_path = try self.stashPath();
        defer self.allocator.free(stash_path);

        var file = try std.Io.Dir.cwd().createFile(self.io, stash_path, .{});
        defer file.close(self.io);

        const file_index = entries.len - 1 - index;
        for (entries, 0..) |entry, i| {
            if (i == file_index) continue;
            const hex = Sha1.hex(entry.sha);
            var line_buf: [128]u8 = undefined;
            const line = try std.fmt.bufPrint(&line_buf, "{s} {s}\n", .{ &hex, entry.message });
            try std.Io.File.writeStreamingAll(file, self.io, line);
        }
    }

    pub fn clear(self: Stash) !void {
        const stash_path = try self.stashPath();
        defer self.allocator.free(stash_path);
        std.Io.Dir.cwd().deleteFile(self.io, stash_path) catch {};
    }
};
