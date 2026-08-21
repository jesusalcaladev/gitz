const std = @import("std");
const linux = std.os.linux;

/// Memory-mapped file access for zero-copy packfile reads.
pub const MmapFile = struct {
    data: []const u8,
    mapped: bool,

    /// Open and memory-map a file.
    pub fn open(path: []const u8) !MmapFile {
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch {
            return error.FileNotFound;
        };

        // Get file size using lseek to end
        const rc = linux.lseek(@intCast(fd), 0, linux.SEEK.END);
        if (@as(isize, @bitCast(rc)) < 0) {
            _ = linux.close(@intCast(fd));
            return error.StatFailed;
        }
        const size: usize = @intCast(@as(isize, @bitCast(rc)));

        if (size == 0) {
            _ = linux.close(@intCast(fd));
            return .{ .data = &.{}, .mapped = false };
        }

        // mmap the file
        const mapped_ptr = std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch {
            _ = linux.close(@intCast(fd));
            return .{ .data = &.{}, .mapped = false };
        };

        _ = linux.close(@intCast(fd));

        return .{
            .data = @ptrCast(mapped_ptr),
            .mapped = true,
        };
    }

    /// Close and unmap the file.
    pub fn close(self: *MmapFile) void {
        if (self.mapped and self.data.len > 0) {
            std.posix.munmap(@alignCast(@ptrCast(self.data.ptr)));
            self.mapped = false;
        } else if (self.data.len > 0) {
            std.heap.page_allocator.free(@constCast(self.data));
        }
        self.data = &.{};
    }

    /// Get a slice of the mapped data at a specific offset.
    pub fn slice(self: MmapFile, offset: usize, length: usize) []const u8 {
        if (offset + length > self.data.len) return &.{};
        return self.data[offset .. offset + length];
    }
};

/// Pack reader that uses mmap for zero-copy access.
pub const MmapPackReader = struct {
    mmap: MmapFile,
    version: u32,
    num_objects: u32,

    pub fn open(path: []const u8) !MmapPackReader {
        const mm = try MmapFile.open(path);
        if (mm.data.len < 12) {
            var m = mm;
            m.close();
            return error.PackTooSmall;
        }

        if (!std.mem.eql(u8, mm.data[0..4], "PACK")) {
            var m = mm;
            m.close();
            return error.InvalidPackMagic;
        }

        const version = std.mem.readInt(u32, mm.data[4..8], .big);
        const num_objects = std.mem.readInt(u32, mm.data[8..12], .big);

        return .{
            .mmap = mm,
            .version = version,
            .num_objects = num_objects,
        };
    }

    pub fn close(self: *MmapPackReader) void {
        self.mmap.close();
    }

    /// Read an object header at the given offset (zero-copy).
    pub fn getHeader(self: MmapPackReader, offset: usize) !ObjectHeader {
        if (offset >= self.mmap.data.len) return error.InvalidOffset;
        var pos = offset;
        const byte = self.mmap.data[pos];
        pos += 1;

        const obj_type: ObjectType = @enumFromInt((byte >> 4) & 0x07);
        var size: usize = byte & 0x0f;
        var shift: u6 = 4;

        var b = byte;
        while (b & 0x80 != 0) {
            if (pos >= self.mmap.data.len) return error.UnexpectedEof;
            b = self.mmap.data[pos];
            pos += 1;
            size |= @as(usize, @intCast(b & 0x7f)) << @intCast(shift);
            shift +|= 7;
        }

        return .{
            .obj_type = obj_type,
            .size = size,
            .data_start = pos,
        };
    }

    pub const ObjectType = enum(u8) {
        commit = 1,
        tree = 2,
        blob = 3,
        tag = 4,
        ofs_delta = 6,
        ref_delta = 7,
    };

    pub const ObjectHeader = struct {
        obj_type: ObjectType,
        size: usize,
        data_start: usize,
    };
};

test "mmap open non-existent" {
    const result = MmapFile.open("/nonexistent/path");
    try std.testing.expectError(error.FileNotFound, result);
}
