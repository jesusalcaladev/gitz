const std = @import("std");
const Sha1 = @import("sha1.zig").Sha1;

pub const ObjectType = enum(u8) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,
};

pub fn toObjType(pot: ObjectType) ?@import("object.zig").ObjectType {
    return switch (pot) {
        .commit => .commit,
        .tree => .tree,
        .blob => .blob,
        .tag => .tag,
        .ofs_delta, .ref_delta => null,
    };
}

pub fn fromObjType(ot: @import("object.zig").ObjectType) ObjectType {
    return switch (ot) {
        .commit => .commit,
        .tree => .tree,
        .blob => .blob,
        .tag => .tag,
    };
}

pub const PackObject = struct {
    obj_type: ObjectType,
    data: []const u8,
    delta_base_sha: ?[20]u8 = null,
    delta_base_offset: ?usize = null,
};

// ============================================================================
// PACK WRITER
// ============================================================================

pub const PackWriter = struct {
    allocator: std.mem.Allocator,
    writer: std.ArrayList(u8),
    num_objects: u32,
    written_shas: std.ArrayList([20]u8),
    written_types: std.ArrayList(ObjectType),
    written_offsets: std.ArrayList(u32),

    pub fn init(allocator: std.mem.Allocator) PackWriter {
        return .{
            .allocator = allocator,
            .writer = .empty,
            .num_objects = 0,
            .written_shas = .empty,
            .written_types = .empty,
            .written_offsets = .empty,
        };
    }

    pub fn deinit(self: *PackWriter) void {
        self.writer.deinit(self.allocator);
        self.written_shas.deinit(self.allocator);
        self.written_types.deinit(self.allocator);
        self.written_offsets.deinit(self.allocator);
    }

    pub fn writeHeader(self: *PackWriter, version: u32, num_objects: u32) !void {
        self.num_objects = num_objects;
        try self.writer.appendSlice(self.allocator, "PACK");
        try self.writeU32(version);
        try self.writeU32(num_objects);
    }

    pub fn writeObject(self: *PackWriter, obj_type: ObjectType, sha: [20]u8, data: []const u8) !void {
        const offset: u32 = @intCast(self.writer.items.len);
        try self.writeTypeAndSize(obj_type, data.len);
        try self.writeZlibCompressed(data);
        try self.written_shas.append(self.allocator, sha);
        try self.written_types.append(self.allocator, obj_type);
        try self.written_offsets.append(self.allocator, offset);
        self.num_objects += 1;
    }

    pub fn finalize(self: *PackWriter) !void {
        const pack_sha = Sha1.hash(self.writer.items);
        try self.writer.appendSlice(self.allocator, &pack_sha);
    }

    pub fn getPackData(self: *PackWriter) []const u8 {
        return self.writer.items;
    }

    fn writeU32(self: *PackWriter, val: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, val, .big);
        try self.writer.appendSlice(self.allocator, &buf);
    }

    fn writeTypeAndSize(self: *PackWriter, obj_type: ObjectType, size: usize) !void {
        var byte: u8 = (@intFromEnum(obj_type) << 4) | @as(u8, @intCast(size & 0x0f));
        if (size > 0x0f) byte |= 0x80;
        try self.writer.append(self.allocator, byte);
        var remaining = size >> 4;
        while (remaining > 0) {
            byte = @intCast(remaining & 0x7f);
            remaining >>= 7;
            if (remaining > 0) byte |= 0x80;
            try self.writer.append(self.allocator, byte);
        }
    }

    fn writeZlibCompressed(self: *PackWriter, data: []const u8) !void {
        const zlib_mod = @import("zlib.zig");
        const compressed = zlib_mod.zlib.compress(self.allocator, data) catch {
            try self.writeDeflateStored(data);
            return;
        };
        defer self.allocator.free(compressed);
        try self.writer.appendSlice(self.allocator, compressed);
    }

    fn writeDeflateStored(self: *PackWriter, data: []const u8) !void {
        try self.writer.appendSlice(self.allocator, &.{ 0x78, 0x01 });
        var pos: usize = 0;
        while (pos < data.len) {
            const chunk = @min(data.len - pos, 65535);
            const is_last = (pos + chunk >= data.len);
            const bfinal: u8 = if (is_last) 1 else 0;
            try self.writer.append(self.allocator, bfinal);
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u16, len_buf[0..2], @intCast(chunk), .little);
            std.mem.writeInt(u16, len_buf[2..4], @intCast(~chunk), .little);
            try self.writer.appendSlice(self.allocator, &len_buf);
            try self.writer.appendSlice(self.allocator, data[pos .. pos + chunk]);
            pos += chunk;
        }
        const ad = adler32(data);
        var adler_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &adler_buf, ad, .big);
        try self.writer.appendSlice(self.allocator, &adler_buf);
    }
};

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

