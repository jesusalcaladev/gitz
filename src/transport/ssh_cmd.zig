const std = @import("std");
const Sha1 = @import("../core/sha1.zig").Sha1;
const storage_mod = @import("../core/storage.zig");
const object = @import("../core/object.zig");
const packfile_mod = @import("../core/packfile.zig");
const zlib_mod = @import("../core/zlib.zig");

const Allocator = std.mem.Allocator;

/// SSH transport using system ssh command
pub const SshTransport = struct {
    allocator: Allocator,
    io: std.Io,
    url: []const u8,
    host: []const u8,
    path: []const u8,

    pub fn init(allocator: Allocator, io: std.Io, url: []const u8) !SshTransport {
        const parsed = try parseSshUrl(allocator, url);
        return .{
            .allocator = allocator,
            .io = io,
            .url = url,
            .host = parsed.host,
            .path = parsed.path,
        };
    }

    pub fn deinit(self: *SshTransport) void {
        _ = self;
    }

    /// Discover refs via SSH
    pub fn discoverRefs(self: *SshTransport) ![]RemoteRef {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "ssh");
        try argv.append(self.allocator, "-T");
        try argv.append(self.allocator, "-o");
        try argv.append(self.allocator, "BatchMode=yes");
        try argv.append(self.allocator, self.host);
        try argv.append(self.allocator, "git-upload-pack");
        try argv.append(self.allocator, "--hierarchical-refsets");
        try argv.append(self.allocator, self.path);

        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv.items,
        }) catch return error.SshError;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        var refs = std.ArrayList(RemoteRef).empty;
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len >= 41 and line[40] == ' ') {
                const sha_hex = line[0..40];
                const name = std.mem.trim(u8, line[41..], &[_]u8{ '\n', '\r', ' ' });
                if (name.len > 0) {
                    const sha = Sha1.fromHex(sha_hex) catch continue;
                    try refs.append(self.allocator, .{
                        .name = try self.allocator.dupe(u8, name),
                        .sha = sha,
                    });
                }
            }
        }

        return try refs.toOwnedSlice(self.allocator);
    }

    /// Fetch objects via SSH
    pub fn fetch(self: *SshTransport, git_dir: []const u8, refs: []RemoteRef, have_shas: []const [20]u8) !void {
        // Build wants/haves input for git-upload-pack
        var input = std.ArrayList(u8).empty;
        defer input.deinit(self.allocator);

        for (refs) |ref| {
            const hex = Sha1.hex(ref.sha);
            try input.appendSlice(self.allocator, "want ");
            try input.appendSlice(self.allocator, &hex);
            try input.appendSlice(self.allocator, "\n");
        }

        for (have_shas) |sha| {
            const hex = Sha1.hex(sha);
            try input.appendSlice(self.allocator, "have ");
            try input.appendSlice(self.allocator, &hex);
            try input.appendSlice(self.allocator, "\n");
        }

        try input.appendSlice(self.allocator, "done\n");

        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "ssh");
        try argv.append(self.allocator, "-T");
        try argv.append(self.allocator, self.host);
        try argv.append(self.allocator, "git-upload-pack");
        try argv.append(self.allocator, self.path);

        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv.items,
        }) catch return error.SshError;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        try self.parsePackfile(git_dir, result.stdout);
    }

    /// Push objects via SSH
    pub fn push(self: *SshTransport, git_dir: []const u8, ref_name: []const u8, sha: [20]u8, old_sha: ?[20]u8) !void {
        const new_hex = Sha1.hex(sha);
        const old_hex: [40]u8 = if (old_sha) |os| Sha1.hex(os) else [_]u8{'0'} ** 40;
        const cmd = try std.fmt.allocPrint(self.allocator, "{s} {s} refs/heads/{s}\n", .{ &old_hex, &new_hex, ref_name });
        defer self.allocator.free(cmd);
        _ = try self.collectPushObjects(git_dir, sha, old_sha);

        const objects = try self.collectPushObjects(git_dir, sha, null);
        defer self.allocator.free(objects);

        var pw = packfile_mod.PackWriter.init(self.allocator);
        defer pw.deinit();
        try pw.writeHeader(2, @intCast(objects.len));

        const store = storage_mod.StorageBackend.fromRepoConfig(self.allocator, self.io, git_dir);
        for (objects) |obj_sha| {
            const obj = store.read(self.allocator, self.io, obj_sha) catch continue;
            const serialized = try obj.serialize(self.allocator);
            defer self.allocator.free(serialized);

            const null_pos = std.mem.indexOfScalar(u8, serialized, 0) orelse 0;
            const content = serialized[null_pos + 1 ..];

            const pot: packfile_mod.ObjectType = switch (obj) {
                .blob => .blob,
                .tree => .tree,
                .commit => .commit,
                .tag => .tag,
            };
            try pw.writeObject(pot, obj_sha, content);
        }
        try pw.finalize();

        var full_input = std.ArrayList(u8).empty;
        defer full_input.deinit(self.allocator);
        try full_input.appendSlice(self.allocator, cmd);
        try full_input.appendSlice(self.allocator, pw.getPackData());

        // Use std.process.spawn to pipe stdin for push data
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "ssh");
        try argv.append(self.allocator, "-T");
        try argv.append(self.allocator, self.host);
        try argv.append(self.allocator, "git-receive-pack");
        try argv.append(self.allocator, self.path);

        var child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch return error.SshError;

        // Write the push data to stdin and close it
        if (child.stdin) |*stdin| {
            std.Io.File.writeStreamingAll(stdin.*, self.io, full_input.items) catch {
                return error.SshError;
            };
            stdin.close(self.io);
            child.stdin = null;
        }

        // Wait for the child process to finish
        _ = child.wait(self.io) catch {};
    }

    /// Collect objects reachable from sha but not from old_sha
    fn collectPushObjects(self: *SshTransport, git_dir: []const u8, new_sha: [20]u8, old_sha: ?[20]u8) ![][20]u8 {
        const store = storage_mod.StorageBackend.fromRepoConfig(self.allocator, self.io, git_dir);

        var visited = std.AutoHashMap([20]u8, void).init(self.allocator);
        defer visited.deinit();

        var queue = std.ArrayList([20]u8).empty;
        defer queue.deinit(self.allocator);

        if (old_sha) |old| {
            try self.markReachable(store, &visited, old);
        }

        try queue.append(self.allocator, new_sha);
        while (queue.items.len > 0) {
            const sha = queue.pop().?;
            if (visited.contains(sha)) continue;
            try visited.put(sha, {});

            const obj = store.read(self.allocator, self.io, sha) catch continue;
            switch (obj) {
                .commit => |c| {
                    try queue.append(self.allocator, c.tree);
                    for (c.parents) |p| try queue.append(self.allocator, p);
                },
                .tree => |t| {
                    for (t.entries) |e| try queue.append(self.allocator, e.sha);
                },
                .tag => |tg| {
                    try queue.append(self.allocator, tg.object);
                },
                .blob => {},
            }
        }

        var result = std.ArrayList([20]u8).empty;
        var old_set = std.AutoHashMap([20]u8, void).init(self.allocator);
        defer old_set.deinit();

        if (old_sha) |old| {
            try self.markReachable(store, &old_set, old);
        }

        var iter = visited.iterator();
        while (iter.next()) |entry| {
            if (!old_set.contains(entry.key_ptr.*)) {
                try result.append(self.allocator, entry.key_ptr.*);
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn markReachable(self: *SshTransport, store: storage_mod.StorageBackend, visited: *std.AutoHashMap([20]u8, void), start_sha: [20]u8) !void {
        var queue = std.ArrayList([20]u8).empty;
        defer queue.deinit(self.allocator);
        try queue.append(self.allocator, start_sha);

        while (queue.items.len > 0) {
            const sha = queue.pop().?;
            if (visited.contains(sha)) continue;
            try visited.put(sha, {});

            const obj = store.read(self.allocator, self.io, sha) catch continue;
            switch (obj) {
                .commit => |c| {
                    try queue.append(self.allocator, c.tree);
                    for (c.parents) |p| try queue.append(self.allocator, p);
                },
                .tree => |t| {
                    for (t.entries) |e| try queue.append(self.allocator, e.sha);
                },
                .tag => |tg| {
                    try queue.append(self.allocator, tg.object);
                },
                .blob => {},
            }
        }
    }

    /// Parse packfile from SSH output
    fn parsePackfile(self: *SshTransport, git_dir: []const u8, data: []const u8) !void {
        var pos: usize = 0;
        while (pos + 4 <= data.len) {
            if (std.mem.eql(u8, data[pos..][0..4], "PACK")) {
                pos += 4;
                break;
            }
            pos += 1;
        }

        if (pos + 8 > data.len) return;

        const version = std.mem.readInt(u32, data[pos..][0..4], .big);
        const num_objects = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);
        pos += 8;

        if (version != 2 and version != 3) return;

        var obj_index: u32 = 0;
        while (obj_index < num_objects and pos + 1 < data.len) : (obj_index += 1) {
            const first_byte = data[pos];
            pos += 1;

            const obj_type_num: u8 = (first_byte >> 4) & 0x07;

            switch (obj_type_num) {
                1, 2, 3, 4 => {
                    const result = zlib_mod.zlib.decompressCounted(self.allocator, data[pos..]) catch break;
                    defer self.allocator.free(result.data);
                    pos += result.consumed;

                    const obj_type: packfile_mod.ObjectType = @enumFromInt(obj_type_num);
                    try self.writeObjectAsLoose(git_dir, obj_type, result.data);
                },
                else => break,
            }
        }
    }

    fn writeObjectAsLoose(self: *SshTransport, git_dir: []const u8, obj_type: packfile_mod.ObjectType, data: []const u8) !void {
        const type_str: []const u8 = switch (obj_type) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
            else => return,
        };

        const header = try std.fmt.allocPrint(self.allocator, "{s} {d}\x00", .{ type_str, data.len });
        defer self.allocator.free(header);

        const full_obj = try self.allocator.alloc(u8, header.len + data.len);
        defer self.allocator.free(full_obj);
        @memcpy(full_obj[0..header.len], header);
        @memcpy(full_obj[header.len..], data);

        const backend = storage_mod.StorageBackend.fromConfig(git_dir, null);
        const obj_type_enum: object.ObjectType = switch (obj_type) {
            .commit => .commit,
            .tree => .tree,
            .blob => .blob,
            .tag => .tag,
            else => return,
        };
        backend.writeRaw(self.allocator, self.io, obj_type_enum, full_obj) catch {};
    }
};

