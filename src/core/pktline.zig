const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;

/// Git packet-line protocol parser.
///
/// Format:
///   - 4 hex chars = length of packet (including the 4-byte header)
///   - "0000" = flush packet
///   - "0001" = response end
///   - First line after refs may contain \0 + capabilities
///
/// Used by both SSH and Smart HTTP transports.

pub const RemoteRef = struct {
    name: []const u8,
    sha: [20]u8,
};

/// Parse refs from a pkt-line response.
pub fn parseRefs(allocator: std.mem.Allocator, data: []const u8) ![]RemoteRef {
    var result: std.ArrayList(RemoteRef) = .empty;

    var pos: usize = 0;
    while (pos < data.len) {
        if (pos + 4 > data.len) break;
        const len_hex = data[pos .. pos + 4];
        pos += 4;

        const pkt_len = std.fmt.parseInt(u16, len_hex, 16) catch break;
        if (pkt_len == 0) continue; // flush
        if (pkt_len < 4) break;

        const payload_len = @as(usize, pkt_len) - 4;
        if (pos + payload_len > data.len) break;
        const payload = data[pos .. pos + payload_len];
        pos += payload_len;

        const line = if (payload.len > 0 and payload[payload.len - 1] == '\n')
            payload[0 .. payload.len - 1]
        else
            payload;

        // Split on \0 for capabilities
        const content = if (std.mem.indexOf(u8, line, "\x00")) |nul_pos|
            line[0..nul_pos]
        else
            line;

        if (content.len < 41) continue;
        if (content[40] != ' ') continue;

        const sha_hex = content[0..40];
        const name = std.mem.trim(u8, content[41..], " \t\r\n");
        if (name.len == 0) continue;

        const sha = Sha1.fromHex(sha_hex) catch continue;
        const owned_name = allocator.dupe(u8, name) catch continue;

        try result.append(allocator, .{
            .name = owned_name,
            .sha = sha,
        });
    }

    return try result.toOwnedSlice(allocator);
}

/// Extract PACK data from a pkt-line response.
/// Returns the raw pack data (after removing pkt-line framing).
pub fn extractPackData(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var pack_data: std.ArrayList(u8) = .empty;

    var pos: usize = 0;
    while (pos < data.len) {
        if (pos + 4 > data.len) break;
        const len_hex = data[pos .. pos + 4];
        pos += 4;

        const pkt_len = std.fmt.parseInt(u16, len_hex, 16) catch break;
        if (pkt_len == 0) continue; // flush
        if (pkt_len == 1) break; // response end
        if (pkt_len < 4) break;

        const payload_len = @as(usize, pkt_len) - 4;
        if (pos + payload_len > data.len) break;
        try pack_data.appendSlice(allocator, data[pos .. pos + payload_len]);
        pos += payload_len;
    }

    return try pack_data.toOwnedSlice(allocator);
}

/// Build a pkt-line "want" message for fetch.
pub fn buildWantLine(allocator: std.mem.Allocator, sha: [20]u8) ![]u8 {
    const sha_hex = Sha1.hex(sha);
    const want_line = try std.fmt.allocPrint(allocator, "want {s}\n", .{&sha_hex});
    const pkt_len: u16 = @intCast(4 + want_line.len);
    const pkt_hex = try std.fmt.allocPrint(allocator, "{x:0>4}", .{pkt_len});
    var result = std.ArrayList(u8).empty;
    try result.appendSlice(allocator, pkt_hex);
    try result.appendSlice(allocator, want_line);
    allocator.free(pkt_hex);
    return try result.toOwnedSlice(allocator);
}

/// Build a pkt-line flush packet.
pub fn flushPacket() []const u8 {
    return "0000";
}

/// Build a pkt-line "done" message.
pub fn doneMessage(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator, "0009done\n", .{});
}

test "parse refs" {
    const allocator = std.testing.allocator;
    // Simulated pkt-line ref listing
    const data =
        "0033" ++ "0123456789abcdef0123456789abcdef01234567 HEAD\x00\n" ++
        "003c" ++ "0123456789abcdef0123456789abcdef01234567 refs/heads/main\n" ++
        "0000";

    const refs = try parseRefs(allocator, data);
    defer {
        for (refs) |r| allocator.free(r.name);
        allocator.free(refs);
    }

    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("HEAD", refs[0].name);
    try std.testing.expectEqualStrings("refs/heads/main", refs[1].name);
}

