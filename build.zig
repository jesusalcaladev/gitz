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
        }),
    });
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.option([]const u8, "args", "Arguments to pass to gitz (space-separated)")) |raw_args| {
        var it = std.mem.splitScalar(u8, raw_args, ' ');
        while (it.next()) |arg| {
            if (arg.len > 0) run_cmd.addArg(arg);
        }
    }
    const run_step = b.step("run", "Run gitz");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);

    // Cross-platform build step
    // Usage: zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast
    // Supported targets:
    //   -Dtarget=x86_64-linux    (Linux x86_64)
    //   -Dtarget=aarch64-linux  (Linux ARM64)
    //   -Dtarget=x86_64-macos   (macOS Intel)
    //   -Dtarget=aarch64-macos  (macOS Apple Silicon)
    //   -Dtarget=x86_64-windows (Windows x86_64)
    //
    // The install script (scripts/install.sh) automates this for all platforms.
}