// ============================================================================
// PACK READER
// ============================================================================

pub const PackReader = struct {
    data: []const u8,
    version: u32,
    num_objects: u32,

    pub fn init(data: []const u8) !PackReader {
        if (data.len < 12) return error.PackTooSmall;
        if (!std.mem.eql(u8, data[0..4], "PACK")) return error.InvalidPackMagic;
        const version = std.mem.readInt(u32, data[4..8], .big);
        if (version != 2 and version != 3) return error.UnsupportedPackVersion;
        return .{ .data = data, .version = version, .num_objects = std.mem.readInt(u32, data[8..12], .big) };
    }

    pub fn getObjectAt(self: PackReader, offset: usize) !PackHeader {
        if (offset >= self.data.len) return error.InvalidOffset;
        var pos = offset;
        const byte = self.data[pos];
        pos += 1;
        const obj_type: ObjectType = @enumFromInt((byte >> 4) & 0x07);
        var size: usize = byte & 0x0f;
        var shift: u6 = 4;
        var b = byte;
        while (b & 0x80 != 0) {
            if (pos >= self.data.len) return error.UnexpectedEof;
            b = self.data[pos];
            pos += 1;
            size |= @as(usize, @intCast(b & 0x7f)) << @intCast(shift);
            shift +|= 7;
        }
        var ref_delta_sha: ?[20]u8 = null;
        if (obj_type == .ref_delta) {
            if (pos + 20 > self.data.len) return error.UnexpectedEof;
            var sha: [20]u8 = undefined;
            @memcpy(&sha, self.data[pos .. pos + 20]);
            ref_delta_sha = sha;
            pos += 20;
        }
        return .{ .obj_type = obj_type, .size = size, .data_offset = pos, .ref_delta_sha = ref_delta_sha };
    }
};

pub const PackHeader = struct {
    obj_type: ObjectType,
    size: usize,
    data_offset: usize,
    ref_delta_sha: ?[20]u8 = null,
};

// ============================================================================
// TOPOLOGICAL SORT — DAG-aware ordering for cache-friendly pack layout
// ============================================================================

pub fn topologicalSort(allocator: std.mem.Allocator, objects: []const ObjectWithDeps) ![]ObjectWithDeps {
    var in_degree: std.AutoHashMap(usize, u32) = .init(allocator);
    defer in_degree.deinit();
    var sha_to_idx: std.AutoHashMap([20]u8, usize) = .init(allocator);
    defer sha_to_idx.deinit();

    for (objects, 0..) |obj, i| {
        try sha_to_idx.put(obj.sha, i);
        try in_degree.put(i, 0);
    }

    for (objects, 0..) |_, i| {
        const entry = try in_degree.getOrPut(i);
        entry.value_ptr.* = 0;
    }

    for (objects, 0..) |obj, i| {
        for (obj.dep_shas) |dep_sha| {
            if (sha_to_idx.contains(dep_sha)) {
                const entry = try in_degree.getOrPut(i);
                entry.value_ptr.* += 1;
            }
        }
    }

    var queue: std.ArrayList(usize) = .empty;
    var iter = in_degree.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* == 0) try queue.append(allocator, entry.key_ptr.*);
    }
    defer queue.deinit(allocator);

    var result: std.ArrayList(ObjectWithDeps) = .empty;
    errdefer result.deinit(allocator);

    var idx: usize = 0;
    while (idx < queue.items.len) {
        const current = queue.items[idx];
        idx += 1;
        try result.append(allocator, objects[current]);
        for (objects, 0..) |_, i| {
            if (in_degree.getPtr(i)) |deg| {
                if (deg.* > 0) {
                    for (objects[i].dep_shas) |dep_sha| {
                        if (sha_to_idx.get(dep_sha)) |dep_idx| {
                            if (dep_idx == current) {
                                deg.* -= 1;
                                if (deg.* == 0) try queue.append(allocator, i);
                            }
                        }
                    }
                }
            }
        }
    }
    return try result.toOwnedSlice(allocator);
}

