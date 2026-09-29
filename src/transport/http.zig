const std = @import("std");
const safety = @import("../util/clone_safety.zig");
const Sha1 = @import("../core/sha1.zig").Sha1;
const object = @import("../core/object.zig");
const refs_mod = @import("../core/refs.zig");
const zlib_mod = @import("../core/zlib.zig");
const packfile_mod = @import("../core/packfile.zig");
const storage_mod = @import("../core/storage.zig");
const Repo = @import("../core/repo.zig").Repo;
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;

/// A parsed remote reference
/// The wire module owns this shape; version 2 carries extra fields on it, so
/// aliasing avoids a second, subtly different definition.
pub const RemoteRef = wire.RemoteRef;

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

    /// Discover remote refs, preferring protocol version 2.
    ///
    /// Version 0 is kept as a fallback because some servers still only speak it,
    /// but it is tried second: a version 0 server that answers the ref
    /// advertisement will then return an *empty* body for the pack, which used
    /// to look like a successful fetch that downloaded nothing.
    pub fn discoverRefs(self: *HttpTransport) ![]RemoteRef {
        if (self.discoverRefsV2()) |refs| return refs else |_| {}
        return self.discoverRefsV0();
    }

    fn discoverRefsV2(self: *HttpTransport) ![]RemoteRef {
        var url_buf: [1024]u8 = undefined;
        const info_url = try std.fmt.bufPrint(&url_buf, "{s}/info/refs?service=git-upload-pack", .{self.url});

        const advertisement = try self.httpGetV2(info_url);
        defer self.allocator.free(advertisement);

        // A smart server still sends the `# service=` preamble before the
        // advertisement when version 2 was requested.
        const body = wire.skipServicePreamble(advertisement);
        const adv = try wire.parseAdvertisement(self.allocator, body);
        if (adv.version != 2) return error.ProtocolV2Refused;
        freeAdvertisement(self.allocator, adv);

        // Version 2 moved ref listing into a command, so the advertisement alone
        // names no refs at all.
        var upload_buf: [1024]u8 = undefined;
        const upload_url = try std.fmt.bufPrint(&upload_buf, "{s}/git-upload-pack", .{self.url});
        const request = try wire.buildLsRefs(self.allocator, &.{});
        defer self.allocator.free(request);

        const response = try self.httpPostV2(upload_url, request);
        defer self.allocator.free(response);

        return wire.parseLsRefs(self.allocator, response);
    }

    /// Version 0 ref advertisement, for servers that refuse version 2.
    fn discoverRefsV0(self: *HttpTransport) ![]RemoteRef {
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

    /// Fetch objects from remote, over protocol version 2 when the server allows
    /// it and version 0 otherwise.
    pub fn fetch(self: *HttpTransport, repo: Repo, refs: []RemoteRef, have_shas: []const [20]u8) !void {
        if (self.fetchV2(repo, refs, have_shas)) |_| {
            return;
        } else |err| switch (err) {
            // A version 0 server answers the ref advertisement but returns an
            // empty body for a version 0 pack request, so the fallback is not
            // optional for those servers.
            error.ProtocolV2Refused, error.EmptyPack, error.NotAPackfile => return self.fetchV0(repo, refs, have_shas),
            else => return err,
        }
    }

    fn fetchV2(self: *HttpTransport, repo: Repo, refs: []RemoteRef, have_shas: []const [20]u8) anyerror!void {
        var upload_buf: [1024]u8 = undefined;
        const url = try std.fmt.bufPrint(&upload_buf, "{s}/git-upload-pack", .{self.url});

        // Only branches are wanted; a tag ref would make the server send history
        // that no branch needs.
        var wants: std.ArrayList([20]u8) = .empty;
        defer wants.deinit(self.allocator);
        for (refs) |ref| {
            if (!std.mem.startsWith(u8, ref.name, "refs/heads/")) continue;
            try wants.append(self.allocator, ref.sha);
        }
        if (wants.items.len == 0) return error.NothingToFetch;

        const request = try wire.buildFetch(self.allocator, wants.items, have_shas, .{});
        defer self.allocator.free(request);

        const response = try self.httpPostV2(url, request);
        defer self.allocator.free(response);

        const result = try wire.parseFetchResponse(self.allocator, response);
        defer result.deinit(self.allocator);
        if (result.server_errors.len > 0) return error.ServerRejectedFetch;
        if (result.pack.len == 0) return error.EmptyPack;

        _ = try wire.ingestPack(self.allocator, self.io, repo, result.pack);
    }

    fn fetchV0(self: *HttpTransport, repo: Repo, refs: []RemoteRef, have_shas: []const [20]u8) !void {
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
            const pkt = try std.fmt.bufPrint(&pkt_buf, "{s}{s}", .{ &pkt_hex, line });
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
        try self.parsePackfile(repo, response);
    }

    /// Parse a packfile response and write objects to loose store
    fn parsePackfile(self: *HttpTransport, repo: Repo, data: []const u8) !void {
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

        if (version != 2 and version != 3) return;

        // Track offsets for ofs-delta resolution
        var offsets = std.AutoHashMap(usize, [20]u8).init(self.allocator);
        defer offsets.deinit();

        // First pass: extract all non-delta objects and build offset→sha map
        // Second pass: resolve deltas
        var pending_deltas: std.ArrayList(PendingDelta) = .empty;
        defer {
            for (pending_deltas.items) |d| self.allocator.free(d.compressed_data);
            pending_deltas.deinit(self.allocator);
        }

        var obj_index: u32 = 0;
        while (obj_index < num_objects and pos + 1 < data.len) : (obj_index += 1) {
            const obj_offset = pos;

            // Parse type and size (variable-length encoding)
            const first_byte = data[pos];
            pos += 1;

            const obj_type_num: u8 = (first_byte >> 4) & 0x07;
            var obj_size: u64 = first_byte & 0x0f;
            var shift: u6 = 4;

            var b = first_byte;
            while (b & 0x80 != 0) {
                if (pos >= data.len) return;
                b = data[pos];
                pos += 1;
                obj_size |= @as(u64, @intCast(b & 0x7f)) << @intCast(shift);
                shift +|= 7;
            }
            _ = &obj_size; // size is tracked by decompressCounted

            switch (obj_type_num) {
                1, 2, 3, 4 => {
                    // Full object (commit, tree, blob, tag)
                    const result = zlib_mod.zlib.decompressCounted(self.allocator, data[pos..]) catch break;
                    defer self.allocator.free(result.data);

                    pos += result.consumed;

                    const obj_type: packfile_mod.ObjectType = @enumFromInt(obj_type_num);
                    try self.writeObjectAsLoose(repo, obj_type, result.data);
                },
                6 => {
                    // OFS_DELTA: base is at (current_offset - negative_offset)
                    const neg_offset = try parseOfsDelta(data, &pos);
                    const base_offset = obj_offset - neg_offset;

                    const result = zlib_mod.zlib.decompressCounted(self.allocator, data[pos..]) catch break;
                    pos += result.consumed;

                    const base_sha = offsets.get(base_offset) orelse {
                        // Store for second pass
                        try pending_deltas.append(self.allocator, .{
                            .base_offset = base_offset,
                            .base_sha = null,
                            .compressed_data = self.allocator.dupe(u8, result.data) catch break,
                            .is_ofs = true,
                        });
                        continue;
                    };

                    // Resolve delta
                    const base_obj = storage_mod.StorageBackend.fromRepoConfig(self.allocator, self.io, repo).read(self.allocator, self.io, base_sha) catch continue;
                    _ = base_obj;
                },
                7 => {
                    // REF_DELTA: base identified by 20-byte SHA
                    if (pos + 20 > data.len) return;
                    var base_sha: [20]u8 = undefined;
                    @memcpy(&base_sha, data[pos..][0..20]);
                    pos += 20;

                    const result = zlib_mod.zlib.decompressCounted(self.allocator, data[pos..]) catch break;
                    pos += result.consumed;

                    try pending_deltas.append(self.allocator, .{
                        .base_offset = 0,
                        .base_sha = base_sha,
                        .compressed_data = self.allocator.dupe(u8, result.data) catch break,
                        .is_ofs = false,
                    });
                },
                else => break,
            }
        }
    }

    fn writeObjectAsLoose(self: *HttpTransport, repo: Repo, obj_type: packfile_mod.ObjectType, data: []const u8) !void {
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
        const backend = storage_mod.StorageBackend.fromConfig(repo.common_dir, null);
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
    /// Push objects to the remote, over protocol version 2 when possible.
    ///
    /// The response is parsed and a rejected ref reported as a failure. The old
    /// implementation posted the request and threw the answer away, so a push
    /// the server had refused still looked like it had worked.
    pub fn push(self: *HttpTransport, repo: Repo, ref_name: []const u8, sha: [20]u8) !void {
        const old_sha = try self.remoteRefSha(ref_name);
        const objects = try self.collectPushObjects(repo, sha, old_sha);
        defer self.allocator.free(objects);

        if (self.pushV2(repo, ref_name, sha, old_sha, objects)) |_| {
            return;
        } else |err| switch (err) {
            error.ProtocolV2Refused => return self.pushV0(repo, ref_name, sha, old_sha, objects),
            else => return err,
        }
    }

    fn pushV2(
        self: *HttpTransport,
        repo: Repo,
        ref_name: []const u8,
        sha: [20]u8,
        old_sha: ?[20]u8,
        objects: []const [20]u8,
    ) anyerror!void {
        var recv_buf: [1024]u8 = undefined;
        const recv_url = try std.fmt.bufPrint(&recv_buf, "{s}/git-receive-pack", .{self.url});

        const updates = [_]wire.Update{.{
            .ref_name = ref_name,
            .old_sha = old_sha orelse ([_]u8{0} ** 20),
            .new_sha = sha,
        }};

        const body = try self.buildPushBody(repo, &updates, objects);
        defer self.allocator.free(body);

        const response = try self.httpPostV2To(recv_url, body, "application/x-git-receive-pack-request");
        defer self.allocator.free(response);

        const report = try wire.parsePushResponse(self.allocator, response);
        defer {
            for (report.results) |r| {
                self.allocator.free(r.ref_name);
                if (r.reason) |x| self.allocator.free(x);
            }
            self.allocator.free(report.results);
            if (report.unpack_error) |x| self.allocator.free(x);
            if (report.fatal) |x| self.allocator.free(x);
        }

        if (report.fatal) |f| {
            try io_stderr(self.io, "remote: {s}\n", .{f});
            return error.PushRejected;
        }
        if (report.unpack_error) |u| {
            try io_stderr(self.io, "remote: could not unpack objects: {s}\n", .{u});
            return error.PushRejected;
        }
        if (!report.allOk()) {
            for (report.results) |r| {
                if (r.ok) continue;
                try io_stderr(self.io, " ! {s} {s}\n", .{ r.ref_name, r.reason orelse "rejected" });
            }
            return error.PushRejected;
        }
    }

    /// Version 0 push, for servers that refuse version 2.
    fn pushV0(
        self: *HttpTransport,
        repo: Repo,
        ref_name: []const u8,
        sha: [20]u8,
        old_sha: ?[20]u8,
        objects: []const [20]u8,
    ) !void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        const old_hex = if (old_sha) |s| Sha1.hex(s) else ([_]u8{'0'} ** 40);
        const new_hex = Sha1.hex(sha);

        var cmd_buf: [256]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&cmd_buf, "{s} {s} {s}\x00", .{ &old_hex, &new_hex, ref_name });
        try appendPktLine(self.allocator, &body, cmd);
        try body.appendSlice(self.allocator, "0000");

        const pack = try self.packFor(repo, objects);
        defer self.allocator.free(pack);
        try body.appendSlice(self.allocator, pack);

        var recv_buf: [1024]u8 = undefined;
        const recv_url = try std.fmt.bufPrint(&recv_buf, "{s}/git-receive-pack", .{self.url});

        const response = try self.httpPost(recv_url, body.items);
        defer self.allocator.free(response);

        // Even in version 0 the answer says what happened to the ref.
        if (std.mem.indexOf(u8, response, "ng ") != null) return error.PushRejected;
    }

    /// Serialise the objects into a packfile, reusing the writer the fetch path
    /// already used.
    fn packFor(self: *HttpTransport, repo: Repo, objects: []const [20]u8) ![]u8 {
        var pw = packfile_mod.PackWriter.init(self.allocator);
        defer pw.deinit();
        try pw.writeHeader(2, @intCast(objects.len));

        const store = storage_mod.StorageBackend.fromRepoConfig(self.allocator, self.io, repo);
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
        return self.allocator.dupe(u8, pw.getPackData());
    }

    /// The `command=push` request with the packfile appended after the flush.
    ///
    /// The pack is a plain packfile, not side-band framed: version 2 clients send
    /// it raw after the command's flush packet.
    fn buildPushBody(
        self: *HttpTransport,
        repo: Repo,
        updates: []const wire.Update,
        objects: []const [20]u8,
    ) ![]u8 {
        const command = try wire.buildPush(self.allocator, updates, .{});
        defer self.allocator.free(command);

        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, command);

        // Zero objects is still a valid push: a ref update where the server
        // already has everything, or a deletion.
        if (objects.len > 0) {
            var pw = packfile_mod.PackWriter.init(self.allocator);
            defer pw.deinit();
            try pw.writeHeader(2, @intCast(objects.len));

            const store = storage_mod.StorageBackend.fromRepoConfig(self.allocator, self.io, repo);
            for (objects) |obj_sha| {
                const obj = store.read(self.allocator, self.io, obj_sha) catch continue;
                defer obj.deinit(self.allocator);
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
            try body.appendSlice(self.allocator, pw.getPackData());
        }

        return body.toOwnedSlice(self.allocator);
    }

    /// The current value of `ref_name` on the remote, which a push has to claim
    /// as the expected old value.
    fn remoteRefSha(self: *HttpTransport, ref_name: []const u8) !?[20]u8 {
        var info_buf: [1024]u8 = undefined;
        const info_url = try std.fmt.bufPrint(&info_buf, "{s}/info/refs?service=git-receive-pack", .{self.url});

        if (self.discoverRefsV2Push()) |refs| {
            defer {
                for (refs) |r| self.allocator.free(r.name);
                self.allocator.free(refs);
            }
            for (refs) |r| {
                if (std.mem.eql(u8, r.name, ref_name)) return r.sha;
            }
            return null;
        } else |_| {}

        // Version 0 puts the refs in the advertisement itself.
        const response = try self.httpGet(info_url);
        defer self.allocator.free(response);

        var reader = wire.Reader.init(response);
        while (try reader.next()) |pkt| {
            if (pkt.kind != .data) continue;
            const line = std.mem.trim(u8, pkt.payload, " \t\r\n");
            if (line.len < 42 or line[40] != ' ') continue;
            const name = line[41..];
            if (std.mem.eql(u8, name, ref_name)) return Sha1.fromHex(line[0..40]) catch null;
        }
        return null;
    }

    /// `ls-refs` against receive-pack, which is how version 2 learns the remote
    /// refs before a push.
    fn discoverRefsV2Push(self: *HttpTransport) ![]RemoteRef {
        var recv_buf: [1024]u8 = undefined;
        const recv_url = try std.fmt.bufPrint(&recv_buf, "{s}/git-receive-pack", .{self.url});

        const request = try wire.buildLsRefs(self.allocator, &.{});
        defer self.allocator.free(request);
        const response = try self.httpPostV2To(recv_url, request, "application/x-git-receive-pack-request");
        defer self.allocator.free(response);
        return wire.parseLsRefs(self.allocator, response);
    }

    fn httpPostV2To(self: *HttpTransport, url: []const u8, body: []const u8, content_type: []const u8) ![]const u8 {
        return self.httpRequest("POST", url, body, &.{
            .{ .name = "Content-Type", .value = content_type },
            .{ .name = "Git-Protocol", .value = "version=2" },
        });
    }

    /// Collect all objects reachable from `new_sha` that are not reachable from `old_sha`.
    fn collectPushObjects(self: *HttpTransport, repo: Repo, new_sha: [20]u8, old_sha: ?[20]u8) ![][20]u8 {
        const store = storage_mod.StorageBackend.fromRepoConfig(self.allocator, self.io, repo);

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
        return self.httpRequest("GET", url, &.{}, &.{});
    }

    /// HTTP POST using std.http.Client (no curl dependency)
    fn httpPost(self: *HttpTransport, url: []const u8, body: []const u8) ![]const u8 {
        return self.httpRequest("POST", url, body, &.{.{ .name = "Content-Type", .value = "application/x-git-upload-pack-request" }});
    }

    /// Request that asks for wire protocol version 2.
    ///
    /// The `Git-Protocol` header has to be on the ref advertisement *and* on the
    /// POST; without it the server answers in version 0 and the pack request
    /// comes back empty.
    fn httpGetV2(self: *HttpTransport, url: []const u8) ![]const u8 {
        return self.httpRequest("GET", url, &.{}, &.{.{ .name = "Git-Protocol", .value = "version=2" }});
    }

    fn appendPktLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), payload: []const u8) !void {
        const line = try wire.encodeData(allocator, payload);
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    fn io_stderr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        try std.Io.File.stderr().writeStreamingAll(io, msg);
    }

    /// The `Content-Type` is not optional. upload-pack answers a POST without it
    /// with `200` and an *empty* body, which reads as a successful fetch that
    /// downloaded nothing rather than as an error.
    fn httpPostV2(self: *HttpTransport, url: []const u8, body: []const u8) ![]const u8 {
        return self.httpRequest("POST", url, body, &.{
            .{ .name = "Content-Type", .value = "application/x-git-upload-pack-request" },
            .{ .name = "Git-Protocol", .value = "version=2" },
        });
    }

    fn freeAdvertisement(allocator: std.mem.Allocator, adv: wire.Advertisement) void {
        for (adv.capabilities.entries) |e| {
            allocator.free(e.name);
            allocator.free(e.value);
        }
        allocator.free(adv.capabilities.entries);
    }

    /// Execute HTTP request using Zig's built-in HTTP client
    ///
    /// `header` is an optional name/value pair, used for `Git-Protocol`.
    fn httpRequest(
        self: *HttpTransport,
        method: []const u8,
        url: []const u8,
        body: []const u8,
        headers: []const std.http.Header,
    ) ![]const u8 {
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const uri = std.Uri.parse(url) catch return error.InvalidUrl;

        var aw = std.Io.Writer.Allocating.init(self.allocator);
        defer aw.deinit();

        const method_enum: std.http.Method = if (std.mem.eql(u8, method, "POST")) .POST else .GET;

        // `extra_headers` is borrowed by the request, so the slice has to
        // outlive the call, which it does as long as the caller owns it.
        const result = client.fetch(.{
            .location = .{ .uri = uri },
            .method = method_enum,
            .payload = if (body.len > 0) body else null,
            .response_writer = &aw.writer,
            .extra_headers = headers,
        }) catch return error.HttpRequestFailed;

        if (@intFromEnum(result.status) >= 400) return error.HttpRequestFailed;

        return try self.allocator.dupe(u8, aw.written());
    }
};

