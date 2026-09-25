const std = @import("std");
const Fs = @import("../../util/fs.zig").Fs;
const Sha1 = @import("../../core/sha1.zig").Sha1;

const testing = std.testing;
const io = testing.io;

// ============================================================================
// Differential test harness
// ============================================================================
//
// The unit suite tests modules. It does not test what a user experiences, and
// that gap is why 140 green tests coexisted with a `merge` that silently threw
// away one side of every conflict and a `clone` that aborted with SIGABRT.
//
// These tests take a scenario, run it verbatim in a real `git` repository and
// in a real `gitz` repository, and require the two to agree on the resulting
// working tree. `git` is the oracle: it is the definition of correct behaviour,
// so the comparison cannot be satisfied by gitz agreeing with itself.

const Tool = enum { git, gitz };

/// Absolute path of the built gitz binary. `build.zig` makes the test step
/// depend on the install step, so this exists whenever the tests run.
///
/// It has to be absolute: scenarios run their child processes with `cwd` set to
/// a scratch directory, and a relative `argv[0]` would be resolved against that
/// directory instead of the project root.
fn gitzPath() ![]const u8 {
    const gpa = std.heap.page_allocator;
    const cwd = try std.process.currentPathAlloc(io, gpa);
    return std.fmt.allocPrint(gpa, "{s}/zig-out/bin/gitz", .{cwd});
}

const Step = union(enum) {
    /// Run a command; `@tool` in argv[0] is replaced by the tool under test.
    run: []const []const u8,
    /// Run a command with `dir` as the working directory, for scenarios that
    /// need more than one repository (clone, for instance).
    run_in: struct { dir: []const u8, argv: []const []const u8 },
    /// Write a file with the given content.
    write: struct { path: []const u8, content: []const u8 },
    /// Delete a file (ignored if missing).
    remove: []const u8,
    /// Assert the working tree matches between git and gitz right here.
    compare: void,
};

const RunResult = std.process.RunResult;

/// Exit status, or null when the child died on a signal. A signal death is
/// never a pass: the old `clone` aborted with SIGABRT (exit 134).
fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

fn runTool(
    gpa: std.mem.Allocator,
    t: Tool,
    gitz_bin: []const u8,
    dir: []const u8,
    argv: []const []const u8,
) !RunResult {
    var full: std.ArrayList([]const u8) = .empty;
    errdefer full.deinit(gpa);
    try full.append(gpa, if (t == .git) "git" else gitz_bin);
    for (argv) |a| try full.append(gpa, a);
    defer full.deinit(gpa);

    // A fixed identity keeps commit SHAs comparable between the two runs, and
    // avoids depending on whatever is in the developer's global git config.
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("GIT_AUTHOR_NAME", "Diff Test");
    try env.put("GIT_AUTHOR_EMAIL", "diff@test.local");
    try env.put("GIT_COMMITTER_NAME", "Diff Test");
    try env.put("GIT_COMMITTER_EMAIL", "diff@test.local");
    // A fixed clock makes the two histories byte-comparable.
    try env.put("GIT_AUTHOR_DATE", "1700000000 +0000");
    try env.put("GIT_COMMITTER_DATE", "1700000000 +0000");
    // gitz initialises on `main`; pin git to the same default so scenarios can
    // say `switch main` without depending on the machine's git config.
    try env.put("GIT_CONFIG_COUNT", "1");
    try env.put("GIT_CONFIG_KEY_0", "init.defaultBranch");
    try env.put("GIT_CONFIG_VALUE_0", "main");

    return std.process.run(gpa, io, .{
        .argv = full.items,
        .cwd = .{ .path = dir },
        .environ_map = &env,
    });
}

/// One step's outcome, so git and gitz can be compared step by step.
const StepOutcome = struct {
    code: ?u8,
    /// The command that produced this outcome, for failure messages. Null for
    /// file-manipulation steps.
    argv: ?[]const []const u8,
    /// Working tree contents after the step, as path -> content hash.
    tree: std.StringHashMap([20]u8),
};

fn snapshotTree(gpa: std.mem.Allocator, dir: []const u8) !std.StringHashMap([20]u8) {
    var map: std.StringHashMap([20]u8) = .init(gpa);
    errdefer {
        var it = map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        map.deinit();
    }
    try collectTree(gpa, dir, "", &map);
    return map;
}

