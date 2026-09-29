const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;

/// Delta chain resolver for packfiles.
///
/// Git packfiles store objects as deltas (ofs-delta or ref-delta) to save space.
/// When reading an object from a pack, we must:
///   1. Find the delta header (type, base reference)
///   2. Recursively resolve the base object
///   3. Apply the delta instruction stream
///   4. Return the reconstructed object data
///
/// This module handles the recursive delta resolution with cycle detection
/// and depth limits to prevent stack overflow.

pub const DeltaResolver = struct {
    allocator: std.mem.Allocator,

    /// Maximum delta chain depth before giving up.
    pub const MAX_CHAIN_DEPTH = 50;

    pub fn init(allocator: std.mem.Allocator) DeltaResolver {
        return .{ .allocator = allocator };
    }

    /// Resolve a delta chain, returning the final object data.
    /// pack_data: the full pack file data
    /// delta_offset: offset of the delta object in the pack
    /// Returns: the resolved (decompressed) object data
    pub fn resolve(
        self: DeltaResolver,
        pack_data: []const u8,
        delta_offset: usize,
    ) !ResolvedObject {
        return self.resolveDepth(pack_data, delta_offset, 0, &.{});
    }

    fn resolveDepth(
        self: DeltaResolver,
        pack_data: []const u8,
        offset: usize,
        depth: u32,
        visited: []const usize,
    ) !ResolvedObject {
        if (depth > MAX_CHAIN_DEPTH) return error.DeltaChainTooDeep;

        // Check for cycles
        for (visited) |v| {
            if (v == offset) return error.DeltaCycleDetected;
        }

        // Parse the object header
        const hdr = try parsePackHeader(pack_data, offset);

        switch (hdr.obj_type) {
            .ofs_delta => {
                // OFS_DELTA: base is at (current_offset - delta_negative_offset)
                const base_offset = try parseOfsDeltaOffset(pack_data, hdr.content_start);
                const actual_base_offset = offset - base_offset;

                // Check if base is also a delta
                const base_hdr = try parsePackHeader(pack_data, actual_base_offset);
                if (base_hdr.obj_type == .ofs_delta or base_hdr.obj_type == .ref_delta) {
                    // Base is also a delta — recurse
                    var new_visited = std.ArrayList(usize).init(self.allocator);
                    defer new_visited.deinit();
                    try new_visited.appendSlice(visited);
                    try new_visited.append(offset);

                    const base_obj = try self.resolveDepth(pack_data, actual_base_offset, depth + 1, new_visited.items);
                    defer self.allocator.free(base_obj.data);

                    const delta_data = try decompressZlibAt(self.allocator, pack_data, hdr.content_start_after_ofs);
                    defer self.allocator.free(delta_data);

                    const result = try applyDelta(self.allocator, base_obj.data, delta_data);
                    return .{ .obj_type = base_obj.obj_type, .data = result };
                } else {
                    // Base is a full object — decompress it
                    const base_data = try decompressZlibAt(self.allocator, pack_data, base_hdr.content_start);
                    defer self.allocator.free(base_data);

                    const delta_data = try decompressZlibAt(self.allocator, pack_data, hdr.content_start_after_ofs);
                    defer self.allocator.free(delta_data);

                    const result = try applyDelta(self.allocator, base_data, delta_data);
                    return .{ .obj_type = base_hdr.obj_type, .data = result };
                }
            },
            .ref_delta => {
                // REF_DELTA: base identified by SHA-1 (20 bytes after header)
                _ = readSha(pack_data, hdr.content_start);
                const delta_data_start = hdr.content_start + 20;

                const delta_data = try decompressZlibAt(self.allocator, pack_data, delta_data_start);
                defer self.allocator.free(delta_data);

                // For now, we need to find the base object by SHA
                // In a full implementation, this would search the pack index
                return error.BaseObjectNotFound;
            },
            else => {
                // Full object — just decompress
                const data = try decompressZlibAt(self.allocator, pack_data, hdr.content_start);
                return .{ .obj_type = hdr.obj_type, .data = data };
            },
        }
    }

    pub const ResolvedObject = struct {
        obj_type: PackObjType,
        data: []u8,
    };

    pub const PackObjType = enum(u8) {
        commit = 1,
        tree = 2,
        blob = 3,
        tag = 4,
    };
};

// ============================================================================
// Pack header parsing
// ============================================================================

pub const ObjType = enum(u8) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,
};

