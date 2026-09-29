const std = @import("std");
const Sha1 = @import("../core/sha1.zig").Sha1;
const pack_ingest = @import("../core/pack_ingest.zig");
const pktline = @import("../core/pktline.zig");
const Repo = @import("../core/repo.zig").Repo;

/// Git wire protocol version 2.
///
/// Version 2 is not optional in practice: GitHub stopped serving the pack for a
/// version 0 `want`/`done` request. It still answers the version 0 ref
/// advertisement, so a version 0 client looks like it is working right up until
/// it asks for objects and silently receives an empty body.
///
/// The shape is: a capability advertisement, then a sequence of commands. Each
/// command is
///
///     command=<name>\n
///     <command arguments>\n
///     0001          <- delim, ends the command's own section
///     <command data>\n
///     0000          <- flush, ends the request
///
/// and the response is a sequence of sections introduced by a `key` line, one of
/// which is `packfile`. Everything after that `packfile` line is the raw
/// packfile -- version 2 dropped side-band framing for it.

/// One definition, shared with the version 0 parser in `core/pktline.zig`.
pub const RemoteRef = pktline.RemoteRef;

// ============================================================================
// pkt-line
// ============================================================================

pub const PktKind = enum { data, delim, flush, response_end };

pub const Pkt = struct {
    kind: PktKind,
    payload: []const u8,
};

/// Read pkt-lines from `data`.
///
/// Protocol 2 needs all four kinds distinguished: a `0001` delim ends a command's
/// argument section, a `0000` flush ends the request or the response, and a
/// `0002` marks the end of the response.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn next(self: *Reader) !?Pkt {
        if (self.pos + 4 > self.data.len) return null;
        const len_hex = self.data[self.pos .. self.pos + 4];
        self.pos += 4;

        const n = std.fmt.parseInt(u16, len_hex, 16) catch return null;
        if (n == 0) return Pkt{ .kind = .flush, .payload = &.{} };
        if (n == 1) return Pkt{ .kind = .delim, .payload = &.{} };
        if (n == 2) return Pkt{ .kind = .response_end, .payload = &.{} };
        if (n < 4) return null;

        const payload_len = @as(usize, n) - 4;
        if (self.pos + payload_len > self.data.len) return null;
        const payload = self.data[self.pos .. self.pos + payload_len];
        self.pos += payload_len;
        return Pkt{ .kind = .data, .payload = payload };
    }
};

/// Wrap `payload` as a pkt-line. A trailing newline is added when missing,
/// because every protocol 2 line is newline terminated.
pub fn encodeData(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const needs_newline = payload.len == 0 or payload[payload.len - 1] != '\n';
    const total = 4 + payload.len + @as(usize, if (needs_newline) 1 else 0);
    const out = try allocator.alloc(u8, total);

    _ = try std.fmt.bufPrint(out[0..4], "{x:0>4}", .{total});
    @memcpy(out[4 .. 4 + payload.len], payload);
    if (needs_newline) out[total - 1] = '\n';

    return out;
}

pub const delim = "0001";
pub const flush = "0000";
pub const response_end = "0002";

// ============================================================================
// capabilities
// ============================================================================

/// The server's capability list, e.g. `ls-refs=unborn`, `fetch=shallow
/// wait-for-done filter`.
pub const Capabilities = struct {
    entries: []Entry,

    pub const Entry = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn get(self: Capabilities, name: []const u8) ?[]const u8 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.value;
        }
        return null;
    }

    pub fn has(self: Capabilities, name: []const u8) bool {
        return self.get(name) != null;
    }
};

/// Parse the advertisement that opens a protocol session.
///
/// The shape decides the fallback: a version 2 session opens with
/// `version 2` followed by capabilities, while a version 0 server opens with
/// `<sha> <ref>\0<capabilities>`. Guessing version 2 when the line is absent
/// made the push path send `command=push` to a server speaking version 0, which
/// answered with nothing and the push was reported as rejected for no visible
/// reason.
///
/// Not every service supports version 2. GitHub answers `git-upload-pack` with
/// a version 2 advertisement and `git-receive-pack` with a version 0 one, and
/// git itself pushes over version 0 there.
pub const Advertisement = struct {
    /// 2 when the server opened a version 2 session, 0 when it answered in the
    /// older format, and 1 when it explicitly refused version 2.
    version: u2,
    capabilities: Capabilities,
};