fn collectTree(
    gpa: std.mem.Allocator,
    root: []const u8,
    rel: []const u8,
    map: *std.StringHashMap([20]u8),
) !void {
    const full = if (rel.len == 0)
        try gpa.dupe(u8, root)
    else
        try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, rel });
    defer gpa.free(full);

    var d = Fs.openIterable(io, full) catch return;
    defer d.close(io);

    var it = d.iterate();
    while (try it.next(io)) |entry| {
        // Repository metadata is excluded at every level, not just the root:
        // the two tools store it differently by design (`git init` drops in
        // sample hooks and an info/exclude that `gitz init` has no equivalent
        // for), and comparing it would test layout rather than behaviour.
        if (std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, ".gitz")) continue;

        const child_rel = if (rel.len == 0)
            try gpa.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.name });

        switch (entry.kind) {
            .directory => {
                defer gpa.free(child_rel);
                try collectTree(gpa, root, child_rel, map);
            },
            .file => {
                const child_full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, child_rel });
                defer gpa.free(child_full);
                const content = std.Io.Dir.cwd().readFileAlloc(io, child_full, gpa, .unlimited) catch {
                    gpa.free(child_rel);
                    continue;
                };
                defer gpa.free(content);
                // The key's ownership moves into the map.
                map.put(child_rel, Sha1.hash(content)) catch |e| {
                    gpa.free(child_rel);
                    return e;
                };
            },
            else => gpa.free(child_rel),
        }
    }
}

fn freeTree(gpa: std.mem.Allocator, map: *std.StringHashMap([20]u8)) void {
    var it = map.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    map.deinit();
}

/// Run a scenario in a fresh directory for one tool, capturing the tree after
/// every step so the comparison can point at the first divergence.
fn runScenario(
    gpa: std.mem.Allocator,
    t: Tool,
    gitz_bin: []const u8,
    base: []const u8,
    name: []const u8,
    steps: []const Step,
) ![]StepOutcome {
    const dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, name });
    defer gpa.free(dir);
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var outcomes = std.ArrayList(StepOutcome){ .items = &.{}, .capacity = 0 };
    errdefer {
        for (outcomes.items) |*o| freeTree(gpa, &o.tree);
        outcomes.deinit(gpa);
    }

    for (steps) |step| {
        var code: ?u8 = null;
        var argv: ?[]const []const u8 = null;
        switch (step) {
            .run => |a| {
                argv = a;
                const r = runTool(gpa, t, gitz_bin, dir, a) catch |e| {
                    std.debug.print("  [{s}] failed to spawn: {s}\n", .{ @tagName(t), @errorName(e) });
                    return e;
                };
                code = exitCode(r.term);
                gpa.free(r.stdout);
                gpa.free(r.stderr);
            },
            .run_in => |r| {
                argv = r.argv;
                const sub = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, r.dir });
                defer gpa.free(sub);
                try std.Io.Dir.cwd().createDirPath(io, sub);
                const res = runTool(gpa, t, gitz_bin, sub, r.argv) catch |e| {
                    std.debug.print("  [{s}] failed to spawn: {s}\n", .{ @tagName(t), @errorName(e) });
                    return e;
                };
                code = exitCode(res.term);
                gpa.free(res.stdout);
                gpa.free(res.stderr);
            },
            .write => |w| {
                const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, w.path });
                defer gpa.free(p);
                if (std.fs.path.dirname(w.path)) |d| {
                    const sub = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, d });
                    defer gpa.free(sub);
                    try std.Io.Dir.cwd().createDirPath(io, sub);
                }
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = w.content });
            },
            .remove => |p| {
                const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, p });
                defer gpa.free(full);
                std.Io.Dir.cwd().deleteFile(io, full) catch {};
            },
            .compare => {},
        }
        try outcomes.append(gpa, .{ .code = code, .argv = argv, .tree = try snapshotTree(gpa, dir) });
    }

    return outcomes.toOwnedSlice(gpa);
}

