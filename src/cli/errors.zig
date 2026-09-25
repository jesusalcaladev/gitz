const std = @import("std");
const Io = @import("../util/io.zig").Io;

/// Single exit path for "this command cannot continue".
///
/// Every failure path used to be `io.eprint("fatal: ...")` followed by
/// `return;`, which exits 0. That made a failed `gitz push` indistinguishable
/// from a successful one for any script, CI job, or deploy pipeline reading the
/// exit status. `fatal` prints to stderr and terminates with a non-zero status,
/// so a failure is always observable.
pub const ExitSuccess: u8 = 0;
pub const ExitFailure: u8 = 1;

pub fn fatal(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    io.eprint("fatal: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(ExitFailure);
}

/// Non-fatal error message (e.g. a bad argument to an otherwise valid command).
/// Still exits non-zero: the command did not do what was asked.
pub fn errorf(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    io.eprint("error: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(ExitFailure);
}

pub fn exitWith(io: Io, code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    io.eprint(fmt ++ "\n", args) catch {};
    std.process.exit(code);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "fatal and errorf are declared noreturn and fail" {
    // `fatal`/`errorf` cannot be called here — they never return. What the
    // contract guarantees is that they are `noreturn` (so control flow after a
    // call site does not silently continue) and that they always use a
    // non-zero status. The behavioural check lives in the e2e suite, which runs
    // the real binary and asserts the process exit code.
    comptime {
        const F: *const fn (Io, []const u8, anytype) noreturn = &fatal;
        const E: *const fn (Io, []const u8, anytype) noreturn = &errorf;
        _ = F;
        _ = E;
    }
    try testing.expect(ExitFailure != ExitSuccess);
}