/// Clone a repository via HTTP
pub fn clone(allocator: Allocator, io: std.Io, url: []const u8, dest: []const u8) !void {
    try safety.ensureEmptyDestination(io, dest);

    // Create destination directory structure
    try std.Io.Dir.cwd().createDirPath(io, dest);

    // Create .gitz structure
    var buf: [512]u8 = undefined;
    const gitz_dir = try std.fmt.bufPrint(&buf, "{s}/.gitz", .{dest});
    try std.Io.Dir.cwd().createDirPath(io, gitz_dir);

    const refs_dir = try std.fmt.bufPrint(&buf, "{s}/.gitz/refs/heads", .{dest});
    try std.Io.Dir.cwd().createDirPath(io, refs_dir);

    const tags_dir = try std.fmt.bufPrint(&buf, "{s}/.gitz/refs/tags", .{dest});
    try std.Io.Dir.cwd().createDirPath(io, tags_dir);

    const objects_dir = try std.fmt.bufPrint(&buf, "{s}/.gitz/objects", .{dest});
    try std.Io.Dir.cwd().createDirPath(io, objects_dir);

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

    const refs_manager = refs_mod.Refs.init(Repo.flat(git_dir_path));
    for (refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            // Write local branch ref
            try refs_manager.write(allocator, io, ref.name, ref.sha);

            // Write remote tracking ref
            const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{ref.name[11..]});
            defer allocator.free(remote_ref);
            const remote_dir = try std.fmt.allocPrint(allocator, "{s}/.gitz/refs/remotes/origin", .{dest});
            defer allocator.free(remote_dir);
            try std.Io.Dir.cwd().createDirPath(io, remote_dir);
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

    try transport.fetch(Repo.flat(fetch_git_dir), refs, &.{});

    // Checkout files
    const checkout_ref = default_branch orelse refs[0].name;
    const checkout_sha = try refs_manager.read(allocator, io, checkout_ref);
    try checkoutFiles(allocator, io, Repo.flat(fetch_git_dir), checkout_sha, dest);

    // Print success message via stdout
    const stdout = std.Io.File.stdout();
    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "Cloned into '{s}'\nFetching {d} refs\n", .{ dest, refs.len });
    try std.Io.File.writeStreamingAll(stdout, io, msg);
}