pub const ObjectWithDeps = struct {
    sha: [20]u8,
    obj_type: ObjectType,
    data: []const u8,
    dep_shas: []const [20]u8,
};

// ============================================================================
// DELTA COMPRESSION
// ============================================================================

pub fn computeDelta(allocator: std.mem.Allocator, base: []const u8, target: []const u8) ![]u8 {
    var delta: std.ArrayList(u8) = .empty;
    var tpos: usize = 0;
    while (tpos < target.len) {
        var best_offset: usize = 0;
        var best_length: usize = 0;
        if (base.len > 0 and target.len - tpos >= 3) {
            const needle = target[tpos .. @min(tpos + target.len - tpos, target.len)];
            var bpos: usize = 0;
            while (bpos < base.len) {
                const search_end = @min(bpos + 4096, base.len);
                if (std.mem.indexOf(u8, base[bpos..search_end], needle[0..1])) |found| {
                    const abs_pos = bpos + found;
                    var match_len: usize = 0;
                    while (match_len < needle.len and abs_pos + match_len < base.len) {
                        if (base[abs_pos + match_len] != target[tpos + match_len]) break;
                        match_len += 1;
                    }
                    if (match_len > best_length) {
                        best_offset = abs_pos;
                        best_length = match_len;
                    }
                    bpos = abs_pos + 1;
                } else break;
            }
        }
        if (best_length >= 3) {
            try writeCopyInstruction(&delta, allocator, best_offset, best_length);
            tpos += best_length;
        } else {
            var run_len: usize = 0;
            while (tpos + run_len < target.len and run_len < 127) : (run_len += 1) {}
            try delta.append(allocator, @intCast(run_len));
            try delta.appendSlice(allocator, target[tpos .. tpos + run_len]);
            tpos += run_len;
        }
    }
    return try delta.toOwnedSlice(allocator);
}

fn writeCopyInstruction(delta: *std.ArrayList(u8), allocator: std.mem.Allocator, offset: usize, length: usize) !void {
    var instr: u8 = 0x80;
    var param_bytes: [6]u8 = undefined;
    var param_len: usize = 0;
    if (offset & 0x000000ff != 0) { instr |= 0x01; param_bytes[param_len] = @intCast(offset & 0xff); param_len += 1; }
    if (offset & 0x0000ff00 != 0) { instr |= 0x02; param_bytes[param_len] = @intCast((offset >> 8) & 0xff); param_len += 1; }
    if (offset & 0x00ff0000 != 0) { instr |= 0x04; param_bytes[param_len] = @intCast((offset >> 16) & 0xff); param_len += 1; }
    if (offset & 0xff000000 != 0) { instr |= 0x08; param_bytes[param_len] = @intCast((offset >> 24) & 0xff); param_len += 1; }
    if (length & 0x00ff != 0) { instr |= 0x10; param_bytes[param_len] = @intCast(length & 0xff); param_len += 1; }
    if (length & 0xff00 != 0) { instr |= 0x20; param_bytes[param_len] = @intCast((length >> 8) & 0xff); param_len += 1; }
    if (length & 0xff0000 != 0) { instr |= 0x40; param_bytes[param_len] = @intCast((length >> 16) & 0xff); param_len += 1; }
    try delta.append(allocator, instr);
    try delta.appendSlice(allocator, param_bytes[0..param_len]);
}

