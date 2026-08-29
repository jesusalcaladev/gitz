const std = @import("std");
const testing = std.testing;
const Sha1 = @import("../../core/sha1.zig").Sha1;
const pktline = @import("../../core/pktline.zig");
const smart_http = @import("../../transport/smart_http.zig");

// =============================================================================
// pktline tests
// =============================================================================

test "parseRefs: empty input" {
    const allocator = testing.allocator;
    const refs = try pktline.parseRefs(allocator, "");
    defer allocator.free(refs);
    try testing.expectEqual(@as(usize, 0), refs.len);
}

test "parseRefs: single ref" {
    const allocator = testing.allocator;
    const data =
        "0032" ++ "0123456789abcdef0123456789abcdef01234567 HEAD\n";
    const refs = try pktline.parseRefs(allocator, data);
    defer {
        for (refs) |r| allocator.free(r.name);
        allocator.free(refs);
    }
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("HEAD", refs[0].name);
}

test "parseRefs: multiple refs" {
    const allocator = testing.allocator;
    const data =
        "0032" ++ "0123456789abcdef0123456789abcdef01234567 HEAD\n" ++
        "003d" ++ "0123456789abcdef0123456789abcdef01234567 refs/heads/main\n" ++
        "0040" ++ "0123456789abcdef0123456789abcdef01234567 refs/heads/feature\n" ++
        "0000";
    const refs = try pktline.parseRefs(allocator, data);
    defer {
        for (refs) |r| allocator.free(r.name);
        allocator.free(refs);
    }
    try testing.expectEqual(@as(usize, 3), refs.len);
    try testing.expectEqualStrings("HEAD", refs[0].name);
    try testing.expectEqualStrings("refs/heads/main", refs[1].name);
    try testing.expectEqualStrings("refs/heads/feature", refs[2].name);
}

test "parseRefs: with capabilities" {
    const allocator = testing.allocator;
    const data =
        "0033" ++ "0123456789abcdef0123456789abcdef01234567 HEAD\x00\n" ++
        "003c" ++ "0123456789abcdef0123456789abcdef01234567 refs/heads/main\n" ++
        "0000";
    const refs = try pktline.parseRefs(allocator, data);
    defer {
        for (refs) |r| allocator.free(r.name);
        allocator.free(refs);
    }
    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings("HEAD", refs[0].name);
    try testing.expectEqualStrings("refs/heads/main", refs[1].name);
}

test "parseRefs: flush packets skipped" {
    const allocator = testing.allocator;
    const data =
        "0000" ++
        "003d" ++ "0123456789abcdef0123456789abcdef01234567 refs/heads/main\n" ++
        "0000";
    const refs = try pktline.parseRefs(allocator, data);
    defer {
        for (refs) |r| allocator.free(r.name);
        allocator.free(refs);
    }
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("refs/heads/main", refs[0].name);
}

test "parseRefs: short packet stops parsing" {
    const allocator = testing.allocator;
    const data =
        "0001" ++
        "003d" ++ "0123456789abcdef0123456789abcdef01234567 refs/heads/main\n" ++
        "0000";
    const refs = try pktline.parseRefs(allocator, data);
    defer {
        for (refs) |r| allocator.free(r.name);
        allocator.free(refs);
    }
    try testing.expectEqual(@as(usize, 0), refs.len);
}

test "parseRefs: invalid hex stops parsing" {
    const allocator = testing.allocator;
    const data =
        "ZZZZ" ++ "bad data\n" ++
        "003d" ++ "0123456789abcdef0123456789abcdef01234567 refs/heads/main\n" ++
        "0000";
    const refs = try pktline.parseRefs(allocator, data);
    defer {
        for (refs) |r| allocator.free(r.name);
        allocator.free(refs);
    }
    try testing.expectEqual(@as(usize, 0), refs.len);
}

test "extractPackData: empty" {
    const allocator = testing.allocator;
    const data = "0000";
    const pack = try pktline.extractPackData(allocator, data);
    defer allocator.free(pack);
    try testing.expectEqual(@as(usize, 0), pack.len);
}

test "extractPackData: response end" {
    const allocator = testing.allocator;
    const data = "0001";
    const pack = try pktline.extractPackData(allocator, data);
    defer allocator.free(pack);
    try testing.expectEqual(@as(usize, 0), pack.len);
}

test "extractPackData: single packet" {
    const allocator = testing.allocator;
    const data = "000c" ++ "PACKDATA" ++ "0000";
    const pack = try pktline.extractPackData(allocator, data);
    defer allocator.free(pack);
    try testing.expectEqualStrings("PACKDATA", pack);
}

test "extractPackData: multiple packets" {
    const allocator = testing.allocator;
    const data =
        "000c" ++ "PACKDAT1" ++
        "000c" ++ "PACKDAT2" ++
        "0000";
    const pack = try pktline.extractPackData(allocator, data);
    defer allocator.free(pack);
    try testing.expectEqualStrings("PACKDAT1PACKDAT2", pack);
}

