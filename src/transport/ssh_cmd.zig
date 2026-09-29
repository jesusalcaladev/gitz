const std = @import("std");
const Sha1 = @import("../core/sha1.zig").Sha1;
const storage_mod = @import("../core/storage.zig");
const object = @import("../core/object.zig");
const packfile_mod = @import("../core/packfile.zig");
const zlib_mod = @import("../core/zlib.zig");
const Repo = @import("../core/repo.zig").Repo;
const pktline = @import("../core/pktline.zig");
const wire = @import("wire.zig");

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

    /// Discover refs via SSH, preferring protocol version 2.
    ///
    /// Over SSH the version is requested by putting `GIT_PROTOCOL=version=2` in
    /// the child's environment -- there is no header to attach. A server that
    /// ignores it answers in version 0, and that is still handled, but a server
    /// like GitHub answers the version 0 ref advertisement and then returns an
    /// empty body for the pack, so version 2 is not optional in practice.
    pub fn discoverRefs(self: *SshTransport) ![]RemoteRef {
        if (self.discoverRefsV2()) |refs| return refs else |_| {}
        return self.discoverRefsV0();
    }

    fn discoverRefsV2(self: *SshTransport) ![]RemoteRef {
        var session = try self.startSession("git-upload-pack");
        defer session.deinit();

        const advertisement = try session.readAdvertisement();
        const adv = try wire.parseAdvertisement(self.allocator, advertisement);
        if (adv.version != 2) return error.ProtocolV2Refused;
        freeAdvertisement(self.allocator, adv);

        // Version 2 lists refs through a command, not in the advertisement.
        const request = try wire.buildLsRefs(self.allocator, &.{});
        defer self.allocator.free(request);
        try session.writeRequest(request);

        return wire.parseLsRefs(self.allocator, try session.readToEnd());
    }

    /// Version 0 ref advertisement: run upload-pack and read what it prints.
    fn discoverRefsV0(self: *SshTransport) ![]RemoteRef {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "ssh");
        try argv.append(self.allocator, "-T");
        try argv.append(self.allocator, "-o");
        try argv.append(self.allocator, "BatchMode=yes");
        try argv.append(self.allocator, self.host);
        try argv.append(self.allocator, "git-upload-pack");
        try argv.append(self.allocator, self.path);

        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv.items,
        }) catch return error.SshError;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        // The advertisement is pkt-line framed, so each ref is preceded by a
        // four-hex-digit length and the first one carries the server
        // capabilities after a NUL. This used to be read as plain `<sha>
        // <name>` lines, which matched nothing, so `gitz clone`, `fetch` and
        // push all reported "no refs found on remote" against any real
        // server. `pktline.parseRefs` is the same parser the HTTP transport
        // uses, and it already handles the NUL capability suffix.
        return pktline.parseRefs(self.allocator, result.stdout);
    }

    /// One `ssh ... git-upload-pack` process, for request/response exchanges.
    const Session = struct {
        child: std.process.Child,
        allocator: std.mem.Allocator,
        io: std.Io,
        buf: [64 * 1024]u8 = undefined,

        fn deinit(self: *Session) void {
            // `kill` reaps the child and clears its id, so the two are exclusive.
            // Calling `wait` after a successful `kill` trips an assertion inside
            // the standard library rather than returning an error.
            if (self.child.stdin) |*in| {
                in.close(self.io);
                self.child.stdin = null;
            }
            if (self.child.id == null) return; // already reaped
            self.child.kill(self.io);
        }

        /// Read until the server has sent its whole advertisement.
        ///
        /// The advertisement ends with a flush packet. Waiting for it matters:
        /// upload-pack will not read a request until it has finished
        /// advertising, so writing the request before this point is fine but
        /// *interpreting* the response is not, and the two are easy to confuse.
        fn readAdvertisement(self: *Session) ![]const u8 {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(self.allocator);

            while (true) {
                const chunk = try self.readSome();
                try buf.appendSlice(self.allocator, chunk);

                // Only stop on a flush that lands on a packet boundary.
                var reader = wire.Reader.init(buf.items);
                while (try reader.next()) |pkt| {
                    if (pkt.kind == .flush) return buf.items;
                }
            }
        }

        fn writeRequest(self: *Session, request: []const u8) !void {
            const stdin = &(self.child.stdin orelse return error.SshError);
            var written: usize = 0;
            while (written < request.len) {
                const n = std.os.linux.write(@intCast(stdin.handle), request[written..].ptr, request.len - written);
                if (n <= 0) return error.SshError;
                written += n;
            }
            stdin.close(self.io);
            self.child.stdin = null;
        }

        /// Read whatever is left of the response, borrowed from `self`.
        fn readToEnd(self: *Session) ![]const u8 {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(self.allocator);
            while (true) {
                const chunk = try self.readSome();
                if (chunk.len == 0) break;
                try buf.appendSlice(self.allocator, chunk);
            }
            return buf.items;
        }

        fn readSome(self: *Session) ![]const u8 {
            const stdout = &(self.child.stdout orelse return error.SshError);
            const n = std.Io.File.readStreaming(stdout.*, self.io, &.{&self.buf}) catch return &.{};
            return self.buf[0..n];
        }
    };

    /// Start `ssh ... <service> <path>`, asking for protocol version 2.
    fn startSession(self: *SshTransport, service: []const u8) !Session {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);

        // `GIT_PROTOCOL` is how SSH is told which wire version to speak, and it
        // has to be in the child's environment. `spawn`'s `environ_map` replaces
        // the whole environment rather than adding to it, and rebuilding the
        // parent's here would be both fragile and libc-dependent, so the
        // variable is set with `env` instead -- which passes everything else
        // through untouched. Without it the server falls back to version 0,
        // which GitHub answers with an empty pack.
        try argv.append(self.allocator, "env");
        try argv.append(self.allocator, "GIT_PROTOCOL=version=2");
        try argv.append(self.allocator, "ssh");
        try argv.append(self.allocator, "-T");
        try argv.append(self.allocator, "-o");
        try argv.append(self.allocator, "BatchMode=yes");
        // Setting the variable in ssh's own environment is not enough: ssh has to
        // be told to forward it, and without `SendEnv` the server never sees it
        // and answers in version 0. Both halves are required.
        try argv.append(self.allocator, "-o");
        try argv.append(self.allocator, "SendEnv=GIT_PROTOCOL");
        try argv.append(self.allocator, self.host);
        try argv.append(self.allocator, service);
        try argv.append(self.allocator, self.path);

        const child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            // Inherited: reading stdout to completion while an unread stderr pipe
            // sits there can deadlock once the server writes more than a pipe
            // buffer, and both services report protocol errors on stdout.
            .stderr = .inherit,
        }) catch return error.SshError;

        return .{ .child = child, .allocator = self.allocator, .io = self.io };
    }

    fn freeAdvertisement(allocator: std.mem.Allocator, adv: wire.Advertisement) void {
        for (adv.capabilities.entries) |e| {
            allocator.free(e.name);
            allocator.free(e.value);
        }
        allocator.free(adv.capabilities.entries);
    }

    /// Fetch objects via SSH
    pub fn fetch(self: *SshTransport, repo: Repo, refs: []RemoteRef, have_shas: []const [20]u8) anyerror!void {
        if (self.fetchV2(repo, refs, have_shas)) |_| {
            return;
        } else |err| switch (err) {
            error.ProtocolV2Refused, error.EmptyPack, error.NotAPackfile => return self.fetchV0(repo, refs, have_shas),
            else => return err,
        }
    }

    fn fetchV2(self: *SshTransport, repo: Repo, refs: []RemoteRef, have_shas: []const [20]u8) anyerror!void {
        var session = try self.startSession("git-upload-pack");
        defer session.deinit();

        const advertisement = try session.readAdvertisement();
        const adv = try wire.parseAdvertisement(self.allocator, advertisement);
        if (adv.version != 2) return error.ProtocolV2Refused;
        freeAdvertisement(self.allocator, adv);

        var wants: std.ArrayList([20]u8) = .empty;
        defer wants.deinit(self.allocator);
        for (refs) |ref| {
            if (!std.mem.startsWith(u8, ref.name, "refs/heads/")) continue;
            try wants.append(self.allocator, ref.sha);
        }
        if (wants.items.len == 0) return error.NothingToFetch;

        const request = try wire.buildFetch(self.allocator, wants.items, have_shas, .{});
        defer self.allocator.free(request);
        try session.writeRequest(request);

        const response = try session.readToEnd();
        const result = try wire.parseFetchResponse(self.allocator, response);
        defer result.deinit(self.allocator);
        if (result.server_errors.len > 0) return error.ServerRejectedFetch;

        _ = try wire.ingestPack(self.allocator, self.io, repo, result.pack);
    }

    /// Version 0 fetch, kept for servers that refuse version 2.
    fn fetchV0(self: *SshTransport, repo: Repo, refs: []RemoteRef, have_shas: []const [20]u8) !void {
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

        // The wants have to reach the server, so this cannot use
        // `std.process.run`: that helper hardcodes `.stdin = .ignore`, so the
        // `input` built above was discarded and the server sent no pack at all.
        // The fetch then "succeeded" having written zero objects, and the
        // following checkout failed with nothing to check out.
        var child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            // Inherited rather than piped: reading stdout to completion while a
            // stderr pipe sits unread can deadlock once the server writes more
            // error output than the pipe buffer holds. upload-pack reports
            // protocol-level errors on stdout, so nothing is lost.
            .stderr = .inherit,
        }) catch return error.SshError;

        if (child.stdin) |*stdin| {
            const fd = stdin.handle;
            var written: usize = 0;
            while (written < input.items.len) {
                const n = std.os.linux.write(@intCast(fd), input.items[written..].ptr, input.items.len - written);
                if (n <= 0) return error.SshError;
                written += n;
            }
            stdin.close(self.io);
            child.stdin = null;
        }

        var stdout_buf: [64 * 1024]u8 = undefined;
        var stdout_data: std.ArrayList(u8) = .empty;
        defer stdout_data.deinit(self.allocator);
        while (child.stdout) |*f| {
            const n = std.Io.File.readStreaming(f.*, self.io, &.{&stdout_buf}) catch break;
            if (n == 0) break;
            stdout_data.appendSlice(self.allocator, stdout_buf[0..n]) catch break;
        }

        const term = child.wait(self.io) catch return error.SshError;
        const exit_code: i32 = switch (term) {
            .exited => |code| @intCast(code),
            else => -1,
        };
        if (exit_code != 0) return error.FetchFailed;

        try self.parsePackfile(repo, stdout_data.items);
    }

    /// Push objects via SSH, over protocol version 2 when the server allows it.
    ///
    /// The response is parsed and a rejected ref reported. The old path posted
    /// the request and ignored the answer, so a push the server had refused was
    /// still reported to the user as a success.
    pub fn push(self: *SshTransport, repo: Repo, ref_name: []const u8, sha: [20]u8, old_sha: ?[20]u8) !void {
        const result = self.pushV2(repo, ref_name, sha, old_sha);
        if (result) |_| {
            return;
        } else |err| switch (err) {
            error.ProtocolV2Refused => return self.pushV0(repo, ref_name, sha, old_sha),
            else => return err,
        }
    }

    fn pushV2(
        self: *SshTransport,
        repo: Repo,
        ref_name: []const u8,
        sha: [20]u8,
        old_sha: ?[20]u8,
    ) anyerror!void {
        var session = try self.startSession("git-receive-pack");
        defer session.deinit();

        const advertisement = try session.readAdvertisement();
        const adv = try wire.parseAdvertisement(self.allocator, advertisement);
        // GitHub's receive-pack answers in version 0 even though its
        // upload-pack speaks version 2, which is also what git does there.
        if (adv.version != 2) return error.ProtocolV2Refused;
        freeAdvertisement(self.allocator, adv);

        const full_ref = try self.allocator.dupe(u8, if (std.mem.startsWith(u8, ref_name, "refs/"))
            ref_name
        else
            try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{ref_name}));
        defer self.allocator.free(full_ref);

        const objects = try self.collectPushObjects(repo, sha, old_sha);
        defer self.allocator.free(objects);

        const updates = [_]wire.Update{.{
            .ref_name = full_ref,
            .old_sha = old_sha orelse ([_]u8{0} ** 20),
            .new_sha = sha,
        }};

        const request = try self.buildPushRequest(repo, updates[0..], objects);
        defer self.allocator.free(request);
        try session.writeRequest(request);

        const response = try session.readToEnd();
        const report = try wire.parsePushResponse(self.allocator, response);
        defer freeReport(self.allocator, report);

        if (report.fatal) |f| {
            std.debug.print("remote: {s}\n", .{f});
            return error.PushRejected;
        }
        if (report.unpack_error) |u| {
            std.debug.print("remote: could not unpack objects: {s}\n", .{u});
            return error.PushRejected;
        }
        if (!report.allOk()) {
            for (report.results) |r| {
                if (r.ok) continue;
                std.debug.print(" ! {s} {s}\n", .{ r.ref_name, r.reason orelse "rejected" });
            }
            return error.PushRejected;
        }
    }

    /// The `command=push` request with the packfile appended after the flush.
    fn buildPushRequest(
        self: *SshTransport,
        repo: Repo,
        updates: []const wire.Update,
        objects: []const [20]u8,
    ) ![]u8 {
        const command = try wire.buildPush(self.allocator, updates, .{});
        defer self.allocator.free(command);

        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, command);

        // Zero objects is still a valid push: the server already has everything,
        // or the update deletes a ref.
        if (objects.len > 0) {
            const pack = try self.packOf(repo, objects);
            defer self.allocator.free(pack);
            try body.appendSlice(self.allocator, pack);
        }

        return body.toOwnedSlice(self.allocator);
    }

    fn packOf(self: *SshTransport, repo: Repo, objects: []const [20]u8) ![]u8 {
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
        return self.allocator.dupe(u8, pw.getPackData());
    }

    /// Version 0 push, kept for servers that refuse version 2.
    fn pushV0(self: *SshTransport, repo: Repo, ref_name: []const u8, sha: [20]u8, old_sha: ?[20]u8) !void {
        const new_hex = Sha1.hex(sha);
        const old_hex: [40]u8 = if (old_sha) |os| Sha1.hex(os) else [_]u8{'0'} ** 40;

        const objects = try self.collectPushObjects(repo, sha, old_sha);
        defer self.allocator.free(objects);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        // Version 0 receive-pack takes its capabilities after the command's NUL,
        // and the packfile after the flush.
        const full_ref = if (std.mem.startsWith(u8, ref_name, "refs/")) ref_name else blk: {
            const r = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{ref_name});
            defer self.allocator.free(r);
            break :blk try self.allocator.dupe(u8, r);
        };
        defer if (!std.mem.startsWith(u8, ref_name, "refs/")) self.allocator.free(full_ref);

        var cmd_buf: [512]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&cmd_buf, "{s} {s} {s}\x00report-status", .{ &old_hex, &new_hex, full_ref });
        const pkt = try wire.encodeData(self.allocator, cmd);
        defer self.allocator.free(pkt);
        try body.appendSlice(self.allocator, pkt);
        try body.appendSlice(self.allocator, "0000");

        if (objects.len > 0) {
            const pack = try self.packOf(repo, objects);
            defer self.allocator.free(pack);
            try body.appendSlice(self.allocator, pack);
        }

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
            .stderr = .inherit,
        }) catch return error.SshError;
        defer if (child.id != null) child.kill(self.io);

        if (child.stdin) |*stdin| {
            const fd = stdin.handle;
            var written: usize = 0;
            while (written < body.items.len) {
                const n = std.os.linux.write(@intCast(fd), body.items[written..].ptr, body.items.len - written);
                if (n <= 0) return error.SshError;
                written += n;
            }
            stdin.close(self.io);
            child.stdin = null;
        }

        var buf: [64 * 1024]u8 = undefined;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        while (child.stdout) |*f| {
            const n = std.Io.File.readStreaming(f.*, self.io, &.{&buf}) catch break;
            if (n == 0) break;
            try out.appendSlice(self.allocator, buf[0..n]);
        }
        _ = child.wait(self.io) catch return error.SshError;

        const report = try wire.parsePushResponse(self.allocator, out.items);
        defer freeReport(self.allocator, report);
        if (!report.allOk()) return error.PushRejected;
    }

    fn freeReport(allocator: std.mem.Allocator, report: wire.PushReport) void {
        for (report.results) |r| {
            allocator.free(r.ref_name);
            if (r.reason) |x| allocator.free(x);
        }
        allocator.free(report.results);
        if (report.unpack_error) |x| allocator.free(x);
        if (report.fatal) |x| allocator.free(x);
    }

    fn collectPushObjects(self: *SshTransport, repo: Repo, new_sha: [20]u8, old_sha: ?[20]u8) ![][20]u8 {
        const store = storage_mod.StorageBackend.fromRepoConfig(self.allocator, self.io, repo);

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
    fn parsePackfile(self: *SshTransport, repo: Repo, data: []const u8) !void {
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
                    try self.writeObjectAsLoose(repo, obj_type, result.data);
                },
                else => break,
            }
        }
    }

    fn writeObjectAsLoose(self: *SshTransport, repo: Repo, obj_type: packfile_mod.ObjectType, data: []const u8) !void {
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
};

/// The shared pkt-line parser defines its own, identical shape. Aliasing it
/// keeps one definition instead of three copies of the same struct.
pub const RemoteRef = pktline.RemoteRef;

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
        // Keep "git@" prefix so SSH resolves as git@github.com, not jesusalcala@github.com
        if (std.mem.indexOf(u8, url[4..], ":")) |colon_pos| {
            const abs_colon = 4 + colon_pos;
            return .{
                .host = try allocator.dupe(u8, url[0..abs_colon]),
                .path = try allocator.dupe(u8, url[abs_colon + 1 ..]),
            };
        }
    }

    return error.InvalidSshUrl;
}