fn freeOutcomes(gpa: std.mem.Allocator, outcomes: []StepOutcome) void {
    for (outcomes) |*o| freeTree(gpa, &o.tree);
    gpa.free(outcomes);
}

const Scenario = struct {
    name: []const u8,
    steps: []const Step,
    /// Steps whose exit status must match. Most commands share a contract, but
    /// a few (like `status`) print different things while agreeing on state,
    /// and the tree comparison already covers what matters.
    compare_codes: bool,
};

/// Run one scenario under both tools and require the working trees to match.
fn expectSameAsGit(s: Scenario) !void {
    const gpa = testing.allocator;

    // Skip cleanly when the toolchain needed to compare is unavailable, rather
    // than reporting a false failure.
    const binary = gitzPath() catch {
        std.debug.print("skipping '{s}': cannot resolve cwd\n", .{s.name});
        return;
    };
    std.Io.Dir.cwd().access(io, binary, .{}) catch {
        std.debug.print("skipping '{s}': {s} not built\n", .{ s.name, binary });
        return;
    };

    const probe = try runTool(gpa, .git, binary, ".", &.{"--version"});
    defer {
        gpa.free(probe.stdout);
        gpa.free(probe.stderr);
    }
    if (exitCode(probe.term) == null) {
        std.debug.print("skipping '{s}': git not available\n", .{s.name});
        return;
    }

    const base = try std.fmt.allocPrint(gpa, "zig-cache/gitz_e2e/{s}", .{s.name});
    defer gpa.free(base);
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    const git_out = try runScenario(gpa, .git, binary, base, "git", s.steps);
    defer freeOutcomes(gpa, git_out);
    const gitz_out = try runScenario(gpa, .gitz, binary, base, "gitz", s.steps);
    defer freeOutcomes(gpa, gitz_out);

    if (git_out.len != gitz_out.len) return error.StepCountMismatch;

    for (git_out, gitz_out, 0..) |g, z, i| {
        if (s.compare_codes and g.code != z.code) {
            std.debug.print("\nscenario '{s}': exit code differs at step {d}", .{ s.name, i });
            if (g.argv) |a| {
                std.debug.print(": `", .{});
                for (a, 0..) |arg, k| {
                    if (k > 0) std.debug.print(" ", .{});
                    std.debug.print("{s}", .{arg});
                }
                std.debug.print("`", .{});
            }
            std.debug.print("\n  git  -> {?}\n  gitz -> {?}\n", .{ g.code, z.code });
            return error.ExitCodeDiverged;
        }
        if (!treesEqual(g.tree, z.tree)) {
            reportDivergence(s.name, i, g.argv, g.tree, z.tree);
            return error.WorkingTreeDiverged;
        }
    }
}

fn treesEqual(a: std.StringHashMap([20]u8), b: std.StringHashMap([20]u8)) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |e| {
        const other = b.get(e.key_ptr.*) orelse return false;
        if (!std.mem.eql(u8, &e.value_ptr.*, &other)) return false;
    }
    return true;
}

fn reportDivergence(
    name: []const u8,
    step: usize,
    argv: ?[]const []const u8,
    git_tree: std.StringHashMap([20]u8),
    gitz_tree: std.StringHashMap([20]u8),
) void {
    std.debug.print("\nscenario '{s}' diverged at step {d}", .{ name, step });
    if (argv) |a| {
        std.debug.print(": `", .{});
        for (a, 0..) |arg, k| {
            if (k > 0) std.debug.print(" ", .{});
            std.debug.print("{s}", .{arg});
        }
        std.debug.print("`", .{});
    }
    std.debug.print("\n", .{});
    var git_it = git_tree.iterator();
    while (git_it.next()) |e| {
        if (gitz_tree.get(e.key_ptr.*)) |other| {
            if (std.mem.eql(u8, &e.value_ptr.*, &other)) continue;
            std.debug.print("  {s}: content differs (git {s} vs gitz {s})\n", .{
                e.key_ptr.*, hexOf(e.value_ptr.*), hexOf(other),
            });
        } else {
            std.debug.print("  {s}: missing in gitz\n", .{e.key_ptr.*});
        }
    }
    var gitz_it = gitz_tree.iterator();
    while (gitz_it.next()) |e| {
        if (git_tree.get(e.key_ptr.*) == null) {
            std.debug.print("  {s}: unexpected in gitz\n", .{e.key_ptr.*});
        }
    }
}

