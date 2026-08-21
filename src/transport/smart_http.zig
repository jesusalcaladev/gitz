const std = @import("std");
const Io = @import("../util/io.zig").Io;
const Sha1 = @import("../core/sha1.zig").Sha1;
const pktline = @import("../core/pktline.zig");

/// Smart HTTP transport for Git (native, no curl).
pub const SmartHttp = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SmartHttp {
        return .{ .allocator = allocator, .io = io };
    }

    /// Discover refs via Smart HTTP.
    pub fn discoverRefs(self: SmartHttp, url: []const u8) ![]pktline.RemoteRef {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const full_url = try std.fmt.allocPrint(self.allocator, "{s}/info/refs?service=git-upload-pack", .{url});
        defer self.allocator.free(full_url);
        const uri = try std.Uri.parse(full_url);

        var response_storage = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        defer response_storage.deinit(self.allocator);

        const result = try client.fetch(.{
            .location = .{ .uri = uri },
            .method = .GET,
            .response_storage = .{ .dynamic = &response_storage },
        });

        if (result.status != .ok) return error.HttpGetFailed;
        return try pktline.parseRefs(self.allocator, response_storage.items);
    }

    /// Fetch objects via Smart HTTP.
    pub fn fetchPack(self: SmartHttp, url: []const u8, want_shas: []const [20]u8) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const full_url = try std.fmt.allocPrint(self.allocator, "{s}/git-upload-pack", .{url});
        defer self.allocator.free(full_url);
        const uri = try std.Uri.parse(full_url);

        // Build request body
        var body = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
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

        try body.appendSlice(self.allocator, "0000");
        try body.appendSlice(self.allocator, "0009done\n");

        var response_storage = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        defer response_storage.deinit(self.allocator);

        const result = try client.fetch(.{
            .location = .{ .uri = uri },
            .method = .POST,
            .payload = body.items,
            .response_storage = .{ .dynamic = &response_storage },
        });

        if (result.status != .ok) return error.HttpPostFailed;
        return try pktline.extractPackData(self.allocator, response_storage.items);
    }

    /// Discover refs for push.
    pub fn discoverPushRefs(self: SmartHttp, url: []const u8) ![]pktline.RemoteRef {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const full_url = try std.fmt.allocPrint(self.allocator, "{s}/info/refs?service=git-receive-pack", .{url});
        defer self.allocator.free(full_url);
        const uri = try std.Uri.parse(full_url);

        var response_storage = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        defer response_storage.deinit(self.allocator);

        const result = try client.fetch(.{
            .location = .{ .uri = uri },
            .method = .GET,
            .response_storage = .{ .dynamic = &response_storage },
        });

        if (result.status != .ok) return error.HttpGetFailed;
        return try pktline.parseRefs(self.allocator, response_storage.items);
    }

    /// Push pack via Smart HTTP.
    pub fn pushPack(self: SmartHttp, url: []const u8, pack_data: []const u8) !PushResult {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const full_url = try std.fmt.allocPrint(self.allocator, "{s}/git-receive-pack", .{url});
        defer self.allocator.free(full_url);
        const uri = try std.Uri.parse(full_url);

        var response_storage = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        defer response_storage.deinit(self.allocator);

        const result = try client.fetch(.{
            .location = .{ .uri = uri },
            .method = .POST,
            .payload = pack_data,
            .response_storage = .{ .dynamic = &response_storage },
        });

        if (result.status != .ok) return .rejected;

        const response = response_storage.items;
        if (std.mem.indexOf(u8, response, "unpack ok") != null) return .ok;
        if (std.mem.indexOf(u8, response, "unpack fail") != null) return .unpack_failed;
        if (std.mem.indexOf(u8, response, "rejected") != null) return .rejected;
        return .unknown;
    }

    pub const PushResult = enum {
        ok,
        unpack_failed,
        rejected,
        unknown,
    };
};