pub fn parseAdvertisement(allocator: std.mem.Allocator, data: []const u8) !Advertisement {
    var reader = Reader.init(data);
    var entries: std.ArrayList(Capabilities.Entry) = .empty;
    errdefer entries.deinit(allocator);

    var version: u2 = 0;
    var first = true;

    while (try reader.next()) |pkt| {
        if (pkt.kind == .flush or pkt.kind == .delim) break;

        var lines = std.mem.splitScalar(u8, trimNewline(pkt.payload), '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;

            if (first and std.mem.startsWith(u8, line, "version ")) {
                const v = std.fmt.parseInt(u8, std.mem.trim(u8, line["version ".len..], " "), 10) catch 2;
                version = if (v == 1) 1 else 2;
                first = false;
                continue;
            }
            first = false;

            // A version 0 advertisement opens with a ref, not a capability.
            if (line.len >= 41 and line[40] == ' ') break;

            if (std.mem.indexOf(u8, line, "=")) |eq| {
                try entries.append(allocator, .{
                    .name = try allocator.dupe(u8, line[0..eq]),
                    .value = try allocator.dupe(u8, line[eq + 1 ..]),
                });
            } else {
                try entries.append(allocator, .{
                    .name = try allocator.dupe(u8, line),
                    .value = "",
                });
            }
        }
    }

    return .{ .version = version, .capabilities = .{ .entries = try entries.toOwnedSlice(allocator) } };
}

/// The `# service=git-upload-pack` preamble a smart HTTP server still sends even
/// when the client asked for version 2. The advertisement follows the flush.
pub fn skipServicePreamble(data: []const u8) []const u8 {
    var reader = Reader.init(data);
    while (reader.next() catch null) |pkt| {
        if (pkt.kind == .flush) return data[reader.pos..];
    }
    return data;
}

// ============================================================================
// ls-refs
// ============================================================================

/// Build a `ls-refs` request. `ref_prefixes` narrows what the server lists;
/// passing an empty slice asks for everything.
pub fn buildLsRefs(allocator: std.mem.Allocator, ref_prefixes: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendLine(allocator, &out, "command=ls-refs");
    try appendLine(allocator, &out, "agent=git/gitz");
    try appendLine(allocator, &out, "object-format=sha1");
    try out.appendSlice(allocator, delim);

    for (ref_prefixes) |p| {
        try appendFmt(allocator, &out, "ref-prefix {s}", .{p});
    }
    try out.appendSlice(allocator, flush);

    return out.toOwnedSlice(allocator);
}

/// Parse a `ls-refs` response.
///
/// Lines are `<sha> <refname>`, plus `unborn <refname>` for a branch with no
/// commits yet, and two attribute lines whose key is a ref name rather than a
/// keyword: `peeled <ref> <sha>` and `symref-target <ref> <target>`.
pub fn parseLsRefs(allocator: std.mem.Allocator, data: []const u8) ![]RemoteRef {
    var reader = Reader.init(data);
    var out: std.ArrayList(RemoteRef) = .empty;

    while (try reader.next()) |pkt| {
        if (pkt.kind != .data) continue;

        var lines = std.mem.splitScalar(u8, trimNewline(pkt.payload), '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len < 42) continue;

            if (std.mem.startsWith(u8, line, "unborn ")) continue;

            if (std.mem.startsWith(u8, line, "peeled ") or std.mem.startsWith(u8, line, "symref-target ")) {
                var parts = std.mem.tokenizeAny(u8, line, " ");
                _ = parts.next() orelse continue; // the keyword
                const ref_name = parts.next() orelse continue;
                const value = parts.next() orelse continue;

                for (out.items) |*r| {
                    if (!std.mem.eql(u8, r.name, ref_name)) continue;
                    if (std.mem.startsWith(u8, line, "peeled ")) {
                        r.peeled = Sha1.fromHex(value) catch null;
                    } else {
                        r.symref_target = try allocator.dupe(u8, value);
                    }
                }
                continue;
            }

            const sha = Sha1.fromHex(line[0..40]) catch continue;
            if (line[40] != ' ') continue;
            const name = line[41..];
            if (name.len == 0) continue;

            try out.append(allocator, .{ .name = try allocator.dupe(u8, name), .sha = sha });
        }
    }

    return out.toOwnedSlice(allocator);
}

