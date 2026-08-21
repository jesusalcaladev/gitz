const std = @import("std");
const cli = @import("cli/mod.zig");
const Io = @import("util/io.zig").Io;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    const io = Io.init(init.io, allocator);

    if (args.len < 2) {
        try cli.printHelp(io);
        return;
    }

    const command = args[1];
    try cli.dispatch(allocator, command, args[2..], io);
}

comptime {
    _ = @import("core/sha1.zig");
    _ = @import("core/object.zig");
    _ = @import("core/loose.zig");
    _ = @import("core/refs.zig");
    _ = @import("core/index.zig");
    _ = @import("core/ignore.zig");
    _ = @import("core/diff.zig");
    _ = @import("core/merge.zig");
    _ = @import("core/config.zig");
    _ = @import("core/stash.zig");
    _ = @import("core/delta.zig");
    _ = @import("core/packfile.zig");
    _ = @import("core/packindex.zig");
    _ = @import("core/parallel.zig");
    _ = @import("core/pktline.zig");
    _ = @import("core/mmap.zig");
    _ = @import("core/streampack.zig");
    _ = @import("core/threadpool.zig");
    _ = @import("core/objectstore.zig");
    _ = @import("core/zlib.zig");
    _ = @import("cli/commands/init.zig");
    _ = @import("cli/commands/add.zig");
    _ = @import("cli/commands/commit.zig");
    _ = @import("cli/commands/status.zig");
    _ = @import("cli/commands/log.zig");
    _ = @import("cli/commands/branch.zig");
    _ = @import("cli/commands/switch.zig");
    _ = @import("cli/commands/diff.zig");
    _ = @import("cli/commands/stash.zig");
    _ = @import("cli/commands/reset.zig");
    _ = @import("cli/commands/tag.zig");
    _ = @import("cli/commands/merge.zig");
    _ = @import("cli/commands/rebase.zig");
    _ = @import("cli/commands/undo.zig");
    _ = @import("cli/commands/blame.zig");
    _ = @import("cli/commands/gc.zig");
    _ = @import("cli/commands/remote.zig");
    _ = @import("cli/commands/clone.zig");
    _ = @import("cli/commands/fetch.zig");
    _ = @import("cli/commands/push.zig");
    _ = @import("cli/commands/pull.zig");
    _ = @import("transport/http.zig");
    _ = @import("transport/ssh.zig");
    _ = @import("transport/smart_http.zig");
    _ = @import("transport/auth.zig");
    _ = @import("cli/commands/config.zig");
    _ = @import("tests/integration/compat.zig");
}
