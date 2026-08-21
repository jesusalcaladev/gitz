const std = @import("std");
const Io = @import("../util/io.zig").Io;
const Sha1 = @import("../core/sha1.zig").Sha1;
const pktline = @import("../core/pktline.zig");

/// Smart HTTP transport for Git.
///
/// Implements the Git Smart HTTP protocol (RFC on git-scm.com):
///
/// Clone/Fetch:
///   1. GET  /info/refs?service=git-upload-pack
///   2. POST /git-upload-pack  (want/have lines)
///   3. Receive PACK data
///
/// Push:
///   1. GET  /info/refs?service=git-receive-pack
///   2. POST /git-receive-pack  (PACK data)
///   3. Receive unpack-ok/rejected
///
/// This eliminates the dependency on the `git` binary for HTTP operations.

pub const SmartHttp = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SmartHttp {
        return .{ .allocator = allocator, .io = io };
    }

    /// Discover refs via Smart HTTP.
    /// GET /info/refs?service=git-upload-pack
    pub fn discoverRefs(self: SmartHttp, url: []const u8) ![]pktline.RemoteRef {
        const info_refs_url = try std.fmt.allocPrint(self.allocator, "{s}/info/refs?service=git-upload-pack", .{url});
        defer self.allocator.free(info_refs_url);

        const response = try self.httpGet(info_refs_url);
        defer self.allocator.free(response);

        return try pktline.parseRefs(self.allocator, response);
    }

    /// Fetch objects via Smart HTTP.
    /// POST /git-upload-pack with want/have lines, receive PACK.
    pub fn fetchPack(self: SmartHttp, url: []const u8, want_shas: []const [20]u8) ![]u8 {
        const upload_url = try std.fmt.allocPrint(self.allocator, "{s}/git-upload-pack", .{url});
        defer self.allocator.free(upload_url);

        // Build request body: want lines + flush + done
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        for (want_shas) |sha| {
            const sha_hex = Sha1.hex(sha);
            const want_line = try std.fmt.allocPrint(self.allocator, "want {s}\n", .{&sha_hex});
            defer self.allocator.free(want_line);

            const pkt_len: u16 = @intCast(4 + want_line.len);
            const pkt_hex = try std.fmt.allocPrint(self.allocator, "{x:0>4}", .{pkt_len});
            defer self.allocator.free(pkt_hex);

            try body.appendSlice(self.allocator, pkt_hex);
            try body.appendSlice(self.allocator, want_line);
        }

        // Flush packet
        try body.appendSlice(self.allocator, "0000");
        // Done
        try body.appendSlice(self.allocator, "0009done\n");

        const response = try self.httpPost(upload_url, body.items);
        defer self.allocator.free(response);

        // Extract PACK data from response
        return try pktline.extractPackData(self.allocator, response);
    }

    /// Discover refs for push.
    /// GET /info/refs?service=git-receive-pack
    pub fn discoverPushRefs(self: SmartHttp, url: []const u8) ![]pktline.RemoteRef {
        const info_refs_url = try std.fmt.allocPrint(self.allocator, "{s}/info/refs?service=git-receive-pack", .{url});
        defer self.allocator.free(info_refs_url);

        const response = try self.httpGet(info_refs_url);
        defer self.allocator.free(response);

        return try pktline.parseRefs(self.allocator, response);
    }

    /// Push pack via Smart HTTP.
    /// POST /git-receive-pack with PACK data.
    pub fn pushPack(self: SmartHttp, url: []const u8, pack_data: []const u8) !PushResult {
        const receive_url = try std.fmt.allocPrint(self.allocator, "{s}/git-receive-pack", .{url});
        defer self.allocator.free(receive_url);

        const response = try self.httpPost(receive_url, pack_data);
        defer self.allocator.free(response);

        // Parse response
        if (std.mem.indexOf(u8, response, "unpack ok") != null) {
            return .ok;
        }
        if (std.mem.indexOf(u8, response, "unpack fail") != null) {
            return .unpack_failed;
        }
        if (std.mem.indexOf(u8, response, "rejected") != null) {
            return .rejected;
        }
        return .unknown;
    }

    pub const PushResult = enum {
        ok,
        unpack_failed,
        rejected,
        unknown,
    };

    // -- HTTP helpers using curl as subprocess --

    fn httpGet(self: SmartHttp, url: []const u8) ![]u8 {
        var argv = [_][]const u8{ "curl", "-s", "-L", "-H", "Content-Type: application/x-git-upload-pack-request", url };

        const result = std.process.run(self.allocator, self.io, .{
            .argv = &argv,
        }) catch return error.HttpGetFailed;

        if (result.term != .exited or result.term.exited != 0) {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
            return error.HttpGetFailed;
        }

        self.allocator.free(result.stderr);
        return result.stdout;
    }

    fn httpPost(self: SmartHttp, url: []const u8, body: []const u8) ![]u8 {
        // Write body to temp file
        const tmp_path = "/tmp/gitz_http_body";
        var tmp_file = std.Io.Dir.cwd().createFile(self.io, tmp_path, .{}) catch return error.HttpPostFailed;
        defer tmp_file.close(self.io);
        try std.Io.File.writeStreamingAll(tmp_file, self.io, body);

        const argv_base = [_][]const u8{ "curl", "-s", "-L", "-X", "POST" };

        const content_type_arg = "-H";
        const content_type_val = "Content-Type: application/x-git-receive-pack-request";

        const data_val = try std.fmt.allocPrint(self.allocator, "@{s}", .{tmp_path});
        defer self.allocator.free(data_val);

        var argv: [8][]const u8 = undefined;
        argv[0] = argv_base[0];
        argv[1] = argv_base[1];
        argv[2] = argv_base[2];
        argv[3] = argv_base[3];
        argv[4] = argv_base[4];
        argv[5] = content_type_arg;
        argv[6] = content_type_val;
        argv[7] = url;

        const result = std.process.run(self.allocator, self.io, .{
            .argv = &argv,
        }) catch return error.HttpPostFailed;

        // Cleanup temp file
        std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};

        if (result.term != .exited or result.term.exited != 0) {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
            return error.HttpPostFailed;
        }

        self.allocator.free(result.stderr);
        return result.stdout;
    }
};