// ============================================================================
// fetch
// ============================================================================

pub const FetchOptions = struct {
    /// Client identity; servers log it and some require it.
    agent: []const u8 = "git/gitz",
    want_deltas: bool = true,
};

/// Build a `fetch` request for the given wants and the commits we already have.
///
/// `thin-pack` is deliberately not requested: a thin pack omits bases it expects
/// the client to already have, and gitz would then have to resolve deltas
/// against objects outside the pack.
pub fn buildFetch(
    allocator: std.mem.Allocator,
    wants: []const [20]u8,
    haves: []const [20]u8,
    opts: FetchOptions,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendLine(allocator, &out, "command=fetch");
    try appendFmt(allocator, &out, "agent={s}", .{opts.agent});
    try appendLine(allocator, &out, "object-format=sha1");
    try out.appendSlice(allocator, delim);

    // `no-progress` keeps the server from sending progress sections we would
    // have to skip. `ofs-delta` asks for the cheaper offset-based deltas, which
    // the ingester resolves without a SHA lookup.
    try appendLine(allocator, &out, "no-progress");
    if (opts.want_deltas) try appendLine(allocator, &out, "ofs-delta");

    for (wants) |sha| {
        const hex = Sha1.hex(sha);
        try appendFmt(allocator, &out, "want {s}", .{&hex});
    }
    for (haves) |sha| {
        const hex = Sha1.hex(sha);
        try appendFmt(allocator, &out, "have {s}", .{&hex});
    }

    try appendLine(allocator, &out, "done");
    try out.appendSlice(allocator, flush);

    return out.toOwnedSlice(allocator);
}

pub const FetchResult = struct {
    /// The raw packfile. Either a borrowed slice of the response buffer or, when
    /// the pack arrived in side-band packets, an allocation the caller frees with
    /// `freeFetchResult`.
    pack: []const u8,
    /// True when `pack` is caller-owned rather than borrowed.
    pack_is_owned: bool = false,
    /// Objects the server confirmed it has, which may be used as `have` next
    /// time even when the client does not hold them locally.
    acknowledged: [][]const u8,
    server_errors: [][]const u8,

    pub fn deinit(self: FetchResult, allocator: std.mem.Allocator) void {
        if (self.pack_is_owned) allocator.free(self.pack);
        for (self.acknowledged) |a| allocator.free(a);
        allocator.free(self.acknowledged);
        for (self.server_errors) |e| allocator.free(e);
        allocator.free(self.server_errors);
    }
};

/// Where the packfile bytes begin inside a `fetch` response.
pub const PackLocation = struct {
    start: usize,
    sideband: bool,
};

/// Locate the packfile in a `fetch` response body.
///
/// After the `packfile` section header comes the pack, but the framing is not
/// uniform. GitHub sends a newline and then side-band-64k packets -- a four hex
/// digit length, one band byte, then up to 16 KiB of payload -- with band 1
/// carrying the pack. Treating those bytes as a bare packfile lands the reader
/// inside `PACK` instead of at its start, so the shape has to be detected rather
/// than assumed.
pub fn locatePack(data: []const u8) !PackLocation {
    var reader = Reader.init(data);
    while (try reader.next()) |pkt| {
        if (pkt.kind == .response_end or pkt.kind == .flush) break;
        if (pkt.kind != .data) continue;
        if (!std.mem.startsWith(u8, trimNewline(pkt.payload), "packfile")) continue;

        var at = reader.pos;
        if (at < data.len and data[at] == '\n') at += 1;

        if (startsWithPack(data, at)) return .{ .start = at, .sideband = false };
        if (looksLikeSideband(data, at)) return .{ .start = at, .sideband = true };
        return error.PackNotFound;
    }
    return error.PackNotFound;
}

fn startsWithPack(data: []const u8, at: usize) bool {
    return at + 4 <= data.len and std.mem.eql(u8, data[at..][0..4], "PACK");
}