pub fn applyDelta(allocator: std.mem.Allocator, base: []const u8, delta_data: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    var dpos: usize = 0;
    while (dpos < delta_data.len) {
        const instr = delta_data[dpos];
        dpos += 1;
        if (instr & 0x80 != 0) {
            var offset: usize = 0;
            var length: usize = 0;
            if (instr & 0x01 != 0) { offset |= @as(usize, delta_data[dpos]); dpos += 1; }
            if (instr & 0x02 != 0) { offset |= @as(usize, delta_data[dpos]) << 8; dpos += 1; }
            if (instr & 0x04 != 0) { offset |= @as(usize, delta_data[dpos]) << 16; dpos += 1; }
            if (instr & 0x08 != 0) { offset |= @as(usize, delta_data[dpos]) << 24; dpos += 1; }
            if (instr & 0x10 != 0) { length |= @as(usize, delta_data[dpos]); dpos += 1; }
            if (instr & 0x20 != 0) { length |= @as(usize, delta_data[dpos]) << 8; dpos += 1; }
            if (instr & 0x40 != 0) { length |= @as(usize, delta_data[dpos]) << 16; dpos += 1; }
            if (length == 0) length = 0x10000;
            if (offset + length > base.len) return error.DeltaOutOfBounds;
            try result.appendSlice(allocator, base[offset .. offset + length]);
        } else {
            const len = @as(usize, instr);
            if (dpos + len > delta_data.len) return error.DeltaTruncated;
            try result.appendSlice(allocator, delta_data[dpos .. dpos + len]);
            dpos += len;
        }
    }
    return try result.toOwnedSlice(allocator);
}

// ============================================================================
// TESTS
// ============================================================================

test "pack roundtrip" {
    const allocator = std.testing.allocator;
    var pw = PackWriter.init(allocator);
    defer pw.deinit();
    const blob_data = "Hello, world!\n";
    const blob_sha = Sha1.hash(blob_data);
    try pw.writeHeader(2, 1);
    try pw.writeObject(.blob, blob_sha, blob_data);
    try pw.finalize();
    const pack_data = pw.getPackData();
    const pr = try PackReader.init(pack_data);
    try std.testing.expectEqual(@as(u32, 1), pr.num_objects);
    const hdr = try pr.getObjectAt(12);
    try std.testing.expectEqual(ObjectType.blob, hdr.obj_type);
    try std.testing.expectEqual(blob_data.len, hdr.size);
}

test "delta roundtrip" {
    const allocator = std.testing.allocator;
    const base = "The quick brown fox jumps over the lazy dog.";
    const target = "The quick brown fox jumps over the lazy cat.";
    const delta = try computeDelta(allocator, base, target);
    defer allocator.free(delta);
    const result = try applyDelta(allocator, base, delta);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(target, result);
}

test "topological sort" {
    const allocator = std.testing.allocator;
    const sha_a = Sha1.hash("commit_a");
    const sha_b = Sha1.hash("commit_b");
    const sha_c = Sha1.hash("commit_c");
    const objects = [_]ObjectWithDeps{
        .{ .sha = sha_c, .obj_type = .commit, .data = "c", .dep_shas = &.{sha_b} },
        .{ .sha = sha_a, .obj_type = .commit, .data = "a", .dep_shas = &.{} },
        .{ .sha = sha_b, .obj_type = .commit, .data = "b", .dep_shas = &.{sha_a} },
    };
    const sorted = try topologicalSort(allocator, &objects);
    defer allocator.free(sorted);
    try std.testing.expectEqual(sha_a, sorted[0].sha);
    try std.testing.expectEqual(sha_b, sorted[1].sha);
    try std.testing.expectEqual(sha_c, sorted[2].sha);
}