pub const ParsedHeader = struct {
    obj_type: ObjType,
    size: usize,
    content_start: usize,
    /// For ofs_delta: offset of the base object
    content_start_after_ofs: usize = 0,
};

pub fn parsePackHeader(data: []const u8, offset: usize) !ParsedHeader {
    if (offset >= data.len) return error.InvalidOffset;

    var pos = offset;
    const byte = data[pos];
    pos += 1;

    const obj_type_num: ObjType = @enumFromInt((byte >> 4) & 0x07);
    var size: usize = byte & 0x0f;
    var shift: u6 = 4;

    var b = byte;
    while (b & 0x80 != 0) {
        if (pos >= data.len) return error.UnexpectedEof;
        b = data[pos];
        pos += 1;
        size |= @as(usize, @intCast(b & 0x7f)) << @intCast(shift);
        shift +|= 7;
    }

    var result = ParsedHeader{
        .obj_type = obj_type_num,
        .size = size,
        .content_start = pos,
    };

    // For a delta, `content_start` is where the base reference begins and
    // `content_start_after_ofs` is where the delta instruction stream begins.
    // Both used to be set to the same offset, which meant the base offset and
    // the delta data were read from the same place and inflating the "delta"
    // returned whatever followed the base reference.
    if (obj_type_num == .ofs_delta) {
        const ofs_start = pos;

        if (pos >= data.len) return error.UnexpectedEof;
        var ob = data[pos];
        pos += 1;
        var ofs: usize = ob & 0x7f;
        while (ob & 0x80 != 0) {
            if (pos >= data.len) return error.UnexpectedEof;
            ob = data[pos];
            pos += 1;
            ofs = ((ofs + 1) << 7) | @as(usize, @intCast(ob & 0x7f));
        }
        result.content_start = ofs_start;
        result.content_start_after_ofs = pos;
    } else if (obj_type_num == .ref_delta) {
        // `content_start` is the 20-byte base SHA; the delta follows it.
        result.content_start = pos;
        result.content_start_after_ofs = pos + 20;
    }

    return result;
}

fn parseOfsDeltaOffset(data: []const u8, start: usize) !usize {
    var pos = start;
    var ofs: usize = 0;
    if (pos >= data.len) return error.UnexpectedEof;
    var ob = data[pos];
    pos += 1;
    ofs = ob & 0x7f;
    while (ob & 0x80 != 0) {
        if (pos >= data.len) return error.UnexpectedEof;
        ob = data[pos];
        pos += 1;
        ofs = ((ofs + 1) << 7) | @as(usize, @intCast(ob & 0x7f));
    }
    return ofs;
}

pub fn readSha(data: []const u8, offset: usize) [20]u8 {
    var sha: [20]u8 = undefined;
    if (offset + 20 <= data.len) {
        @memcpy(&sha, data[offset .. offset + 20]);
    } else {
        @memset(&sha, 0);
    }
    return sha;
}

// ============================================================================
// Zlib decompression helper
// ============================================================================

/// Inflate one zlib stream starting at `offset`.
///
/// This used the page allocator, so every resolved object leaked a whole page.
/// A clone of a real repository resolves thousands of objects, which made the
/// leak a practical problem rather than a theoretical one. The caller frees the
/// result.
pub fn decompressZlibAt(allocator: std.mem.Allocator, data: []const u8, offset: usize) ![]u8 {
    const zlib_mod = @import("zlib.zig");
    return zlib_mod.zlib.decompress(allocator, data[offset..]);
}

// ============================================================================
// Delta application
// ============================================================================

/// Read one of the size prefixes that opens a delta stream: 7 bits per byte,
/// little endian, with the high bit marking a continuation.
fn readDeltaSize(delta: []const u8, dpos: *usize) !usize {
    var value: usize = 0;
    var shift: u6 = 0;
    while (true) {
        if (dpos.* >= delta.len) return error.DeltaTruncated;
        const b = delta[dpos.*];
        dpos.* += 1;
        value |= @as(usize, b & 0x7f) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
        if (shift > 63) return error.DeltaSizeTooLarge;
    }
    return value;
}

