const std = @import("std");
const Io = @import("io.zig").Io;

/// GitZ terminal theme — a small shared vocabulary of ANSI styles so every
/// command speaks the same visual language.
pub const c = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const reverse = "\x1b[7m";

    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";

    // Bright accents
    pub const bgreen = "\x1b[92m";
    pub const bcyan = "\x1b[96m";
};

/// Semantic glyphs used across outputs.
pub const sym = struct {
    pub const ok = "✓";
    pub const err = "✗";
    pub const warn = "!";
    pub const arrow = "→";
    pub const dot = "•";
    pub const cursor = "▶";
};

/// Render an inline progress bar on the current line:
///   label  [████████░░░░░░]  42%  (1234/2938)
/// Caller is responsible for clearing the line when done (`clearLine`).
pub fn progressBar(io: Io, label: []const u8, done: usize, total: usize, width: usize) void {
    if (total == 0) {
        io.print("\r{s}[{s}]{s} {s}--{s}", .{ c.bold, c.reset, c.reset, c.dim, c.reset }) catch return;
        return;
    }
    const pct = done * 100 / total;
    const filled = done * width / total;

    var bar_buf: [64]u8 = undefined;
    var bar_len: usize = 0;
    var i: usize = 0;
    while (i < width and bar_len + 3 <= bar_buf.len) : (i += 1) {
        const block: []const u8 = if (i < filled) "███" else "░░░";
        @memcpy(bar_buf[bar_len..][0..block.len], block);
        bar_len += block.len;
    }

    io.print(
        "\r\x1b[K  {s}{s}{s}  [{s}{s}{s}] {s}{d:>3}%{s} {s}({d}/{d}){s}",
        .{
            c.cyan,
            label,
            c.reset,
            c.bgreen,
            bar_buf[0..bar_len],
            c.reset,
            c.bold,
            pct,
            c.reset,
            c.dim,
            done,
            total,
            c.reset,
        },
    ) catch return;
}

pub fn clearLine(io: Io) void {
    io.print("\r\x1b[K", .{}) catch return;
}

/// Shared progress state threaded through recursive walkers.
pub const Progress = struct {
    done: u32 = 0,
    total: u32 = 0,
};

/// Advance the shared counter and redraw the bar in place.
pub fn tick(io: Io, label: []const u8, p: *Progress) void {
    p.done += 1;
    progressBar(io, label, p.done, p.total, 28);
}