// ─── Transport protocol builders (TDD) ───────────────────────────────

/// Build a pkt-line "want" message with capabilities on the first want.
pub fn buildWantLineCaps(allocator: std.mem.Allocator, sha: [20]u8, caps: []const u8, first: bool) ![]u8 {
    const sha_hex = Sha1.hex(sha);
    const line = if (first)
        try std.fmt.allocPrint(allocator, "want {s} {s}\n", .{ &sha_hex, caps })
    else
        try std.fmt.allocPrint(allocator, "want {s}\n", .{&sha_hex});
    defer allocator.free(line);
    return try encodePkt(allocator, line);
}

/// Build a pkt-line "have" message.
pub fn buildHaveLine(allocator: std.mem.Allocator, sha: [20]u8) ![]u8 {
    const sha_hex = Sha1.hex(sha);
    const line = try std.fmt.allocPrint(allocator, "have {s}\n", .{&sha_hex});
    defer allocator.free(line);
    return try encodePkt(allocator, line);
}

/// Encode an arbitrary payload as a pkt-line (4-byte hex length prefix).
pub fn encodePkt(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const total = 4 + payload.len;
    var result = try allocator.alloc(u8, total);
    _ = std.fmt.bufPrint(result[0..4], "{x:0>4}", .{@as(u16, @intCast(total))}) catch unreachable;
    @memcpy(result[4..], payload);
    return result;
}

/// Build a receive-pack update command pkt with report-status capability.
pub fn buildPushCommand(allocator: std.mem.Allocator, old_sha: [20]u8, new_sha: [20]u8, ref_name: []const u8) ![]u8 {
    const old_hex = Sha1.hex(old_sha);
    const new_hex = Sha1.hex(new_sha);
    const zero_old = old_hex[0] == '0' and blk: {
        for (old_hex) |c| if (c != '0') break :blk false;
        break :blk true;
    };
    const line = if (zero_old)
        try std.fmt.allocPrint(allocator, "{s} {s} {s}\x00report-status agent=git/2.45.0", .{ &old_hex, &new_hex, ref_name })
    else
        try std.fmt.allocPrint(allocator, "{s} {s} {s}\x00report-status agent=git/2.45.0", .{ &old_hex, &new_hex, ref_name });
    defer allocator.free(line);
    return try encodePkt(allocator, line);
}

pub const PushReport = struct {
    unpack_ok: bool,
    ref_ok: bool,
    ng_reason: ?[]const u8,
};

/// Parse a receive-pack report-status response (pkt-line framed).
pub fn parsePushReport(allocator: std.mem.Allocator, data: []const u8) !PushReport {
    var report = PushReport{ .unpack_ok = false, .ref_ok = false, .ng_reason = null };
    var pos: usize = 0;
    while (pos + 4 <= data.len) {
        const pkt_len = std.fmt.parseInt(usize, data[pos..][0..4], 16) catch break;
        pos += 4;
        if (pkt_len == 0) continue; // flush
        if (pkt_len < 4 or pos + pkt_len - 4 > data.len) break;
        const line = std.mem.trimEnd(u8, data[pos .. pos + pkt_len - 4], &[_]u8{ '\n', '\r' });
        pos += pkt_len - 4;
        if (std.mem.startsWith(u8, line, "unpack ok")) {
            report.unpack_ok = true;
        } else if (std.mem.startsWith(u8, line, "ok ")) {
            report.ref_ok = true;
        } else if (std.mem.startsWith(u8, line, "ng ")) {
            report.ng_reason = try allocator.dupe(u8, line[3..]);
        }
    }
    return report;
}

