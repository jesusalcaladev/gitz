const std = @import("std");
const linux = std.os.linux;

/// Authentication manager for git transports.
pub const AuthConfig = struct {
    ssh_key: ?[]const u8 = null,
    ssh_agent: ?[]const u8 = null,
    http_user: ?[]const u8 = null,
    http_pass: ?[]const u8 = null,
    github_token: ?[]const u8 = null,

    /// Auto-detect authentication from environment.
    pub fn detect(allocator: std.mem.Allocator) AuthConfig {
        var config = AuthConfig{};

        const home = getHomeDir(allocator) orelse return config;
        defer allocator.free(home);

        const key_paths = [_][]const u8{
            ".ssh/id_ed25519",
            ".ssh/id_rsa",
            ".ssh/id_ecdsa",
        };

        for (key_paths) |key_path| {
            const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, key_path }) catch continue;
            if (fileExists(full_path)) {
                config.ssh_key = full_path;
                break;
            } else {
                allocator.free(full_path);
            }
        }

        if (getEnvOwned(allocator, "GITHUB_TOKEN")) |token| {
            config.github_token = token;
        }

        if (getEnvOwned(allocator, "GIT_ASKPASS")) |askpass| {
            config.ssh_agent = askpass;
        }

        return config;
    }

    pub fn deinit(self: *AuthConfig, allocator: std.mem.Allocator) void {
        if (self.ssh_key) |k| allocator.free(k);
        if (self.ssh_agent) |a| allocator.free(a);
        if (self.http_user) |u| allocator.free(u);
        if (self.http_pass) |p| allocator.free(p);
        if (self.github_token) |t| allocator.free(t);
    }

    pub fn buildSshArgs(self: AuthConfig, allocator: std.mem.Allocator, host: []const u8) ![][]const u8 {
        var args = std.ArrayList([]const u8).empty;

        try args.append(allocator, "ssh");
        try args.append(allocator, "-o");
        try args.append(allocator, "StrictHostKeyChecking=no");

        if (self.ssh_key) |key| {
            try args.append(allocator, "-i");
            try args.append(allocator, key);
        }

        if (self.ssh_agent != null) {
            try args.append(allocator, "-A");
        }

        try args.append(allocator, "-l");
        try args.append(allocator, "git");
        try args.append(allocator, host);

        return try args.toOwnedSlice(allocator);
    }

    pub fn buildHttpArgs(self: AuthConfig, allocator: std.mem.Allocator) ![][]const u8 {
        var args = std.ArrayList([]const u8).empty;

        if (self.http_user) |user| {
            try args.append(allocator, "-u");
            const user_pass = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, self.http_pass orelse "" });
            try args.append(allocator, user_pass);
        }

        if (self.github_token) |token| {
            try args.append(allocator, "-H");
            const auth_header = try std.fmt.allocPrint(allocator, "Authorization: token {s}", .{token});
            try args.append(allocator, auth_header);
        }

        return try args.toOwnedSlice(allocator);
    }
};

fn fileExists(path: []const u8) bool {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    _ = linux.close(@intCast(fd));
    return true;
}

fn getHomeDir(allocator: std.mem.Allocator) ?[]const u8 {
    if (readFile("/proc/self/environ")) |env| {
        defer allocator.free(env);
        var entries = std.mem.splitScalar(u8, env, 0);
        while (entries.next()) |entry| {
            if (std.mem.startsWith(u8, entry, "HOME=")) {
                return allocator.dupe(u8, entry[5..]) catch null;
            }
        }
    }
    return null;
}

fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (readFile("/proc/self/environ")) |env| {
        defer allocator.free(env);
        var entries = std.mem.splitScalar(u8, env, 0);
        while (entries.next()) |entry| {
            if (std.mem.startsWith(u8, entry, name) and entry.len > name.len and entry[name.len] == '=') {
                return allocator.dupe(u8, entry[name.len + 1 ..]) catch null;
            }
        }
    }
    return null;
}

fn readFile(path: []const u8) ?[]u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = linux.close(@intCast(fd));

    const rc = linux.lseek(@intCast(fd), 0, linux.SEEK.END);
    const size: usize = if (@as(isize, @bitCast(rc)) < 0) 0 else @intCast(@as(isize, @bitCast(rc)));
    // Seek back to start
    _ = linux.lseek(@intCast(fd), 0, linux.SEEK.SET);

    if (size == 0 or size > 1 << 20) return null;

    const buf = std.heap.page_allocator.alloc(u8, size) catch return null;
    _ = std.posix.read(fd, buf) catch {
        std.heap.page_allocator.free(buf);
        return null;
    };
    return buf;
}

test "auth detect" {
    var auth = AuthConfig.detect(std.testing.allocator);
    auth.deinit(std.testing.allocator);
}
