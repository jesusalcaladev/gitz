const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "gitz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // Strip symbols outside Debug: smaller binary, faster download
            // and load. Debug builds keep symbols for debugging.
            .strip = if (optimize == .Debug) null else true,
            // Release artifacts are not compiled with C++ exceptions or
            // foreign unwinders. Omitting unwind metadata saves another ~7%
            // of the ReleaseSmall binary; keep it in debuggable/speed builds.
            .unwind_tables = if (optimize == .ReleaseSmall) .none else null,
        }),
    });
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run gitz");
    run_step.dependOn(&run_cmd.step);

    // Unit tests. `--test-filter` is a compiler option, not an argument for
    // the generated test binary; pass it through TestOptions.filters so the
    // documented `zig build test -- --test-filter ...` form works on Zig 0.16.
    var test_filters: []const []const u8 = &.{};
    if (b.args) |args| {
        for (args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "--test-filter") and i + 1 < args.len) {
                test_filters = args[i + 1 .. i + 2];
                break;
            }
        }
    }

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
}