/// Remove sideband-64k framing from an upload-pack response, returning band-1
/// (pack data) bytes concatenated.
pub fn stripSideband(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pos: usize = 0;
    while (pos + 4 <= data.len) {
        const pkt_len = std.fmt.parseInt(usize, data[pos..][0..4], 16) catch break;
        pos += 4;
        if (pkt_len == 0) continue; // flush
        if (pkt_len < 4 or pos + pkt_len - 4 > data.len) break;
        const payload = data[pos .. pos + pkt_len - 4];
        pos += pkt_len - 4;
        if (payload.len == 0) continue;
        if (payload[0] == 1) {
            try out.appendSlice(allocator, payload[1..]);
        }
        // bands 2/3 are progress/error — skip
    }
    return try out.toOwnedSlice(allocator);
}

test "encodePkt basic" {
    const allocator = std.testing.allocator;
    const pkt = try encodePkt(allocator, "done\n");
    defer allocator.free(pkt);
    try std.testing.expectEqualStrings("0009done\n", pkt);
}

test "want line with capabilities" {
    const allocator = std.testing.allocator;
    var sha: [20]u8 = undefined;
    for (&sha, 0..) |*b, i| b.* = @intCast(i % 256);
    const pkt = try buildWantLineCaps(allocator, sha, "multi_ack thin-pack ofs-delta", true);
    defer allocator.free(pkt);
    try std.testing.expect(std.mem.indexOf(u8, pkt, "want 00010203") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkt, "multi_ack thin-pack ofs-delta\n") != null);
    // Length prefix must match actual length
    const declared = try std.fmt.parseInt(usize, pkt[0..4], 16);
    try std.testing.expectEqual(pkt.len, declared);
}

test "have line format" {
    const allocator = std.testing.allocator;
    const sha: [20]u8 = @splat(0xab);
    const pkt = try buildHaveLine(allocator, sha);
    defer allocator.free(pkt);
    const hex = Sha1.hex(sha);
    try std.testing.expect(std.mem.indexOf(u8, pkt, &hex) != null);
    try std.testing.expect(std.mem.startsWith(u8, pkt, "0032have "));
}

test "push command includes report-status" {
    const allocator = std.testing.allocator;
    const old: [20]u8 = @splat(0);
    var new: [20]u8 = @splat(0x01);
    const pkt = try buildPushCommand(allocator, old, new, "refs/heads/main");
    defer allocator.free(pkt);
    try std.testing.expect(std.mem.indexOf(u8, pkt, "0000000000000000000000000000000000000000 0101010101010101010101010101010101010101 refs/heads/main") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkt, "report-status") != null);
    _ = &new;
}

test "parse push report ok" {
    const allocator = std.testing.allocator;
    const l1 = try encodePkt(allocator, "unpack ok\n");
    defer allocator.free(l1);
    const l2 = try encodePkt(allocator, "ok refs/heads/main\n");
    defer allocator.free(l2);
    const data = try std.fmt.allocPrint(allocator, "{s}{s}0000", .{ l1, l2 });
    defer allocator.free(data);
    const report = try parsePushReport(allocator, data);
    try std.testing.expect(report.unpack_ok);
    try std.testing.expect(report.ref_ok);
    try std.testing.expect(report.ng_reason == null);
}

test "parse push report rejected" {
    const allocator = std.testing.allocator;
    const l1 = try encodePkt(allocator, "unpack ok\n");
    defer allocator.free(l1);
    const l2 = try encodePkt(allocator, "ng refs/heads/main non-fast-forward\n");
    defer allocator.free(l2);
    const data = try std.fmt.allocPrint(allocator, "{s}{s}0000", .{ l1, l2 });
    defer allocator.free(data);
    const report = try parsePushReport(allocator, data);
    try std.testing.expect(report.unpack_ok);
    try std.testing.expect(!report.ref_ok);
    try std.testing.expect(report.ng_reason != null);
    try std.testing.expect(std.mem.indexOf(u8, report.ng_reason.?, "non-fast-forward") != null);
    allocator.free(report.ng_reason.?);
}

test "stripSideband extracts pack data" {
    const allocator = std.testing.allocator;
    // Two band-1 packets carrying "PACK..." pieces plus a progress packet
    // "NAK\n" is not sideband-framed in the raw stream; stripSideband only sees framed pkts.
    const data = "0009\x01PACK" ++ "0009\x02prog" ++ "0009\x01data" ++ "0000";
    const out = try stripSideband(allocator, data);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("PACKdata", out);
}