test "buildWantLine: valid SHA" {
    const allocator = testing.allocator;
    const sha = Sha1.fromHex("0123456789abcdef0123456789abcdef01234567") catch unreachable;
    const want = try pktline.buildWantLine(allocator, sha);
    defer allocator.free(want);
    try testing.expect(want.len > 44);
    try testing.expect(std.mem.startsWith(u8, want, "00"));
}

test "flushPacket: returns 0000" {
    const flush = pktline.flushPacket();
    try testing.expectEqualStrings("0000", flush);
}

test "doneMessage: returns valid pkt" {
    const allocator = testing.allocator;
    const done = try pktline.doneMessage(allocator);
    defer allocator.free(done);
    try testing.expectEqualStrings("0009done\n", done);
}

test "SmartHttp.PushResult: enum values" {
    const r1 = smart_http.SmartHttp.PushResult.ok;
    const r2 = smart_http.SmartHttp.PushResult.unpack_failed;
    const r3 = smart_http.SmartHttp.PushResult.rejected;
    const r4 = smart_http.SmartHttp.PushResult.unknown;
    try testing.expect(r1 != r2);
    try testing.expect(r2 != r3);
    try testing.expect(r3 != r4);
    try testing.expect(r4 != r1);
}

test "parseRefs: realistic GitHub response" {
    const allocator = testing.allocator;
    // 3 refs: HEAD with caps, main, develop. All pkt_lens include the trailing \n.
    // SHA(40) + " HEAD\x00\n" = 47 -> pkt_len = 51 = 0x0033
    // SHA(40) + " refs/heads/main\n" = 57 -> pkt_len = 61 = 0x003d
    // SHA(40) + " refs/heads/develop\n" = 60 -> pkt_len = 64 = 0x0040
    const data =
        "0033" ++ "0123456789abcdef0123456789abcdef01234567 HEAD\x00\n" ++
        "003d" ++ "0123456789abcdef0123456789abcdef01234567 refs/heads/main\n" ++
        "0040" ++ "0123456789abcdef0123456789abcdef01234567 refs/heads/develop\n" ++
        "0000";
    const refs = try pktline.parseRefs(allocator, data);
    defer {
        for (refs) |r| allocator.free(r.name);
        allocator.free(refs);
    }
    try testing.expectEqual(@as(usize, 3), refs.len);
    try testing.expectEqualStrings("HEAD", refs[0].name);
    try testing.expectEqualStrings("refs/heads/main", refs[1].name);
    try testing.expectEqualStrings("refs/heads/develop", refs[2].name);
}

test "parseRefs: truncated packet" {
    const allocator = testing.allocator;
    const data = "0032" ++ "short";
    const refs = try pktline.parseRefs(allocator, data);
    defer allocator.free(refs);
    try testing.expect(refs.len <= 1);
}

test "parseRefs: name too short" {
    const allocator = testing.allocator;
    const data = "002e" ++ "0123456789abcdef0123456789abcdef01234567 \n";
    const refs = try pktline.parseRefs(allocator, data);
    defer allocator.free(refs);
    try testing.expectEqual(@as(usize, 0), refs.len);
}

test "extractPackData: truncation handling" {
    const allocator = testing.allocator;
    const data = "0064" ++ "abcde";
    const pack = try pktline.extractPackData(allocator, data);
    defer allocator.free(pack);
    try testing.expectEqual(@as(usize, 0), pack.len);
}

test "parseRefs: SHA correctness" {
    const allocator = testing.allocator;
    const sha_hex = "aabbccdd11223344aabbccdd11223344aabbccdd";
    const data = "003d" ++ sha_hex ++ " refs/heads/test\n" ++ "0000";
    const refs = try pktline.parseRefs(allocator, data);
    defer {
        for (refs) |r| allocator.free(r.name);
        allocator.free(refs);
    }
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("refs/heads/test", refs[0].name);

    const expected_sha = Sha1.fromHex(sha_hex) catch unreachable;
    try testing.expectEqual(expected_sha, refs[0].sha);
}

test "parseRefs: multiple refs SHA check" {
    const allocator = testing.allocator;
    const sha1_hex = "0000000000000000000000000000000000000001";
    const sha2_hex = "0000000000000000000000000000000000000002";
    const data =
        "003a" ++ sha1_hex ++ " refs/heads/a\n" ++
        "003a" ++ sha2_hex ++ " refs/heads/b\n" ++
        "0000";
    const refs = try pktline.parseRefs(allocator, data);
    defer {
        for (refs) |r| allocator.free(r.name);
        allocator.free(refs);
    }
    try testing.expectEqual(@as(usize, 2), refs.len);

    const expected1 = Sha1.fromHex(sha1_hex) catch unreachable;
    const expected2 = Sha1.fromHex(sha2_hex) catch unreachable;
    try testing.expectEqual(expected1, refs[0].sha);
    try testing.expectEqual(expected2, refs[1].sha);
}
