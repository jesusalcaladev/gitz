//! SHA-256, needed by the LFS pointer format (`oid sha256:<hex>`).
//!
//! LFS object IDs are SHA-256, not the repository's SHA-1. The pointer command
//! used to hash with SHA-1 and print the result under a `sha256:` label, so every
//! pointer it produced was wrong and no LFS server or `git lfs` client would
//! accept it.

const std = @import("std");

pub const Sha256 = struct {
    pub const digest_len = 32;

    state: [8]u32 = .{
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    },
    /// Total bytes hashed so far.
    length: u64 = 0,
    /// Bytes buffered in `buf`.
    buf_len: usize = 0,
    buf: [64]u8 = undefined,

    pub fn init() Sha256 {
        return .{};
    }

    pub fn update(self: *Sha256, data: []const u8) void {
        self.length +%= data.len;
        var rest = data;

        if (self.buf_len > 0) {
            const want = 64 - self.buf_len;
            const take = @min(want, rest.len);
            @memcpy(self.buf[self.buf_len..][0..take], rest[0..take]);
            self.buf_len += take;
            rest = rest[take..];
            if (self.buf_len < 64) return;
            self.compress(self.buf[0..]);
            self.buf_len = 0;
        }

        while (rest.len >= 64) {
            self.compress(rest[0..64]);
            rest = rest[64..];
        }

        if (rest.len > 0) {
            @memcpy(self.buf[0..rest.len], rest);
            self.buf_len = rest.len;
        }
    }

    pub fn final(self: *Sha256) [digest_len]u8 {
        // The message is padded with 0x80, zeroes, then the 64-bit bit length.
        const bit_len = self.length *% 8;

        self.update(&[_]u8{0x80});
        self.length -%= 1; // padding is not part of the message length

        while (self.buf_len != 56) {
            self.update(&[_]u8{0});
            self.length -%= 1;
        }

        var len_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_bytes, bit_len, .big);
        self.update(&len_bytes);

        var out: [digest_len]u8 = undefined;
        for (self.state, 0..) |word, i| {
            std.mem.writeInt(u32, out[i * 4 ..][0..4], word, .big);
        }
        return out;
    }

    /// One-shot hash.
    pub fn hash(data: []const u8) [digest_len]u8 {
        var h = Sha256.init();
        h.update(data);
        return h.final();
    }

    pub fn hex(digest: [digest_len]u8) [digest_len * 2]u8 {
        const digits = "0123456789abcdef";
        var out: [digest_len * 2]u8 = undefined;
        for (digest, 0..) |b, i| {
            out[i * 2] = digits[b >> 4];
            out[i * 2 + 1] = digits[b & 0xf];
        }
        return out;
    }

    fn compress(self: *Sha256, block: *const [64]u8) void {
        const k = [_]u32{
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        };

        var w: [64]u32 = undefined;
        for (0..16) |i| {
            w[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .big);
        }
        for (16..64) |i| {
            const s0 = std.math.rotr(u32, w[i - 15], 7) ^ std.math.rotr(u32, w[i - 15], 18) ^ (w[i - 15] >> 3);
            const s1 = std.math.rotr(u32, w[i - 2], 17) ^ std.math.rotr(u32, w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
        }

        var a = self.state[0];
        var b = self.state[1];
        var c = self.state[2];
        var d = self.state[3];
        var e = self.state[4];
        var f = self.state[5];
        var g = self.state[6];
        var h = self.state[7];

        for (0..64) |i| {
            const s1 = std.math.rotr(u32, e, 6) ^ std.math.rotr(u32, e, 11) ^ std.math.rotr(u32, e, 25);
            const ch = (e & f) ^ (~e & g);
            const temp1 = h +% s1 +% ch +% k[i] +% w[i];
            const s0 = std.math.rotr(u32, a, 2) ^ std.math.rotr(u32, a, 13) ^ std.math.rotr(u32, a, 22);
            const maj = (a & b) ^ (a & c) ^ (b & c);
            const temp2 = s0 +% maj;

            h = g;
            g = f;
            f = e;
            e = d +% temp1;
            d = c;
            c = b;
            b = a;
            a = temp1 +% temp2;
        }

        self.state[0] +%= a;
        self.state[1] +%= b;
        self.state[2] +%= c;
        self.state[3] +%= d;
        self.state[4] +%= e;
        self.state[5] +%= f;
        self.state[6] +%= g;
        self.state[7] +%= h;
    }
};

const testing = std.testing;

test "empty string matches the published digest" {
    var h = Sha256.init();
    const digest = h.final();
    var got: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&got, "{s}", .{&Sha256.hex(digest)}) catch unreachable;
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &got,
    );
}

test "abc matches the published digest" {
    var got: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&got, "{s}", .{&Sha256.hex(Sha256.hash("abc"))}) catch unreachable;
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &got,
    );
}

test "multi-block message matches the published digest" {
    // 448-bit message, so padding needs a second block.
    const got = Sha256.hex(Sha256.hash("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"));
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{s}", .{&got}) catch unreachable;
    try testing.expectEqualStrings(
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        &out,
    );
}

test "a message longer than one buffer chunk" {
    const piece = "a" ** 1000;
    var h = Sha256.init();
    for (0..3) |_| h.update(piece);

    // Streaming in pieces must equal hashing the whole message at once.
    try testing.expectEqualSlices(
        u8,
        &Sha256.hex(Sha256.hash(piece ** 3)),
        &Sha256.hex(h.final()),
    );
}
