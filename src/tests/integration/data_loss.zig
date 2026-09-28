const std = @import("std");
const testing = std.testing;
const diff_mod = @import("../../core/diff.zig");
const safety = @import("../../util/clone_safety.zig");

// =============================================================================
// Regression tests for the data-loss bugs fixed in the "stop losing data" pass.
//
// Each test below reproduces a failure that was verified against real git
// before the fix. They are deliberately unit-level: they pin the invariant
// (no object disappears, no untracked file is deleted, patches apply) rather
// than shelling out, so they stay fast and hermetic.
// =============================================================================

test "splitLines: a trailing newline terminates the last line, it does not add one" {
    const allocator = testing.allocator;

    // "a\nb\n" is two lines. splitScalar used to yield three, and diffing the
    // phantom empty line produced an unappliable patch.
    {
        const split = try diff_mod.splitLines(allocator, "a\nb\n");
        defer split.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), split.lines.len);
        try testing.expectEqualStrings("a", split.lines[0]);
        try testing.expectEqualStrings("b", split.lines[1]);
        try testing.expect(!split.missing_final_newline);
    }

    // "a\nb" is two lines, the second one not newline-terminated.
    {
        const split = try diff_mod.splitLines(allocator, "a\nb");
        defer split.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), split.lines.len);
        try testing.expect(split.missing_final_newline);
    }

    // "a\n\n" is "a" and an empty line: the empty line is real content.
    {
        const split = try diff_mod.splitLines(allocator, "a\n\n");
        defer split.deinit(allocator);
        try testing.expectEqual(@as(usize, 2), split.lines.len);
        try testing.expectEqualStrings("a", split.lines[0]);
        try testing.expectEqualStrings("", split.lines[1]);
    }
}

test "formatHunkHeader: a count of 1 is omitted on each side independently" {
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings(
        "@@ -1 +1 @@\n",
        try diff_mod.formatHunkHeader(&buf, 1, 1, 1, 1),
    );
    try testing.expectEqualStrings(
        "@@ -1,4 +1 @@\n",
        try diff_mod.formatHunkHeader(&buf, 1, 4, 1, 1),
    );
    try testing.expectEqualStrings(
        "@@ -1 +1,2 @@\n",
        try diff_mod.formatHunkHeader(&buf, 1, 1, 1, 2),
    );
    try testing.expectEqualStrings(
        "@@ -1,3 +1,2 @@\n",
        try diff_mod.formatHunkHeader(&buf, 1, 3, 1, 2),
    );
    // A count of 0 is always written out.
    try testing.expectEqualStrings(
        "@@ -0,0 +1,2 @@\n",
        try diff_mod.formatHunkHeader(&buf, 0, 0, 1, 2),
    );
    try testing.expectEqualStrings(
        "@@ -1,2 +0,0 @@\n",
        try diff_mod.formatHunkHeader(&buf, 1, 2, 0, 0),
    );
}

test "myersDiff on newline-terminated content produces git-appliable hunks" {
    const allocator = testing.allocator;
    var buf: [64]u8 = undefined;

    const old = try diff_mod.splitLines(allocator, "hello\n\nworld\n");
    defer old.deinit(allocator);
    const new = try diff_mod.splitLines(allocator, "changed\n");
    defer new.deinit(allocator);

    const result = try diff_mod.myersDiff(allocator, old.lines, new.lines);
    defer result.deinit(allocator);

    try testing.expect(!result.isEmpty());

    // git renders this change as:
    //   @@ -1,3 +1 @@
    //   -hello
    //   -
    //   -world
    //   +changed
    // The old file has 3 real lines (the blank one is genuine content) and the
    // new one has 1. Counting the phantom trailing line made the header
    // `@@ -1,4 +1,1 @@`, which `git apply` rejected.
    var old_seen: u32 = 0;
    var new_seen: u32 = 0;
    for (result.hunks) |hunk| {
        for (hunk.lines) |line| switch (line.type) {
            .deleted => old_seen += 1,
            .added => new_seen += 1,
            .context => {
                old_seen += 1;
                new_seen += 1;
            },
        };
        try testing.expectEqualStrings("@@ -1,3 +1 @@\n", try diff_mod.formatHunkHeader(&buf, hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count));
    }
    try testing.expectEqual(@as(u32, 3), old_seen);
    try testing.expectEqual(@as(u32, 1), new_seen);
}

test "validateWorktreePath: traversal and absolute paths are rejected" {
    // These are the entry names that let a fetched tree write outside the
    // worktree through checkout/merge/reset.
    try testing.expectError(error.UnsafeCheckoutEntryName, safety.validateWorktreePath("../../../../home/user/.bashrc"));
    try testing.expectError(error.UnsafeCheckoutEntryName, safety.validateWorktreePath("/etc/passwd"));
    try testing.expectError(error.UnsafeCheckoutEntryName, safety.validateWorktreePath("a/../../b"));
    try testing.expectError(error.UnsafeCheckoutEntryName, safety.validateWorktreePath("..\\windows"));
    try testing.expectError(error.UnsafeCheckoutEntryName, safety.validateWorktreePath("src/.gitz/hooks/post-checkout"));
    try testing.expectError(error.UnsafeCheckoutEntryName, safety.validateWorktreePath(""));

    // Ordinary nested paths stay valid.
    try safety.validateWorktreePath("a.txt");
    try safety.validateWorktreePath("src/lib/deep/file.zig");
    try safety.validateWorktreePath("src/.gitignore");
}