/// Short, stable identifier for a content hash, for failure messages.
fn hexOf(sha: [20]u8) []const u8 {
    var buf: [40]u8 = undefined;
    const full = Sha1.hex(sha);
    @memcpy(buf[0..8], full[0..8]);
    return buf[0..8];
}

// ============================================================================
// Scenarios
// ============================================================================

test "e2e: basic init, add, commit" {
    try expectSameAsGit(.{
        .name = "basic",
        .compare_codes = true,
        .steps = &.{
            .{ .run = &.{"init"} },
            .{ .write = .{ .path = "a.txt", .content = "one\ntwo\n" } },
            .{ .run = &.{ "add", "a.txt" } },
            .{ .run = &.{ "commit", "-m", "first" } },
        },
    });
}

test "e2e: nested directories round-trip" {
    try expectSameAsGit(.{
        .name = "nested",
        .compare_codes = true,
        .steps = &.{
            .{ .run = &.{"init"} },
            .{ .write = .{ .path = "top.txt", .content = "top\n" } },
            .{ .write = .{ .path = "sub/a.txt", .content = "a\n" } },
            .{ .write = .{ .path = "sub/deep/b.txt", .content = "b\n" } },
            .{ .run = &.{ "add", "." } },
            .{ .run = &.{ "commit", "-m", "nested" } },
        },
    });
}

test "e2e: fast-forward merge" {
    try expectSameAsGit(.{
        .name = "merge_ff",
        .compare_codes = true,
        .steps = &.{
            .{ .run = &.{"init"} },
            .{ .write = .{ .path = "a.txt", .content = "one\n" } },
            .{ .run = &.{ "add", "a.txt" } },
            .{ .run = &.{ "commit", "-m", "base" } },
            .{ .run = &.{ "branch", "topic" } },
            .{ .write = .{ .path = "a.txt", .content = "one\ntwo\n" } },
            .{ .run = &.{ "add", "a.txt" } },
            .{ .run = &.{ "commit", "-m", "advance" } },
            .{ .run = &.{ "merge", "topic" } },
        },
    });
}

test "e2e: clean three-way merge, edits on different lines" {
    try expectSameAsGit(.{
        .name = "merge_clean",
        .compare_codes = true,
        .steps = &.{
            .{ .run = &.{"init"} },
            .{ .write = .{ .path = "a.txt", .content = "line1\nline2\nline3\n" } },
            .{ .run = &.{ "add", "a.txt" } },
            .{ .run = &.{ "commit", "-m", "base" } },
            .{ .run = &.{ "branch", "topic" } },
            // ours appends at the end
            .{ .write = .{ .path = "a.txt", .content = "line1\nline2\nline3\nline4\n" } },
            .{ .run = &.{ "add", "a.txt" } },
            .{ .run = &.{ "commit", "-m", "ours" } },
            .{ .run = &.{ "switch", "topic" } },
            // theirs edits an early line: must NOT be reported as a conflict
            .{ .write = .{ .path = "a.txt", .content = "line1\nline2-CHANGED\nline3\n" } },
            .{ .run = &.{ "add", "a.txt" } },
            .{ .run = &.{ "commit", "-m", "theirs" } },
            .{ .run = &.{ "switch", "main" } },
            .{ .run = &.{ "merge", "topic" } },
        },
    });
}

test "e2e: conflicting merge produces git's conflict markers" {
    try expectSameAsGit(.{
        .name = "merge_conflict",
        .compare_codes = true,
        .steps = &.{
            .{ .run = &.{"init"} },
            .{ .write = .{ .path = "f.txt", .content = "a\nb\nc\n" } },
            .{ .run = &.{ "add", "f.txt" } },
            .{ .run = &.{ "commit", "-m", "base" } },
            .{ .run = &.{ "branch", "other" } },
            .{ .write = .{ .path = "f.txt", .content = "X\nb\nc\n" } },
            .{ .run = &.{ "add", "f.txt" } },
            .{ .run = &.{ "commit", "-m", "ours" } },
            .{ .run = &.{ "switch", "other" } },
            .{ .write = .{ .path = "f.txt", .content = "Y\nb\nc\n" } },
            .{ .run = &.{ "add", "f.txt" } },
            .{ .run = &.{ "commit", "-m", "theirs" } },
            .{ .run = &.{ "switch", "main" } },
            .{ .run = &.{ "merge", "other" } },
        },
    });
}

