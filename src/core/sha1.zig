const std = @import("std");
const testing = std.testing;

/// SHA-1 implementation for Git compatibility.
/// Uses Zig's built-in SHA-1 for the core hash.
pub const Sha1 = struct {
    pub const DIGEST_LEN = 20;

    pub fn hash(data: []const u8) [DIGEST_LEN]u8 {
        var result: [DIGEST_LEN]u8 = undefined;
        std.crypto.hash.Sha1.hash(data, &result, .{});
        return result;
    }

    /// Format SHA-1 digest as hex string
    pub fn hex(digest: [DIGEST_LEN]u8) [40]u8 {
        return std.fmt.bytesToHex(digest, .lower);
    }

    /// Parse hex string to SHA-1 digest
    pub fn fromHex(hex_str: []const u8) ![DIGEST_LEN]u8 {
        if (hex_str.len != 40) return error.InvalidLength;
        var digest: [DIGEST_LEN]u8 = undefined;
        _ = try std.fmt.hexToBytes(&digest, hex_str);
        return digest;
    }

    /// Format SHA-1 as hex string into buffer
    pub fn formatHex(digest: [DIGEST_LEN]u8, buf: *[40]u8) void {
        const hex_chars = "0123456789abcdef";
        for (digest, 0..) |byte, i| {
            buf[i * 2] = hex_chars[byte >> 4];
            buf[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "sha1 empty string" {
    const result = Sha1.hash("");
    const expected = "da39a3ee5e6b4b0d3255bfef95601890afd80709";
    var hex_buf: [40]u8 = undefined;
    Sha1.formatHex(result, &hex_buf);
    try testing.expectEqualStrings(expected, &hex_buf);
}

test "sha1 'abc'" {
    const result = Sha1.hash("abc");
    const expected = "a9993e364706816aba3e25717850c26c9cd0d89d";
    var hex_buf: [40]u8 = undefined;
    Sha1.formatHex(result, &hex_buf);
    try testing.expectEqualStrings(expected, &hex_buf);
}

test "sha1 'hello world'" {
    const result = Sha1.hash("hello world");
    const expected = "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed";
    var hex_buf: [40]u8 = undefined;
    Sha1.formatHex(result, &hex_buf);
    try testing.expectEqualStrings(expected, &hex_buf);
}

test "sha1 'The quick brown fox jumps over the lazy dog'" {
    const result = Sha1.hash("The quick brown fox jumps over the lazy dog");
    // Correct SHA-1 verified with sha1sum
    const expected = "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12";
    var hex_buf: [40]u8 = undefined;
    Sha1.formatHex(result, &hex_buf);
    try testing.expectEqualStrings(expected, &hex_buf);
}

test "sha1 hex roundtrip" {
    const original = Sha1.hash("test data");
    const hex_str = Sha1.hex(original);
    const parsed = try Sha1.fromHex(&hex_str);
    try testing.expectEqual(original, parsed);
}

test "sha1 fromHex invalid length" {
    const result = Sha1.fromHex("too short");
    try testing.expectError(error.InvalidLength, result);
}
