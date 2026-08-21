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

                    const delta_data = try decompressZlib(pack_data, hdr.content_start_after_ofs);
                    defer self.allocator.free(delta_data);

                    const result = try applyDelta(self.allocator, base_obj.data, delta_data);
                    return .{ .obj_type = base_obj.obj_type, .data = result };
                } else {
                    // Base is a full object — decompress it
                    const base_data = try decompressZlib(pack_data, base_hdr.content_start);
                    defer self.allocator.free(base_data);

                    const delta_data = try decompressZlib(pack_data, hdr.content_start_after_ofs);
                    defer self.allocator.free(delta_data);

                    const result = try applyDelta(self.allocator, base_data, delta_data);
                    return .{ .obj_type = base_hdr.obj_type, .data = result };
                }
            },
            .ref_delta => {
                // REF_DELTA: base identified by SHA-1 (20 bytes after header)
                _ = readSha(pack_data, hdr.content_start);
                const delta_data_start = hdr.content_start + 20;

                const delta_data = try decompressZlib(pack_data, delta_data_start);
                defer self.allocator.free(delta_data);

                // For now, we need to find the base object by SHA
                // In a full implementation, this would search the pack index
                return error.BaseObjectNotFound;
            },
            else => {
                // Full object — just decompress
                const data = try decompressZlib(pack_data, hdr.content_start);
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

const ObjType = enum(u8) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,
};

const ParsedHeader = struct {
    obj_type: ObjType,
    size: usize,
    content_start: usize,
    /// For ofs_delta: offset of the base object
    content_start_after_ofs: usize = 0,
};

fn parsePackHeader(data: []const u8, offset: usize) !ParsedHeader {
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

    if (obj_type_num == .ofs_delta) {
        // Parse negative offset
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
        result.content_start = pos;
        result.content_start_after_ofs = pos;
    } else if (obj_type_num == .ref_delta) {
        result.content_start = pos + 20; // Skip 20-byte SHA
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

fn readSha(data: []const u8, offset: usize) [20]u8 {
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

fn decompressZlib(data: []const u8, offset: usize) ![]u8 {
    const zlib_mod = @import("zlib.zig");
    return zlib_mod.zlib.decompress(std.heap.page_allocator, data[offset..]);
}

// ============================================================================
// Delta application
// ============================================================================

fn applyDelta(allocator: std.mem.Allocator, base: []const u8, delta: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    var dpos: usize = 0;

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
    // Simple delta: insert "Goodbye" then copy "World" from offset 6
    var delta_data: std.ArrayList(u8) = .empty;
    // Insert "Goodbye" (7 bytes)
    try delta_data.append(allocator, 7); // 0x07 = insert 7 bytes
    try delta_data.appendSlice(allocator, "Goodbye");
    // Copy from offset 6, length 5 = "World"
    try delta_data.append(allocator, 0x80 | 0x01 | 0x10); // copy with offset1 + length1
    try delta_data.append(allocator, 6); // offset = 6
    try delta_data.append(allocator, 5); // length = 5
    const delta_bytes = try delta_data.toOwnedSlice(allocator);
    defer allocator.free(delta_bytes);

    const result = try applyDelta(allocator, base, delta_bytes);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("GoodbyeWorld", result);
}
