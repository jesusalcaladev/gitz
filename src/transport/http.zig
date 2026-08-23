const std = @import("std");
const Sha1 = @import("../core/sha1.zig").Sha1;
const object = @import("../core/object.zig");
const refs_mod = @import("../core/refs.zig");
const zlib_mod = @import("../core/zlib.zig");
const packfile_mod = @import("../core/packfile.zig");
const storage_mod = @import("../core/storage.zig");
const pktline = @import("../core/pktline.zig");
const delta_mod = @import("../core/delta.zig");

const Allocator = std.mem.Allocator;

fn typeName(t: packfile_mod.ObjectType) []const u8 {
    return switch (t) {
        .commit => "commit",
        .tree => "tree",
        .blob => "blob",
        .tag => "tag",
        else => "unknown",
    };
}

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

        // Use native HTTP client (no curl dependency)
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
                // Strip capabilities after \0 (e.g. "HEAD\x00multi_ack ...")
                var raw_name = std.mem.trimEnd(u8, ref_line[41..], &[_]u8{ '\n', '\r' });
                if (std.mem.indexOfScalar(u8, raw_name, 0)) |nul| {
                    raw_name = raw_name[0..nul];
                }
                const name = raw_name;

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

        // Build the upload-pack request body
        var body = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        defer body.deinit(self.allocator);

        // Report wanted refs. First want must carry capabilities.
        const caps = "multi_ack thin-pack side-band-64k ofs-delta agent=git/2.45.0";
        for (refs, 0..) |ref, i| {
            const want_pkt = try pktline.buildWantLineCaps(self.allocator, ref.sha, caps, i == 0);
            defer self.allocator.free(want_pkt);
            try body.appendSlice(self.allocator, want_pkt);
        }
        if (refs.len == 0) return error.NoWantedRefs;

        try body.appendSlice(self.allocator, "0000");

        // Advertise what we already have so the server can thin the pack.
        for (have_shas) |sha| {
            const have_pkt = try pktline.buildHaveLine(self.allocator, sha);
            defer self.allocator.free(have_pkt);
            try body.appendSlice(self.allocator, have_pkt);
        }

        try body.appendSlice(self.allocator, "0009done\n");

        var upload_url: [1024]u8 = undefined;
        const url = try std.fmt.bufPrint(&upload_url, "{s}/git-upload-pack", .{self.url});

        // POST the request with Smart HTTP content types (required by git servers)
        const response = try self.httpRequest("POST", url, body.items, &.{
            .{ .name = "Content-Type", .value = "application/x-git-upload-pack-request" },
            .{ .name = "Accept", .value = "application/x-git-upload-pack-result" },
        });
        defer self.allocator.free(response);

        // We negotiated side-band-64k: unwrap the framing first so interleaved
        // progress packets don't corrupt the pack stream.
        const unframed = try pktline.stripSideband(self.allocator, response);
        defer self.allocator.free(unframed);

        // Parse the packfile from the unwrapped stream (falls back internally).
        try self.parsePackfile(git_dir, if (unframed.len > 0) unframed else response);
    }

    /// Parse a packfile response and write objects to loose store.
    /// Handles full objects plus OFS_DELTA and REF_DELTA chains with
    /// iterative resolution (deltas whose bases appear later in the pack,
    /// or whose bases are already in the local object store).
    fn parsePackfile(self: *HttpTransport, git_dir: []const u8, data: []const u8) !void {
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

        const version = std.mem.readInt(u32, data[pos..][0..4], .big);
        const num_objects = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);
        pos += 8;

        if (version != 2 and version != 3) return;

        // Phase 1: parse every entry into memory.
        // offset→sha map fills as objects are resolved.
        var entries: std.ArrayList(PackEntry) = .empty;
        defer {
            for (entries.items) |*e| {
                if (e.raw_delta) |rd| self.allocator.free(rd);
                if (e.resolved_data) |rd| self.allocator.free(rd);
            }
            entries.deinit(self.allocator);
        }

        var obj_index: u32 = 0;
        while (obj_index < num_objects and pos + 1 < data.len) : (obj_index += 1) {
            const obj_offset = pos;

            const first_byte = data[pos];
            pos += 1;
            const type_num: u8 = (first_byte >> 4) & 0x07;
            var b = first_byte;
            while (b & 0x80 != 0) {
                if (pos >= data.len) return error.UnexpectedEof;
                b = data[pos];
                pos += 1;
            }

            var entry = PackEntry{ .offset = obj_offset, .type_num = type_num };

            switch (type_num) {
                1, 2, 3, 4 => {
                    const result = zlib_mod.zlib.decompressCounted(self.allocator, data[pos..]) catch break;
                    pos += result.consumed;
                    entry.resolved_data = result.data;
                    entry.resolved = true;
                },
                6 => {
                    // OFS_DELTA: base at (offset - negative_offset)
                    const neg = try parseOfsDelta(data, &pos);
                    entry.base_offset = obj_offset - neg;
                    const result = zlib_mod.zlib.decompressCounted(self.allocator, data[pos..]) catch break;
                    pos += result.consumed;
                    entry.raw_delta = result.data;
                },
                7 => {
                    // REF_DELTA: base identified by SHA
                    if (pos + 20 > data.len) return error.UnexpectedEof;
                    @memcpy(&entry.base_sha.?, data[pos..][0..20]);
                    pos += 20;
                    const result = zlib_mod.zlib.decompressCounted(self.allocator, data[pos..]) catch break;
                    pos += result.consumed;
                    entry.raw_delta = result.data;
                },
                else => return error.InvalidPackObjectType,
            }

            try entries.append(self.allocator, entry);
        }

        // Phase 2: iteratively resolve deltas until no progress is made.
        // Each pass resolves deltas whose base became available in the previous pass.
        const store = storage_mod.StorageBackend.fromRepoConfig(self.allocator, self.io, git_dir);
        var resolved_count: usize = 0;
        var progress = true;
        while (progress) {
            progress = false;
            resolved_count = 0;
            for (entries.items) |*e| {
                if (e.resolved) continue;
                if (e.raw_delta == null) continue;

                // Find the base data
                var base_type: ?packfile_mod.ObjectType = null;
                var base_data: ?[]const u8 = null;
                var base_is_owned = false;

                if (e.type_num == 6) {
                    // Base by pack offset — must be another entry in this pack
                    for (entries.items) |*cand| {
                        if (cand.offset == e.base_offset and cand.resolved) {
                            base_type = cand.looseType();
                            base_data = cand.resolved_data.?;
                            break;
                        }
                    }
                } else {
                    // REF_DELTA: look in-pack first, then local store
                    for (entries.items) |*cand| {
                        if (cand.resolved and cand.sha != null and std.mem.eql(u8, &cand.sha.?, &e.base_sha.?)) {
                            base_type = cand.looseType();
                            base_data = cand.resolved_data.?;
                            break;
                        }
                    }
                    if (base_data == null) {
                        const base_obj = store.read(self.allocator, self.io, e.base_sha.?) catch null;
                        if (base_obj) |bo| {
                            base_type = switch (bo) {
                                .commit => .commit,
                                .tree => .tree,
                                .blob => .blob,
                                .tag => .tag,
                            };
                            const serialized = bo.serialize(self.allocator) catch continue;
                            defer self.allocator.free(serialized);
                            const nul = std.mem.indexOfScalar(u8, serialized, 0) orelse continue;
                            base_data = self.allocator.dupe(u8, serialized[nul + 1 ..]) catch continue;
                            base_is_owned = true;
                        }
                    }
                }

                const bt = base_type orelse continue;
                const bd = base_data orelse continue;

                const applied = delta_mod.applyDelta(self.allocator, bd, e.raw_delta.?) catch {
                    if (base_is_owned) self.allocator.free(@constCast(bd));
                    continue;
                };

                if (base_is_owned) self.allocator.free(@constCast(bd));
                // A delta inherits its base's object type
                e.type_num = @intFromEnum(bt);
                e.resolved_data = applied;
                e.resolved = true;
                progress = true;
            }
        }

        // Phase 3: write everything to the store and record SHAs.
        for (entries.items) |*e| {
            if (!e.resolved) continue; // unresolvable chain — skip
            const ot: packfile_mod.ObjectType = @enumFromInt(e.type_num);
            try self.writeObjectAsLoose(git_dir, ot, e.resolved_data.?);

            // Record SHA so later REF_DELTAs can find it.
            const header = try std.fmt.allocPrint(self.allocator, "{s} {d}\x00", .{ typeName(ot), e.resolved_data.?.len });
            defer self.allocator.free(header);
            var h = std.crypto.hash.Sha1.init(.{});
            h.update(header);
            h.update(e.resolved_data.?);
            var sha: [20]u8 = undefined;
            h.final(&sha);
            e.sha = sha;
        }
    }

    const PackEntry = struct {
        offset: usize,
        type_num: u8,
        base_offset: usize = 0,
        base_sha: ?[20]u8 = null,
        raw_delta: ?[]u8 = null,
        resolved: bool = false,
        resolved_data: ?[]u8 = null,
        sha: ?[20]u8 = null,    fn looseType(self: PackEntry) ?packfile_mod.ObjectType {
        return switch (self.type_num) {
            1...4 => @enumFromInt(self.type_num),
            else => null,
        }; 
    }
    };

    fn writeObjectAsLoose(self: *HttpTransport, git_dir: []const u8, obj_type: packfile_mod.ObjectType, data: []const u8) !void {
        const type_str: []const u8 = switch (obj_type) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
            else => return,
        };

        // Build git object: "type size\0content"
        const header = try std.fmt.allocPrint(self.allocator, "{s} {d}\x00", .{ type_str, data.len });
        defer self.allocator.free(header);

        const full_obj = try self.allocator.alloc(u8, header.len + data.len);
        defer self.allocator.free(full_obj);
        @memcpy(full_obj[0..header.len], header);
        @memcpy(full_obj[header.len..], data);

        // Use the storage backend — respects the configured backend (loose or shard).
        // This is the critical path where packfile objects are unpacked and stored
        // individually. By routing through StorageBackend, sharded repos get
        // objects distributed to the correct shard automatically.
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

    const PendingDelta = struct {
        base_offset: usize,
        base_sha: ?[20]u8,
        compressed_data: []u8,
        is_ofs: bool,
    };

    fn parseOfsDelta(data: []const u8, pos_ptr: *usize) !usize {
        var pos = pos_ptr.*;
        if (pos >= data.len) return error.UnexpectedEof;
        var b = data[pos];
        pos += 1;
        var ofs: usize = @as(usize, b & 0x7f);
        while (b & 0x80 != 0) {
            if (pos >= data.len) return error.UnexpectedEof;
            b = data[pos];
            pos += 1;
            ofs = ((ofs + 1) << 7) | @as(usize, @intCast(b & 0x7f));
        }
        pos_ptr.* = pos;
        return ofs;
    }

    /// Push objects to remote
    pub fn push(self: *HttpTransport, git_dir: []const u8, ref_name: []const u8, sha: [20]u8) !void {
        // 1. Discover refs via GET /info/refs?service=git-receive-pack
        var push_url: [1024]u8 = undefined;
        const info_url = try std.fmt.bufPrint(&push_url, "{s}/info/refs?service=git-receive-pack", .{self.url});

        const refs_response = try self.httpGet(info_url);
        defer self.allocator.free(refs_response);

        // Parse old remote SHA for this ref (for the update command)
        var old_sha: ?[20]u8 = null;
        var pos: usize = 0;
        while (pos + 4 <= refs_response.len) {
            const pkt_len = std.fmt.parseInt(usize, refs_response[pos..][0..4], 16) catch break;
            if (pkt_len == 0) {
                pos += 4;
                continue;
            }
            if (pkt_len < 4) break;
            if (pos + pkt_len > refs_response.len) break;
            const line = refs_response[pos + 4 .. pos + pkt_len];
            pos += pkt_len;

            if (line.len >= 41 and line[40] == ' ') {
                const sha_hex = line[0..40];
                const name = std.mem.trimEnd(u8, line[41..], &[_]u8{ '\n', '\r' });
                if (std.mem.eql(u8, name, ref_name)) {
                    old_sha = Sha1.fromHex(sha_hex) catch null;
                    break;
                }
            }
        }

        // 2. Collect all objects reachable from new SHA but not from old SHA
        const objects_to_send = try self.collectPushObjects(git_dir, sha, old_sha);
        defer self.allocator.free(objects_to_send);

        if (objects_to_send.len == 0) return; // nothing to push

        // 3. Build packfile
        var pw = packfile_mod.PackWriter.init(self.allocator);
        defer pw.deinit();
        try pw.writeHeader(2, @intCast(objects_to_send.len));

        const store = storage_mod.StorageBackend.fromRepoConfig(self.allocator, self.io, git_dir);
        for (objects_to_send) |obj_sha| {
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

        // 4. Build receive-pack command + pack data
        var body = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        defer body.deinit(self.allocator);

        // Command pkt with report-status capability (required by servers)
        var old_bytes: [20]u8 = if (old_sha) |s| s else @splat(0);
        _ = &old_bytes;
        const cmd_pkt = try pktline.buildPushCommand(self.allocator, old_bytes, sha, ref_name);
        defer self.allocator.free(cmd_pkt);
        try body.appendSlice(self.allocator, cmd_pkt);

        // Flush
        try body.appendSlice(self.allocator, "0000");

        // Append pack data
        try body.appendSlice(self.allocator, pw.getPackData());

        // 5. POST to /git-receive-pack with proper Smart HTTP headers
        const recv_url = try std.fmt.allocPrint(self.allocator, "{s}/git-receive-pack", .{self.url});
        defer self.allocator.free(recv_url);

        const response = try self.httpRequest("POST", recv_url, body.items, &.{
            .{ .name = "Content-Type", .value = "application/x-git-receive-pack-request" },
            .{ .name = "Accept", .value = "application/x-git-receive-pack-result" },
        });
        defer self.allocator.free(response);

        // 6. Parse the report-status reply and surface failures to the caller.
        const report = try pktline.parsePushReport(self.allocator, response);
        if (!report.unpack_ok or !report.ref_ok) {
            return error.PushRejected;
        }
    }

    /// Collect all objects reachable from `new_sha` that are not reachable from `old_sha`.
    fn collectPushObjects(self: *HttpTransport, git_dir: []const u8, new_sha: [20]u8, old_sha: ?[20]u8) ![][20]u8 {
        const store = storage_mod.StorageBackend.fromRepoConfig(self.allocator, self.io, git_dir);

        var visited = std.AutoHashMap([20]u8, void).init(self.allocator);
        defer visited.deinit();

        var queue: std.ArrayList([20]u8) = .empty;
        defer queue.deinit(self.allocator);

        // Add old objects to visited set (they're already on the remote)
        if (old_sha) |old| {
            try self.markReachable(store, &visited, old);
        }

        // BFS from new_sha
        try queue.append(self.allocator, new_sha);
        while (queue.items.len > 0) {
            const sha = queue.pop().?;
            if (visited.contains(sha)) continue;
            visited.put(sha, {}) catch {};

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

        // Build result: objects in visited that were NOT in old reachable set
        // (if old_sha was null, all visited objects are new)
        var result: std.ArrayList([20]u8) = .empty;
        var iter = visited.iterator();
        var old_set = std.AutoHashMap([20]u8, void).init(self.allocator);
        defer old_set.deinit();
        if (old_sha) |old| {
            try self.markReachable(store, &old_set, old);
        }

        while (iter.next()) |entry| {
            if (!old_set.contains(entry.key_ptr.*)) {
                try result.append(self.allocator, entry.key_ptr.*);
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn markReachable(self: *HttpTransport, store: storage_mod.StorageBackend, visited: *std.AutoHashMap([20]u8, void), start_sha: [20]u8) !void {
        var queue: std.ArrayList([20]u8) = .empty;
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

    /// HTTP GET using std.http.Client (no curl dependency)
    fn httpGet(self: *HttpTransport, url: []const u8) ![]const u8 {
        return self.httpRequest("GET", url, &.{}, &.{
            .{ .name = "Accept", .value = "application/x-git-upload-pack-advertisement" },
        });
    }

    /// HTTP POST using std.http.Client (no curl dependency)
    fn httpPost(self: *HttpTransport, url: []const u8, body: []const u8) ![]const u8 {
        return self.httpRequest("POST", url, body, &.{});
    }

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Execute HTTP request using Zig's built-in HTTP client.
    /// Sends User-Agent git/2.45.0 for maximum server compatibility plus any
    /// Smart HTTP content-type headers required by the endpoint.
    fn httpRequest(
        self: *HttpTransport,
        method: []const u8,
        url: []const u8,
        body: []const u8,
        extra_headers: []const Header,
    ) ![]const u8 {
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const uri = std.Uri.parse(url) catch return error.InvalidUrl;

        var aw = std.Io.Writer.Allocating.init(self.allocator);
        defer aw.deinit();

        var std_headers: std.http.Client.Request.Headers = .{};
        std_headers.user_agent = .{ .override = "git/2.45.0" };

        var extra: [3]std.http.Header = undefined;
        var n_extra: usize = 0;
        for (extra_headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) {
                std_headers.content_type = .{ .override = h.value };
            } else if (n_extra < extra.len) {
                extra[n_extra] = .{ .name = h.name, .value = h.value };
                n_extra += 1;
            }
        }

        const method_enum: std.http.Method = if (std.mem.eql(u8, method, "POST")) .POST else .GET;

        const result = client.fetch(.{
            .location = .{ .uri = uri },
            .method = method_enum,
            .payload = if (body.len > 0) body else null,
            .headers = std_headers,
            .extra_headers = extra[0..n_extra],
            .response_writer = &aw.writer,
        }) catch return error.HttpRequestFailed;

        if (@intFromEnum(result.status) >= 400) return error.HttpRequestFailed;

        return try self.allocator.dupe(u8, aw.written());
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
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io, git_dir);

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
