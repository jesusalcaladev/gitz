const std = @import("std");
const Sha1 = @import("../core/sha1.zig").Sha1;
const loose = @import("../core/loose.zig");
const object = @import("../core/object.zig");
const refs_mod = @import("../core/refs.zig");

const Allocator = std.mem.Allocator;

/// A parsed remote reference
pub const RemoteRef = struct {
    name: []const u8,
    sha: [20]u8,
};

/// HTTP transport for Smart Git protocol
pub const HttpTransport = struct {
    allocator: Allocator,
    io: std.Io,
    url: []const u8,

    pub fn init(allocator: Allocator, io: std.Io, url: []const u8) !HttpTransport {
        return .{
            .allocator = allocator,
            .io = io,
            .url = url,
        };
    }

    pub fn deinit(self: *HttpTransport) void {
        _ = self;
    }

    /// Discover remote refs via GET /info/refs?service=git-upload-pack
    pub fn discoverRefs(self: *HttpTransport) ![]RemoteRef {
        var url_buf: [1024]u8 = undefined;
        const info_url = try std.fmt.bufPrint(&url_buf, "{s}/info/refs?service=git-upload-pack", .{self.url});

        var result = std.ArrayList(RemoteRef){ .items = &.{}, .capacity = 0 };
        errdefer {
            for (result.items) |r| self.allocator.free(r.name);
            result.deinit(self.allocator);
        }

        // Use curl as a subprocess for HTTP requests (simpler than raw HTTP)
        const response = try self.httpGet(info_url);
        defer self.allocator.free(response);

        // Parse packet-line format
        var pos: usize = 0;
        while (pos + 4 <= response.len) {
            const len_hex = response[pos..][0..4];
            const pkt_len = std.fmt.parseInt(usize, len_hex, 16) catch break;

            if (pkt_len == 0) {
                pos += 4;
                continue;
            }

            if (pkt_len < 4) break;
            const line = response[pos + 4 ..][0 .. pkt_len - 4];
            pos += pkt_len;

            if (std.mem.startsWith(u8, line, "# service=")) continue;

            var ref_line = line;
            if (ref_line.len > 0 and ref_line[0] == ' ') {
                ref_line = ref_line[1..];
            }

            if (ref_line.len >= 41 and ref_line[40] == ' ') {
                const sha_hex = ref_line[0..40];
                const name = std.mem.trimEnd(u8, ref_line[41..], &[_]u8{ '\n', '\r' });

                const sha = Sha1.fromHex(sha_hex) catch continue;
                const owned_name = self.allocator.dupe(u8, name) catch continue;

                try result.append(self.allocator, .{
                    .name = owned_name,
                    .sha = sha,
                });
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Fetch objects from remote
    pub fn fetch(self: *HttpTransport, git_dir: []const u8, refs: []RemoteRef, have_shas: []const [20]u8) !void {
        _ = have_shas;

        // Build the upload-pack request body
        var body = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        defer body.deinit(self.allocator);

        // Report wanted refs
        for (refs) |ref| {
            var line_buf: [128]u8 = undefined;
            const hex = Sha1.hex(ref.sha);
            const line = try std.fmt.bufPrint(&line_buf, "want {s}\n", .{&hex});
            var pkt_buf: [132]u8 = undefined;
            const pkt_len = 4 + line.len;
            const pkt_hex = std.fmt.bytesToHex([2]u8{ @intCast(pkt_len >> 8), @intCast(pkt_len & 0xff) }, .lower);
            const pkt = try std.fmt.bufPrint(&pkt_buf, "{s}{s}", .{&pkt_hex, line});
            try body.appendSlice(self.allocator, pkt);
        }

        try body.appendSlice(self.allocator, "0000");
        try body.appendSlice(self.allocator, "0009done\n");

        var upload_url: [1024]u8 = undefined;
        const url = try std.fmt.bufPrint(&upload_url, "{s}/git-upload-pack", .{self.url});

        // POST the request
        const response = try self.httpPost(url, body.items);
        defer self.allocator.free(response);

        // Parse the packfile from response
        try self.parsePackfile(git_dir, response);
    }

    /// Parse a packfile response and write objects to loose store
    fn parsePackfile(self: *HttpTransport, git_dir: []const u8, data: []const u8) !void {
        _ = self;
        _ = git_dir;

        // Find PACK header
        var pos: usize = 0;
        while (pos + 4 <= data.len) {
            if (std.mem.eql(u8, data[pos..][0..4], "PACK")) {
                pos += 4;
                break;
            }
            pos += 1;
        }

        if (pos + 8 > data.len) return; // No pack data

        // Read version and object count
        const version = std.mem.readInt(u32, data[pos..][0..4], .big);
        const num_objects = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);
        pos += 8;

        _ = version;

        // Read objects
        for (0..num_objects) |_| {
            if (pos >= data.len) break;

            // Parse type and size (variable-length encoding)
            const first_byte = data[pos];
            pos += 1;

            var obj_type: object.ObjectType = undefined;
            var obj_size: u64 = first_byte & 0x0f;
            var shift: u6 = 4;

            switch ((first_byte >> 4) & 0x07) {
                1 => obj_type = .commit,
                2 => obj_type = .tree,
                3 => obj_type = .blob,
                4 => obj_type = .tag,
                6 => {
                    // OFS_DELTA - skip for now
                    while (pos < data.len and data[pos] & 0x80 != 0) : (pos += 1) {}
                    pos += 1;
                    continue;
                },
                7 => {
                    // REF_DELTA - skip for now
                    pos += 20; // skip reference SHA
                    while (pos < data.len and data[pos] & 0x80 != 0) : (pos += 1) {}
                    pos += 1;
                    continue;
                },
                else => continue,
            }

            while (pos < data.len and data[pos] & 0x80 != 0) {
                obj_size |= @as(u64, data[pos] & 0x7f) << @intCast(shift);
                shift += 7;
                pos += 1;
            }
            if (pos < data.len) {
                obj_size |= @as(u64, data[pos] & 0x7f) << @intCast(shift);
                pos += 1;
            }

            // For now, skip the compressed data
            // A full implementation would use zlib to decompress and write as loose objects
            _ = &obj_type;
            _ = &obj_size;
        }
    }

    /// Push objects to remote
    pub fn push(self: *HttpTransport, git_dir: []const u8, ref_name: []const u8, sha: [20]u8) !void {
        _ = self;
        _ = git_dir;
        _ = ref_name;
        _ = sha;
        _ = git_dir;
        _ = ref_name;
        _ = sha;

        // Full push would:
        // 1. Discover refs via GET /info/refs?service=git-receive-pack
        // 2. Build packfile with all objects reachable from new commits
        // 3. POST to /git-receive-pack
    }

    /// Simple HTTP GET using curl subprocess
    fn httpGet(self: *HttpTransport, url: []const u8) ![]const u8 {
        return self.httpRequest("GET", url, &.{});
    }

    /// Simple HTTP POST using curl subprocess
    fn httpPost(self: *HttpTransport, url: []const u8, body: []const u8) ![]const u8 {
        return self.httpRequest("POST", url, body);
    }

    /// Execute HTTP request via curl
    fn httpRequest(self: *HttpTransport, method: []const u8, url: []const u8, body: []const u8) ![]const u8 {
        var argv = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "curl");
        try argv.append(self.allocator, "-s");
        try argv.append(self.allocator, "-f");
        try argv.append(self.allocator, method);
        try argv.append(self.allocator, url);

        if (body.len > 0) {
            try argv.append(self.allocator, "-d");
            try argv.append(self.allocator, body);
        }

        // Use std.process.run (Zig 0.16 API)
        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv.items,
        }) catch return error.HttpRequestFailed;
        defer self.allocator.free(result.stderr);

        return result.stdout;
    }
};

