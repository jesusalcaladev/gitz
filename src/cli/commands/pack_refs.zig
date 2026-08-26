const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const refs_mod = @import("../../core/refs.zig");

/// gitz pack-refs [--all]
/// Compacts loose refs under refs/heads and refs/tags into the git-compatible
/// packed-refs file. Loose files are removed after being folded in; reads keep
/// working transparently through the packed-refs fallback in Refs.read().
pub fn execute(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8, io: Io) !void {
    _ = args;

    const refs_manager = refs_mod.Refs.init(git_dir);
    const packed_count = refs_mod.packRefs(&refs_manager, allocator, io.io, null) catch |e| {
        try io.eprint("error: could not pack refs: {s}\n", .{@errorName(e)});
        return;
    };

    var total: usize = 0;
    if (refs_mod.loadPackedRefs(refs_manager, allocator, io.io)) |pr_val| {
        var pr = pr_val;
        defer pr.deinit(allocator);
        total = pr.entries.items.len;
    }

    try io.print("Packed {d} ref(s). Total packed refs: {d}\n", .{ packed_count, total });
}