test "e2e: both sides make the identical change" {
    try expectSameAsGit(.{
        .name = "merge_same_change",
        .compare_codes = true,
        .steps = &.{
            .{ .run = &.{"init"} },
            .{ .write = .{ .path = "f.txt", .content = "a\nb\n" } },
            .{ .run = &.{ "add", "f.txt" } },
            .{ .run = &.{ "commit", "-m", "base" } },
            .{ .run = &.{ "branch", "other" } },
            .{ .write = .{ .path = "f.txt", .content = "a\nSAME\n" } },
            .{ .run = &.{ "add", "f.txt" } },
            .{ .run = &.{ "commit", "-m", "ours" } },
            .{ .run = &.{ "switch", "other" } },
            .{ .write = .{ .path = "f.txt", .content = "a\nSAME\n" } },
            .{ .run = &.{ "add", "f.txt" } },
            .{ .run = &.{ "commit", "-m", "theirs" } },
            .{ .run = &.{ "switch", "main" } },
            .{ .run = &.{ "merge", "other" } },
        },
    });
}

test "e2e: file added on one side only" {
    try expectSameAsGit(.{
        .name = "merge_add",
        .compare_codes = true,
        .steps = &.{
            .{ .run = &.{"init"} },
            .{ .write = .{ .path = "a.txt", .content = "a\n" } },
            .{ .run = &.{ "add", "a.txt" } },
            .{ .run = &.{ "commit", "-m", "base" } },
            .{ .run = &.{ "branch", "other" } },
            .{ .write = .{ .path = "new.txt", .content = "brand new\n" } },
            .{ .run = &.{ "add", "new.txt" } },
            .{ .run = &.{ "commit", "-m", "add new" } },
            .{ .run = &.{ "switch", "main" } },
            .{ .run = &.{ "merge", "other" } },
        },
    });
}

test "e2e: file deleted on one side only" {
    try expectSameAsGit(.{
        .name = "merge_delete",
        .compare_codes = true,
        .steps = &.{
            .{ .run = &.{"init"} },
            .{ .write = .{ .path = "keep.txt", .content = "keep\n" } },
            .{ .write = .{ .path = "gone.txt", .content = "gone\n" } },
            .{ .run = &.{ "add", "." } },
            .{ .run = &.{ "commit", "-m", "base" } },
            .{ .run = &.{ "branch", "other" } },
            .{ .remove = "gone.txt" },
            .{ .run = &.{ "add", "-A" } },
            .{ .run = &.{ "commit", "-m", "delete" } },
            .{ .run = &.{ "switch", "main" } },
            .{ .run = &.{ "merge", "other" } },
        },
    });
}

test "e2e: merge across nested directories" {
    try expectSameAsGit(.{
        .name = "merge_nested",
        .compare_codes = true,
        .steps = &.{
            .{ .run = &.{"init"} },
            .{ .write = .{ .path = "sub/a.txt", .content = "a\n1\n" } },
            .{ .write = .{ .path = "sub/deep/b.txt", .content = "b\n1\n" } },
            .{ .run = &.{ "add", "." } },
            .{ .run = &.{ "commit", "-m", "base" } },
            .{ .run = &.{ "branch", "other" } },
            .{ .write = .{ .path = "sub/a.txt", .content = "a\n1\n2\n" } },
            .{ .run = &.{ "add", "." } },
            .{ .run = &.{ "commit", "-m", "ours" } },
            .{ .run = &.{ "switch", "other" } },
            .{ .write = .{ .path = "sub/deep/b.txt", .content = "b\n1\nCHANGED\n" } },
            .{ .run = &.{ "add", "." } },
            .{ .run = &.{ "commit", "-m", "theirs" } },
            .{ .run = &.{ "switch", "main" } },
            .{ .run = &.{ "merge", "other" } },
        },
    });
}