/// A side-band packet is a plausible pkt-line length followed by a band byte.
/// Band 1 is pack data, 2 is progress, 3 is an error.
fn looksLikeSideband(data: []const u8, at: usize) bool {
    if (at + 5 > data.len) return false;
    const n = std.fmt.parseInt(u16, data[at..][0..4], 16) catch return false;
    if (n < 5) return false;
    return switch (data[at + 4]) {
        1, 2, 3 => true,
        else => false,
    };
}

/// Concatenate the band 1 payloads of a side-band-64k pack stream into a plain
/// packfile.
///
/// A band 3 packet is an error the server raised mid-transfer, which is worth
/// surfacing rather than answering with a truncated pack.
pub fn extractSidebandPack(allocator: std.mem.Allocator, data: []const u8, at: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var pos = at;
    while (pos + 4 <= data.len) {
        const n = std.fmt.parseInt(u16, data[pos..][0..4], 16) catch break;
        if (n == 0 or n == 1 or n == 2) break;
        if (n < 5 or pos + n > data.len) break;

        const band = data[pos + 4];
        switch (band) {
            1 => try out.appendSlice(allocator, data[pos + 5 .. pos + n]),
            3 => return error.ServerErrorDuringPack,
            else => {},
        }
        pos += n;
    }

    if (out.items.len == 0) return error.EmptyPack;
    return out.toOwnedSlice(allocator);
}

/// Parse a `fetch` response, returning the packfile.
///
/// Sections are `shallow-info`, `unshallow`, `acknowledgments`, `NAK` and
/// `packfile`. A server can also answer with `ERR <message>`, which is worth
/// surfacing instead of reporting an empty fetch as a success.
pub fn parseFetchResponse(allocator: std.mem.Allocator, data: []const u8) !FetchResult {
    var reader = Reader.init(data);
    var acks: std.ArrayList([]const u8) = .empty;
    errdefer acks.deinit(allocator);
    var errs: std.ArrayList([]const u8) = .empty;
    errdefer errs.deinit(allocator);

    while (try reader.next()) |pkt| {
        if (pkt.kind == .response_end or pkt.kind == .flush) break;
        if (pkt.kind != .data) continue;

        const payload = trimNewline(pkt.payload);
        if (payload.len == 0) continue;

        if (std.mem.startsWith(u8, payload, "packfile")) {
            const where = try locatePack(data);

            if (!where.sideband) {
                return .{
                    .pack = data[where.start..],
                    .acknowledged = try acks.toOwnedSlice(allocator),
                    .server_errors = try errs.toOwnedSlice(allocator),
                };
            }
            return .{
                .pack = try extractSidebandPack(allocator, data, where.start),
                .pack_is_owned = true,
                .acknowledged = try acks.toOwnedSlice(allocator),
                .server_errors = try errs.toOwnedSlice(allocator),
            };
        }
        if (std.mem.startsWith(u8, payload, "ERR ")) {
            try errs.append(allocator, try allocator.dupe(u8, payload["ERR ".len..]));
            continue;
        }
        // `acknowledgments`, `shallow-info`, `unshallow` and `NAK` carry nothing
        // this client acts on.
    }

    return .{
        .pack = &.{},
        .acknowledged = try acks.toOwnedSlice(allocator),
        .server_errors = try errs.toOwnedSlice(allocator),
    };
}

// ============================================================================
// receive-pack (push)
// ============================================================================

/// Build a `push` command for receive-pack.
///
/// The command section carries the options, the delim, then the command data:
/// one `<old> <new> <ref>` line per ref, then the flush. The packfile follows as
/// raw bytes in the same request.
pub fn buildPush(
    allocator: std.mem.Allocator,
    updates: []const Update,
    opts: PushOptions,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendLine(allocator, &out, "command=push");
    try appendFmt(allocator, &out, "agent={s}", .{opts.agent});
    try appendLine(allocator, &out, "object-format=sha1");
    // Status reporting is what makes a rejected push explainable; without it the
    // server accepts the command and says nothing about what happened to it.
    try appendLine(allocator, &out, "report-status");
    try out.appendSlice(allocator, delim);

    // The push-options section is required even when empty.
    try out.appendSlice(allocator, "push-options");
    try out.appendSlice(allocator, delim);

    for (updates) |u| {
        const old_hex = Sha1.hex(u.old_sha);
        const new_hex = Sha1.hex(u.new_sha);
        try appendFmt(allocator, &out, "{s} {s} {s}", .{ &old_hex, &new_hex, u.ref_name });
    }
    try out.appendSlice(allocator, flush);

    return out.toOwnedSlice(allocator);
}

