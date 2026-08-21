const std = @import("std");
const Sha1 = @import("../core/sha1.zig").Sha1;
const loose_mod = @import("../core/loose.zig");
const object_mod = @import("../core/object.zig");

const ObjectType = object_mod.ObjectType;
const GitObject = object_mod.GitObject;
const LooseStore = loose_mod.LooseStore;

/// Parse git's "git upload-pack" output (pkt-line format) and extract refs
pub fn parseRefs(allocator: std.mem.Allocator, data: []const u8) ![]RemoteRef {
    var result = std.ArrayList(RemoteRef){ .items = &.{}, .capacity = 0 };

    var pos: usize = 0;
    while (pos < data.len) {
        if (pos + 4 > data.len) break;
        const len_hex = data[pos .. pos + 4];
        pos += 4;

        const pkt_len = std.fmt.parseInt(u16, len_hex, 16) catch break;
        if (pkt_len == 0) continue;
        if (pkt_len < 4) break;

        const payload_len = @as(usize, pkt_len) - 4;
        if (pos + payload_len > data.len) break;
        const payload = data[pos .. pos + payload_len];
        pos += payload_len;

        const line = if (payload.len > 0 and payload[payload.len - 1] == '\n')
            payload[0 .. payload.len - 1]
        else
            payload;

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

pub const RemoteRef = struct {
    name: []const u8,
    sha: [20]u8,
};

/// Check if a URL is an SSH URL
pub fn isSshUrl(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "ssh://")) return true;
    if (std.mem.startsWith(u8, url, "git@")) return true;
    if (std.mem.indexOf(u8, url, "@")) |at_pos| {
        if (std.mem.indexOf(u8, url[at_pos + 1 ..], ":")) |_| {
            return true;
        }
    }
    return false;
}