pub fn applyDelta(allocator: std.mem.Allocator, base: []const u8, delta: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    var dpos: usize = 0;

    // A delta stream opens with the size of the base object and the size of the
    // result, both as varints, before any instruction. Starting at the first
    // instruction read a size byte as an opcode, so a real packfile failed with
    // `DeltaOutOfBounds` on its first delta.
    const base_size = try readDeltaSize(delta, &dpos);
    if (base_size != base.len) return error.DeltaBaseSizeMismatch;
    // The result size is implied by the instructions, but it is part of the
    // stream and has to be consumed.
    _ = try readDeltaSize(delta, &dpos);

    while (dpos < delta.len) {
        const instr = delta[dpos];
        dpos += 1;

        if (instr & 0x80 != 0) {
            // Copy instruction
            var offset: usize = 0;
            var length: usize = 0;

            if (instr & 0x01 != 0) { offset |= @as(usize, delta[dpos]); dpos += 1; }
            if (instr & 0x02 != 0) { offset |= @as(usize, delta[dpos]) << 8; dpos += 1; }
            if (instr & 0x04 != 0) { offset |= @as(usize, delta[dpos]) << 16; dpos += 1; }
            if (instr & 0x08 != 0) { offset |= @as(usize, delta[dpos]) << 24; dpos += 1; }

            if (instr & 0x10 != 0) { length |= @as(usize, delta[dpos]); dpos += 1; }
            if (instr & 0x20 != 0) { length |= @as(usize, delta[dpos]) << 8; dpos += 1; }
            if (instr & 0x40 != 0) { length |= @as(usize, delta[dpos]) << 16; dpos += 1; }

            if (length == 0) length = 0x10000;

            if (offset + length > base.len) return error.DeltaOutOfBounds;
            try result.appendSlice(allocator, base[offset .. offset + length]);
        } else {
            // Insert instruction
            const len = @as(usize, instr);
            if (dpos + len > delta.len) return error.DeltaTruncated;
            try result.appendSlice(allocator, delta[dpos .. dpos + len]);
            dpos += len;
        }
    }

    return try result.toOwnedSlice(allocator);
}

test "delta apply copy+insert" {
    const allocator = std.testing.allocator;
    const base = "Hello World";

    var delta_data: std.ArrayList(u8) = .empty;
    // A real delta stream opens with the base size and the result size. The
    // original test omitted them, which matched the bug where those bytes were
    // read as instructions.
    try delta_data.append(allocator, base.len); // base size varint
    try delta_data.append(allocator, 12); // result size varint: "GoodbyeWorld"
    // Insert "Goodbye" (7 bytes)
    try delta_data.append(allocator, 7);
    try delta_data.appendSlice(allocator, "Goodbye");
    // Copy from offset 6, length 5 = "World"
    try delta_data.append(allocator, 0x80 | 0x01 | 0x10);
    try delta_data.append(allocator, 6);
    try delta_data.append(allocator, 5);
    const delta_bytes = try delta_data.toOwnedSlice(allocator);
    defer allocator.free(delta_bytes);

    const result = try applyDelta(allocator, base, delta_bytes);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("GoodbyeWorld", result);
}

test "delta stream whose base size disagrees with the base is rejected" {
    const allocator = std.testing.allocator;
    // Claims a 4 byte base but is handed an 11 byte one. Resolving against the
    // wrong base is how a copy instruction ends up reading outside it, so the
    // mismatch has to be caught up front.
    var delta_data: std.ArrayList(u8) = .empty;
    try delta_data.append(allocator, 4);
    try delta_data.append(allocator, 1);
    try delta_data.append(allocator, 1);
    try delta_data.append(allocator, 'x');
    const delta_bytes = try delta_data.toOwnedSlice(allocator);
    defer allocator.free(delta_bytes);

    try std.testing.expectError(
        error.DeltaBaseSizeMismatch,
        applyDelta(allocator, "Hello World", delta_bytes),
    );
}

test "delta size prefixes may span several bytes" {
    const allocator = std.testing.allocator;
    // base size 341 encodes as 0xd5 0x02, which is what a real packfile used.
    var delta_data: std.ArrayList(u8) = .empty;
    try delta_data.append(allocator, 0xd5);
    try delta_data.append(allocator, 0x02);
    try delta_data.append(allocator, 3); // result size
    try delta_data.append(allocator, 3);
    try delta_data.appendSlice(allocator, "abc");
    const delta_bytes = try delta_data.toOwnedSlice(allocator);
    defer allocator.free(delta_bytes);

    const base = try allocator.alloc(u8, 341);
    defer allocator.free(base);
    @memset(base, 'x');

    const result = try applyDelta(allocator, base, delta_bytes);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("abc", result);
}