pub const RemoteRef = struct {
    name: []const u8,
    sha: [20]u8,
};

const SshUrl = struct {
    host: []const u8,
    path: []const u8,
};

/// Check if a URL is an SSH URL
pub fn isSshUrl(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "ssh://")) return true;
    if (std.mem.startsWith(u8, url, "git@")) return true;
    if (std.mem.indexOf(u8, url, "@")) |at_pos| {
        if (std.mem.indexOf(u8, url[at_pos + 1 ..], ":")) |_| {
            return true;
        }
    }
    return false;
}

/// Parse SSH URL
fn parseSshUrl(allocator: Allocator, url: []const u8) !SshUrl {
    if (std.mem.startsWith(u8, url, "ssh://")) {
        const rest = url[6..];
        if (std.mem.indexOf(u8, rest, "@")) |at_pos| {
            const after_at = rest[at_pos + 1 ..];
            if (std.mem.indexOf(u8, after_at, "/")) |slash_pos| {
                return .{
                    .host = try allocator.dupe(u8, after_at[0..slash_pos]),
                    .path = try allocator.dupe(u8, after_at[slash_pos..]),
                };
            }
        }
    }

    if (std.mem.startsWith(u8, url, "git@")) {
        const rest = url[4..];
        if (std.mem.indexOf(u8, rest, ":")) |colon_pos| {
            return .{
                .host = try allocator.dupe(u8, rest[0..colon_pos]),
                .path = try allocator.dupe(u8, rest[colon_pos + 1 ..]),
            };
        }
    }

    return error.InvalidSshUrl;
}