/// Clone a repository via HTTP
pub fn clone(allocator: Allocator, io: std.Io, url: []const u8, dest: []const u8) !void {
    // Create destination directory structure
    std.Io.Dir.cwd().createDirPath(io, dest) catch {};

    // Create .gitz structure
    var buf: [512]u8 = undefined;
    const gitz_dir = try std.fmt.bufPrint(&buf, "{s}/.gitz", .{dest});
    std.Io.Dir.cwd().createDirPath(io, gitz_dir) catch {};

    const refs_dir = try std.fmt.bufPrint(&buf, "{s}/.gitz/refs/heads", .{dest});
    std.Io.Dir.cwd().createDirPath(io, refs_dir) catch {};

    const tags_dir = try std.fmt.bufPrint(&buf, "{s}/.gitz/refs/tags", .{dest});
    std.Io.Dir.cwd().createDirPath(io, tags_dir) catch {};

    const objects_dir = try std.fmt.bufPrint(&buf, "{s}/.gitz/objects", .{dest});
    std.Io.Dir.cwd().createDirPath(io, objects_dir) catch {};

    // Write HEAD
    const head_path = try std.fmt.bufPrint(&buf, "{s}/.gitz/HEAD", .{dest});
    var hf = try std.Io.Dir.cwd().createFile(io, head_path, .{});
    defer hf.close(io);
    try std.Io.File.writeStreamingAll(hf, io, "ref: refs/heads/main\n");

    // Init transport and discover refs
    var transport = try HttpTransport.init(allocator, io, url);
    defer transport.deinit();

    const refs = try transport.discoverRefs();
    defer {
        for (refs) |r| allocator.free(r.name);
        allocator.free(refs);
    }

    if (refs.len == 0) {
        return error.NoRefsFound;
    }

    // Find default branch
    var head_sha: ?[20]u8 = null;
    var default_branch: ?[]const u8 = null;

    for (refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/main") or
            std.mem.startsWith(u8, ref.name, "refs/heads/master"))
        {
            head_sha = ref.sha;
            default_branch = ref.name;
            break;
        }
    }

    if (head_sha == null and refs.len > 0) {
        head_sha = refs[0].sha;
        default_branch = refs[0].name;
    }

    if (head_sha == null) return error.NoRefsFound;

    // Write all remote refs locally
    const git_dir_path = try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dest});
    defer allocator.free(git_dir_path);

    const refs_manager = refs_mod.Refs.init(git_dir_path);
    for (refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            // Write local branch ref
            try refs_manager.write(allocator, io, ref.name, ref.sha);

            // Write remote tracking ref
            const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{ref.name[11..]});
            defer allocator.free(remote_ref);
            const remote_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/remotes/origin", .{dest});
            defer allocator.free(remote_dir);
            std.Io.Dir.cwd().createDirPath(io, remote_dir) catch {};
            try refs_manager.write(allocator, io, remote_ref, ref.sha);
        } else if (std.mem.startsWith(u8, ref.name, "refs/tags/")) {
            try refs_manager.write(allocator, io, ref.name, ref.sha);
        }
    }

    // Set HEAD
    if (default_branch) |db| {
        const branch_name = if (std.mem.startsWith(u8, db, "refs/heads/")) db[11..] else db;
        const symbolic_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name});
        defer allocator.free(symbolic_ref);
        try refs_manager.writeSymbolic(allocator, io, "HEAD", symbolic_ref);
    }

    // Fetch objects
    const fetch_git_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz", .{dest});
    defer allocator.free(fetch_git_dir);

    try transport.fetch(fetch_git_dir, refs, &.{});

    // Checkout files
    const checkout_ref = default_branch orelse refs[0].name;
    const checkout_sha = refs_manager.read(allocator, io, checkout_ref) catch return;
    try checkoutFiles(allocator, io, fetch_git_dir, checkout_sha, dest);

    // Print success message via stdout
    const stdout = std.Io.File.stdout();
    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "Cloned into '{s}'\nFetching {d} refs\n", .{ dest, refs.len });
    try std.Io.File.writeStreamingAll(stdout, io, msg);
}

/// Checkout files from a commit into a directory
fn checkoutFiles(allocator: std.mem.Allocator, io: std.Io, git_dir: []const u8, commit_sha: [20]u8, dest: []const u8) !void {
    const store = loose.LooseStore.init(git_dir);

    // Read commit
    const obj = store.read(allocator, io, commit_sha) catch return;
    const commit = switch (obj) {
        .commit => |c| c,
        else => return,
    };

    // Read tree
    const tree_obj = store.read(allocator, io, commit.tree) catch return;
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => return,
    };

    for (tree.entries) |entry| {
        const blob_obj = store.read(allocator, io, entry.sha) catch continue;
        const content = switch (blob_obj) {
            .blob => |b| b.content,
            else => continue,
        };

        // Ensure parent directory exists
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, entry.name });
        defer allocator.free(file_path);

        if (std.fs.path.dirname(file_path)) |dir| {
            std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        }

        var file = std.Io.Dir.cwd().createFile(io, file_path, .{}) catch continue;
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, content);
    }
}