test "e2e: commit -am stages and commits modified files" {
    try expectSameAsGit(.{
        .name = "commit_am",
        .compare_codes = true,
        .steps = &.{
            .{ .run = &.{"init"} },
            .{ .write = .{ .path = "a.txt", .content = "one\n" } },
            .{ .run = &.{ "add", "a.txt" } },
            .{ .run = &.{ "commit", "-m", "base" } },
            .{ .write = .{ .path = "a.txt", .content = "one\ntwo\n" } },
            .{ .run = &.{ "commit", "-am", "second" } },
        },
    });
}

test "e2e: three-way merge after several commits on each side" {
    try expectSameAsGit(.{
        .name = "merge_multi",
        .compare_codes = true,
        .steps = &.{
            .{ .run = &.{"init"} },
            .{ .write = .{ .path = "f.txt", .content = "1\n2\n3\n4\n5\n6\n7\n8\n" } },
            .{ .run = &.{ "add", "f.txt" } },
            .{ .run = &.{ "commit", "-m", "base" } },
            .{ .run = &.{ "branch", "topic" } },
            .{ .write = .{ .path = "f.txt", .content = "HEAD\n2\n3\n4\n5\n6\n7\n8\n" } },
            .{ .run = &.{ "add", "f.txt" } },
            .{ .run = &.{ "commit", "-m", "ours 1" } },
            .{ .write = .{ .path = "f.txt", .content = "HEAD\n2\n3\n4\n5\n6\n7\n8\nOURS2\n" } },
            .{ .run = &.{ "add", "f.txt" } },
            .{ .run = &.{ "commit", "-m", "ours 2" } },
            .{ .run = &.{ "switch", "topic" } },
            .{ .write = .{ .path = "f.txt", .content = "1\n2\n3\n4\nTHEIRS5\n6\n7\n8\n" } },
            .{ .run = &.{ "add", "f.txt" } },
            .{ .run = &.{ "commit", "-m", "theirs 1" } },
            .{ .write = .{ .path = "f.txt", .content = "1\n2\n3\n4\nTHEIRS5\n6\n7\n8\nTHEIRS8\n" } },
            .{ .run = &.{ "add", "f.txt" } },
            .{ .run = &.{ "commit", "-m", "theirs 2" } },
            .{ .run = &.{ "switch", "main" } },
            .{ .run = &.{ "merge", "topic" } },
        },
    });
}

test "e2e: local clone produces the same tree as git clone" {
    try expectSameAsGit(.{
        .name = "clone_local",
        .compare_codes = true,
        .steps = &.{
            .{ .run_in = .{ .dir = "src", .argv = &.{"init"} } },
            .{ .write = .{ .path = "src/a.txt", .content = "uno\n" } },
            .{ .write = .{ .path = "src/sub/b.txt", .content = "dos\n" } },
            .{ .run_in = .{ .dir = "src", .argv = &.{ "add", "." } } },
            .{ .run_in = .{ .dir = "src", .argv = &.{ "commit", "-m", "primero" } } },
            .{ .write = .{ .path = "src/a.txt", .content = "uno\ntres\n" } },
            .{ .run_in = .{ .dir = "src", .argv = &.{ "add", "." } } },
            .{ .run_in = .{ .dir = "src", .argv = &.{ "commit", "-m", "segundo" } },
            },
            .{ .run = &.{ "clone", "src", "dst" } },
        },
    });
}

test "e2e: clone of a repository with a branch and a tag" {
    try expectSameAsGit(.{
        .name = "clone_branch",
        .compare_codes = true,
        .steps = &.{
            .{ .run_in = .{ .dir = "src", .argv = &.{"init"} } },
            .{ .write = .{ .path = "src/a.txt", .content = "uno\n" } },
            .{ .run_in = .{ .dir = "src", .argv = &.{ "add", "a.txt" } } },
            .{ .run_in = .{ .dir = "src", .argv = &.{ "commit", "-m", "primero" } } },
            .{ .run_in = .{ .dir = "src", .argv = &.{ "branch", "feature" } } },
            .{ .run_in = .{ .dir = "src", .argv = &.{ "tag", "v1" } } },
            .{ .run = &.{ "clone", "src", "dst" } },
        },
    });
}