pub const Update = struct {
    ref_name: []const u8,
    old_sha: [20]u8,
    new_sha: [20]u8,
};

pub const PushOptions = struct {
    agent: []const u8 = "git/gitz",
};

pub const PushReport = struct {
    /// Per ref, in the order the server reported them.
    results: []Result,
    unpack_error: ?[]const u8 = null,
    fatal: ?[]const u8 = null,

    pub const Result = struct {
        ref_name: []const u8,
        ok: bool,
        reason: ?[]const u8 = null,
    };

    /// Whether the server accepted every ref.
    ///
    /// An empty result is *not* a success. A response carrying neither a
    /// per-ref line nor an `unpack` line means the server never answered the way
    /// protocol 2 says it will, and treating that as success is how a push that
    /// never happened was reported as having worked.
    pub fn allOk(self: PushReport) bool {
        if (self.fatal != null or self.unpack_error != null) return false;
        if (self.results.len == 0) return false;
        for (self.results) |r| {
            if (!r.ok) return false;
        }
        return true;
    }
};

/// Parse a `push` response.
///
/// `unpack ok` or `unpack <error>`, then one `ok <ref>` / `ng <ref> <reason>`
/// per ref. A bare `ERR <message>` is fatal for the whole push.
pub fn parsePushResponse(allocator: std.mem.Allocator, data: []const u8) !PushReport {
    var reader = Reader.init(data);
    var results: std.ArrayList(PushReport.Result) = .empty;
    var unpack_error: ?[]const u8 = null;
    var fatal: ?[]const u8 = null;

    while (try reader.next()) |pkt| {
        if (pkt.kind == .response_end or pkt.kind == .flush) continue;
        if (pkt.kind != .data) continue;

        var lines = std.mem.splitScalar(u8, trimNewline(pkt.payload), '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;

            if (std.mem.eql(u8, line, "unpack ok")) {
                unpack_error = null;
            } else if (std.mem.startsWith(u8, line, "unpack ")) {
                unpack_error = try allocator.dupe(u8, line["unpack ".len..]);
            } else if (std.mem.startsWith(u8, line, "ERR ")) {
                fatal = try allocator.dupe(u8, line["ERR ".len..]);
            } else if (std.mem.startsWith(u8, line, "ok ")) {
                try results.append(allocator, .{
                    .ref_name = try allocator.dupe(u8, line["ok ".len..]),
                    .ok = true,
                });
            } else if (std.mem.startsWith(u8, line, "ng ")) {
                const rest = line["ng ".len..];
                if (std.mem.indexOf(u8, rest, " ")) |sp| {
                    try results.append(allocator, .{
                        .ref_name = try allocator.dupe(u8, rest[0..sp]),
                        .ok = false,
                        .reason = try allocator.dupe(u8, rest[sp + 1 ..]),
                    });
                } else {
                    try results.append(allocator, .{
                        .ref_name = try allocator.dupe(u8, rest),
                        .ok = false,
                    });
                }
            }
            // `option` and `push-option` lines are informational.
        }
    }

    return .{
        .results = try results.toOwnedSlice(allocator),
        .unpack_error = unpack_error,
        .fatal = fatal,
    };
}

// ============================================================================
// ingest helper
// ============================================================================

/// Unpack a fetched packfile into the repository, reporting the object count.
pub fn ingestPack(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: Repo,
    pack: []const u8,
) !u32 {
    if (pack.len == 0) return error.EmptyPack;
    const ingester = pack_ingest.Ingest.init(allocator, io, repo.common_dir);
    return ingester.run(pack);
}

// ============================================================================
// helpers
// ============================================================================

fn appendLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    const pkt = try encodeData(allocator, line);
    defer allocator.free(pkt);
    try out.appendSlice(allocator, pkt);
}

