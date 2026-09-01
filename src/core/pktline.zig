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
    defer allocator.free(want_line);
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

// =============================================================================
// TDD Bug-Hunt Tests — pktline Edge Cases
// =============================================================================

test "BUG: extractPackData with empty packets" {
    const allocator = std.testing.allocator;
    // Multiple flush packets followed by data
    const data = "0000" ++ "0000" ++ "000c" ++ "PACKDATA" ++ "0000";
    const pack = try extractPackData(allocator, data);
    defer allocator.free(pack);
    try std.testing.expectEqualStrings("PACKDATA", pack);
}

test "BUG: buildWantLine packet length" {
    const allocator = std.testing.allocator;
    const sha = Sha1.fromHex("aabbccdd11223344aabbccdd11223344aabbccdd") catch unreachable;
    const want = try buildWantLine(allocator, sha);
    defer allocator.free(want);
    // want line: "want <40hex>\n" = 5 + 40 + 1 = 46 bytes
    // pkt_len = 4 + 46 = 50 = 0x0032
    try std.testing.expectEqualStrings("0032", want[0..4]);
    try std.testing.expectEqualStrings("want aabbccdd11223344aabbccdd11223344aabbccdd\n", want[4..]);
}

test "BUG: parseRefs handles response end packet" {
    const allocator = std.testing.allocator;
    // Response end (0001) should stop parsing
    const data = "003d" ++ "0123456789abcdef0123456789abcdef01234567 refs/heads/main\n" ++ "0001";
    const refs = try parseRefs(allocator, data);
    defer {
        for (refs) |r| allocator.free(r.name);
        allocator.free(refs);
    }
    // Should parse the ref before the response end
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("refs/heads/main", refs[0].name);
}

test "BUG: doneMessage format" {
    const allocator = std.testing.allocator;
    const done = try doneMessage(allocator);
    defer allocator.free(done);
    // done message: "done\n" = 5 bytes, pkt_len = 4 + 5 = 9
    try std.testing.expectEqualStrings("0009done\n", done);
}

test "BUG: flushPacket is constant" {
    const f1 = flushPacket();
    const f2 = flushPacket();
    try std.testing.expectEqualStrings("0000", f1);
    try std.testing.expectEqualStrings("0000", f2);
}