/// Checkout files from a commit into a directory
fn checkoutFiles(allocator: std.mem.Allocator, io: std.Io, repo: Repo, commit_sha: [20]u8, dest: []const u8) !void {
    const store = storage_mod.StorageBackend.fromRepoConfig(allocator, io, repo);

    const commit_obj = try store.read(allocator, io, commit_sha);
    const commit = switch (commit_obj) {
        .commit => |c| c,
        else => {
            commit_obj.deinit(allocator);
            return error.ExpectedCommit;
        },
    };
    defer commit_obj.deinit(allocator);

    const tree_obj = try store.read(allocator, io, commit.tree);
    const tree = switch (tree_obj) {
        .tree => |t| t,
        else => {
            tree_obj.deinit(allocator);
            return error.ExpectedTree;
        },
    };
    defer tree_obj.deinit(allocator);

    for (tree.entries) |entry| {
        try checkoutTreeEntry(allocator, io, &store, entry, dest);
    }
}

fn checkoutTreeEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *const storage_mod.StorageBackend,
    entry: object.TreeEntry,
    base: []const u8,
) !void {
    try safety.validateTreeEntryName(entry.name);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, entry.name });
    defer allocator.free(file_path);
    if (std.Io.Dir.cwd().access(io, file_path, .{})) |_| {
        return error.CheckoutPathAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const obj = try store.read(allocator, io, entry.sha);
    defer obj.deinit(allocator);

    switch (obj) {
        .blob => |b| {
            if (std.fs.path.dirname(file_path)) |dir| {
                try std.Io.Dir.cwd().createDirPath(io, dir);
            }
            var file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .exclusive = true });
            defer file.close(io);
            try std.Io.File.writeStreamingAll(file, io, b.content);
        },
        .tree => |t| {
            try std.Io.Dir.cwd().createDirPath(io, file_path);
            for (t.entries) |sub_entry| {
                try checkoutTreeEntry(allocator, io, store, sub_entry, file_path);
            }
        },
        else => return error.ExpectedBlobOrTree,
    }
}

test "legacy HTTP clone checkout rejects traversal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dest = "/tmp/gitz-test-http-clone-safety";
    try std.Io.Dir.cwd().createDirPath(io, dest);
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    const store = storage_mod.StorageBackend.looseBackend(dest);
    const entry = object.TreeEntry{
        .mode = 0o100644,
        .name = "../../victim.txt",
        .sha = Sha1.hash("missing"),
    };
    try std.testing.expectError(
        error.UnsafeCheckoutEntryName,
        checkoutTreeEntry(allocator, io, &store, entry, dest),
    );
}