/// Append one formatted line, framed as a pkt-line.
///
/// The line is built in a stack buffer and the pkt-line around it in a heap
/// allocation that is released immediately, so building a request does not leak
/// a copy of every line it contains.
fn appendFmt(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return error.LineTooLong;
    try appendLine(allocator, out, line);
}

fn trimNewline(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\n') return s[0 .. s.len - 1];
    return s;
}

// ============================================================================
// Tests
// ============================================================================

test "encodeData frames a payload and adds the newline" {
    const gpa = std.testing.allocator;
    const pkt = try encodeData(gpa, "command=ls-refs");
    defer gpa.free(pkt);
    try std.testing.expectEqualStrings("0014command=ls-refs\n", pkt);
}

test "encodeData does not double a trailing newline" {
    const gpa = std.testing.allocator;
    const pkt = try encodeData(gpa, "object-format=sha1\n");
    defer gpa.free(pkt);
    try std.testing.expectEqualStrings("0017object-format=sha1\n", pkt);
}

test "Reader distinguishes data, delim, flush and response end" {
    const stream = "0007ok\n" ++ "0001" ++ "0000" ++ "0002";
    var r = Reader.init(stream);

    const a = (try r.next()).?;
    try std.testing.expectEqual(PktKind.data, a.kind);
    try std.testing.expectEqualStrings("ok\n", a.payload);

    try std.testing.expectEqual(PktKind.delim, (try r.next()).?.kind);
    try std.testing.expectEqual(PktKind.flush, (try r.next()).?.kind);
    try std.testing.expectEqual(PktKind.response_end, (try r.next()).?.kind);
    try std.testing.expect((try r.next()) == null);
}

test "parseAdvertisement reads version and capabilities" {
    const gpa = std.testing.allocator;
    const stream =
        "000eversion 2\n" ++
        "001aagent=git/github-1234\n" ++
        "0017object-format=sha1\n" ++
        "0000";

    const adv = try parseAdvertisement(gpa, stream);
    defer {
        for (adv.capabilities.entries) |e| {
            gpa.free(e.name);
            gpa.free(e.value);
        }
        gpa.free(adv.capabilities.entries);
    }

    try std.testing.expectEqual(@as(u2, 2), adv.version);
    try std.testing.expectEqualStrings("git/github-1234", adv.capabilities.get("agent").?);
    try std.testing.expectEqualStrings("sha1", adv.capabilities.get("object-format").?);
}

test "a version 0 advertisement is not mistaken for version 2" {
    const gpa = std.testing.allocator;
    // What git-receive-pack sends on GitHub: a ref, then capabilities after a NUL,
    // with no `version` line at all.
    const stream =
        "0061a3ce6aeba9c02048b9a443fd156a52fe4a1553ff refs/heads/main\x00report-status push-options\n" ++
        "0000";
    const adv = try parseAdvertisement(gpa, stream);
    defer gpa.free(adv.capabilities.entries);
    try std.testing.expectEqual(@as(u2, 0), adv.version);
}

test "a server that answers version 1 is reported as such" {
    const gpa = std.testing.allocator;
    const adv = try parseAdvertisement(gpa, "000eversion 1\n" ++ "0000");
    defer gpa.free(adv.capabilities.entries);
    try std.testing.expectEqual(@as(u2, 1), adv.version);
}

test "parseLsRefs reads refs and their attributes" {
    const gpa = std.testing.allocator;
    const stream =
        "003d2529185528945b5f55bc29c10fc986a48af59173 refs/heads/main\n" ++
        "003a2222222222222222222222222222222222222222 refs/tags/v1\n" ++
        "0041peeled refs/tags/v1 1111111111111111111111111111111111111111\n" ++
        "0032symref-target refs/heads/main refs/heads/main\n" ++
        "0000";

    const refs = try parseLsRefs(gpa, stream);
    defer {
        for (refs) |r| {
            gpa.free(r.name);
            if (r.symref_target) |t| gpa.free(t);
        }
        gpa.free(refs);
    }

    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("refs/heads/main", refs[0].name);
    try std.testing.expectEqualStrings("refs/heads/main", refs[0].symref_target.?);
    // The `peeled` line belongs to the tag, not to the branch it followed.
    try std.testing.expectEqualStrings("refs/tags/v1", refs[1].name);
    try std.testing.expectEqualStrings("1111111111111111111111111111111111111111", &Sha1.hex(refs[1].peeled.?));
    try std.testing.expect(refs[0].peeled == null);
}

test "parseLsRefs ignores unborn branches" {
    const gpa = std.testing.allocator;
    const stream = "0010unborn main\n" ++ "0000";
    const refs = try parseLsRefs(gpa, stream);
    defer gpa.free(refs);
    try std.testing.expectEqual(@as(usize, 0), refs.len);
}

test "buildFetch has the command, delim, wants and done in order" {
    const gpa = std.testing.allocator;
    const want = [_][20]u8{[_]u8{0xab} ** 20};
    const req = try buildFetch(gpa, &want, &.{}, .{});
    defer gpa.free(req);

    const s = try gpa.dupe(u8, req);
    defer gpa.free(s);
    const order = [_][]const u8{ "command=fetch", "object-format=sha1", "no-progress", "ofs-delta", "done" };
    var at: usize = 0;
    for (order) |needle| {
        const idx = std.mem.indexOfPos(u8, s, at, needle) orelse return error.Missing;
        at = idx + needle.len;
    }
    // A delim must separate the command section from its data.
    try std.testing.expect(std.mem.indexOf(u8, s, "0001") != null);
}

test "parseFetchResponse returns the raw pack after the packfile header" {
    const gpa = std.testing.allocator;
    const stream = "0008NAK\n" ++ "000dpackfile\n" ++ "PACK-rest-of-it-0002";
    const res = try parseFetchResponse(gpa, stream);
    defer gpa.free(res.acknowledged);
    defer gpa.free(res.server_errors);
    try std.testing.expectEqualStrings("PACK-rest-of-it-0002", res.pack);
}

test "parseFetchResponse surfaces a server ERR" {
    const gpa = std.testing.allocator;
    const stream = "0014ERR not our ref\n" ++ "0000";
    const res = try parseFetchResponse(gpa, stream);
    defer gpa.free(res.acknowledged);
    defer {
        for (res.server_errors) |e| gpa.free(e);
        gpa.free(res.server_errors);
    }
    try std.testing.expectEqual(@as(usize, 1), res.server_errors.len);
    try std.testing.expectEqualStrings("not our ref", res.server_errors[0]);
}

test "parsePushResponse separates ok from ng and keeps the reason" {
    const gpa = std.testing.allocator;
    const stream =
        "000eunpack ok\n" ++
        "000cok main\n" ++
        "0029ng refs/heads/other non-fast-forward\n" ++
        "0000";

    const report = try parsePushResponse(gpa, stream);
    defer {
        for (report.results) |r| {
            gpa.free(r.ref_name);
            if (r.reason) |x| gpa.free(x);
        }
        gpa.free(report.results);
    }

    try std.testing.expect(!report.allOk());
    try std.testing.expectEqual(@as(usize, 2), report.results.len);
    try std.testing.expect(report.results[0].ok);
    try std.testing.expect(!report.results[1].ok);
    try std.testing.expectEqualStrings("non-fast-forward", report.results[1].reason.?);
}

test "parsePushResponse reports a failed unpack" {
    const gpa = std.testing.allocator;
    const report = try parsePushResponse(gpa, "0019unpack cannot unpack\n" ++ "0000");
    defer gpa.free(report.results);
    defer gpa.free(report.unpack_error.?);
    try std.testing.expect(!report.allOk());
    try std.testing.expectEqualStrings("cannot unpack", report.unpack_error.?);
}

test "buildPush emits one update line per ref" {
    const gpa = std.testing.allocator;
    const updates = [_]Update{.{
        .ref_name = "refs/heads/main",
        .old_sha = [_]u8{0} ** 20,
        .new_sha = [_]u8{0x11} ** 20,
    }};
    const req = try buildPush(gpa, &updates, .{});
    defer gpa.free(req);

    const s = try gpa.dupe(u8, req);
    defer gpa.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "command=push") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "report-status") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 refs/heads/main") != null);
}
