const std = @import("std");
const Io = @import("../../util/io.zig").Io;

const GITHUB_REPO = "jesusalcaladev/gitz";
const VERSION = "0.3.0";

/// Execute the update command
pub fn execute(allocator: std.mem.Allocator, args: []const []const u8, io: Io) !void {
    var check_only = false;
    var force = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check") or std.mem.eql(u8, arg, "-c")) {
            check_only = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printHelp(io);
            return;
        }
    }

    try io.print("Checking for updates...\n", .{});

    // Get latest version from GitHub API
    const latest_version = getLatestVersion(allocator, io) catch |err| {
        try io.eprint("error: failed to check for updates: {}\n", .{err});
        try io.eprint("Make sure you have internet access.\n", .{});
        return;
    };
    defer if (latest_version) |v| allocator.free(v);

    if (latest_version == null) {
        try io.eprint("error: could not determine latest version\n", .{});
        return;
    }

    const current = VERSION;
    const latest = latest_version.?;

    try io.print("Current version: {s}\n", .{current});
    try io.print("Latest version:  {s}\n", .{latest});

    if (std.mem.eql(u8, current, latest) and !force) {
        try io.print("\nYou are already running the latest version.\n", .{});
        return;
    }

    if (check_only) {
        try io.print("\nA new version is available: {s} -> {s}\n", .{ current, latest });
        try io.print("Run 'gitz update' to install it.\n", .{});
        return;
    }

    // Detect platform
    const platform = detectPlatform() catch {
        try io.eprint("error: unsupported platform\n", .{});
        return;
    };

    try io.print("\nDownloading gitz {s} for {s}...\n", .{ latest, platform });

    // Find current binary path
    const current_bin = findCurrentBinary(allocator, io) catch {
        try io.eprint("error: could not find current binary location\n", .{});
        try io.eprint("Please reinstall manually from:\n", .{});
        try io.eprint("  https://github.com/{s}/releases/latest\n", .{GITHUB_REPO});
        return;
    };
    defer allocator.free(current_bin);

    try io.print("Binary location: {s}\n", .{current_bin});

    // Download and install
    downloadAndInstall(allocator, io, platform, latest, current_bin) catch |err| {
        try io.eprint("error: update failed: {}\n", .{err});
        try io.eprint("\nManual update:\n", .{});
        try io.print("  curl -fsSL https://raw.githubusercontent.com/{s}/main/install.sh | bash\n", .{GITHUB_REPO});
        return;
    };

    try io.print("\nSuccessfully updated to gitz {s}!\n", .{latest});
}

/// Print update command help
fn printHelp(io: Io) !void {
    try io.print(
        \\
        \\Usage: gitz update [options]
        \\
        \\Update gitz to the latest version.
        \\
        \\Options:
        \\  --check, -c     Check for updates without installing
        \\  --force, -f     Force update even if already on latest version
        \\  --help, -h      Show this help message
        \\
        \\Examples:
        \\  gitz update              Update to latest version
        \\  gitz update --check      Check if update is available
        \\  gitz update --force      Force reinstall current version
        \\
    , .{});
}

/// Get latest version from GitHub API
fn getLatestVersion(allocator: std.mem.Allocator, io: Io) !?[]const u8 {
    const api_url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases/latest", .{GITHUB_REPO});
    defer allocator.free(api_url);

    // Use curl to get latest release info
    const result = std.process.run(allocator, io.io, .{
        .argv = &.{ "curl", "-fsSL", api_url },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exited: u8 = switch (result.term) {
        .exited => |code| code,
        else => return null,
    };
    if (exited != 0) return null;

    // Parse tag_name from JSON response
    const tag_name = parseJsonString(allocator, result.stdout, "tag_name") catch return null;
    defer allocator.free(tag_name);

    // Strip 'v' prefix if present
    if (std.mem.startsWith(u8, tag_name, "v")) {
        return allocator.dupe(u8, tag_name[1..]) catch null;
    }

    return allocator.dupe(u8, tag_name) catch null;
}

/// Parse a string value from simple JSON
fn parseJsonString(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ![]const u8 {
    const search = try std.fmt.allocPrint(allocator, "\"{s}\":\"", .{key});
    defer allocator.free(search);

    if (std.mem.indexOf(u8, json, search)) |start_pos| {
        const value_start = start_pos + search.len;
        if (std.mem.indexOf(u8, json[value_start..], "\"")) |end_rel| {
            const end_pos = value_start + end_rel;
            return allocator.dupe(u8, json[value_start..end_pos]);
        }
    }

    return error.KeyNotFound;
}

/// Detect current platform
fn detectPlatform() ![]const u8 {
    const os = @import("builtin").os.tag;
    const arch = @import("builtin").cpu.arch;

    if (os == .linux) {
        if (arch == .x86_64) return "linux-x86_64";
        if (arch == .aarch64) return "linux-aarch64";
    } else if (os == .macos) {
        if (arch == .x86_64) return "macos-x86_64";
        if (arch == .aarch64) return "macos-aarch64";
    }

    return error.UnsupportedPlatform;
}

/// Find the current binary location
fn findCurrentBinary(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    // Try /proc/self/exe on Linux
    const exe_path = std.Io.Dir.cwd().readFileAlloc(io.io, "/proc/self/exe", allocator, .unlimited) catch {
        // Fallback: try to find in PATH
        const result = std.process.run(allocator, io.io, .{
            .argv = &.{ "which", "gitz" },
        }) catch return error.BinaryNotFound;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exited: u8 = switch (result.term) {
            .exited => |code| code,
            else => return error.BinaryNotFound,
        };

        if (exited == 0 and result.stdout.len > 0) {
            // Trim newline
            const path = std.mem.trimEnd(u8, result.stdout, &[_]u8{ '\n', '\r' });
            return allocator.dupe(u8, path);
        }

        return error.BinaryNotFound;
    };
    return exe_path;
}

/// Download and install the new binary
fn downloadAndInstall(
    allocator: std.mem.Allocator,
    io: Io,
    platform: []const u8,
    version: []const u8,
    install_path: []const u8,
) !void {
    // Construct download URL
    const download_url = try std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/releases/download/v{s}/gitz-{s}.tar.gz",
        .{ GITHUB_REPO, version, platform },
    );
    defer allocator.free(download_url);

    // Create temp directory
    _ = std.process.run(allocator, io.io, .{
        .argv = &.{ "mkdir", "-p", "/tmp/gitz-update" },
    }) catch {};

    // Download to temp file
    const tarball_path = "/tmp/gitz-update/gitz.tar.gz";
    const download_result = std.process.run(allocator, io.io, .{
        .argv = &.{ "curl", "-fsSL", download_url, "-o", tarball_path },
    }) catch return error.DownloadFailed;
    defer allocator.free(download_result.stdout);
    defer allocator.free(download_result.stderr);

    const download_exited: u8 = switch (download_result.term) {
        .exited => |code| code,
        else => return error.DownloadFailed,
    };
    if (download_exited != 0) return error.DownloadFailed;

    // Extract tarball
    const extract_result = std.process.run(allocator, io.io, .{
        .argv = &.{ "tar", "-xzf", tarball_path, "-C", "/tmp/gitz-update" },
    }) catch return error.ExtractFailed;
    defer allocator.free(extract_result.stdout);
    defer allocator.free(extract_result.stderr);

    const extract_exited: u8 = switch (extract_result.term) {
        .exited => |code| code,
        else => return error.ExtractFailed,
    };
    if (extract_exited != 0) return error.ExtractFailed;

    // Make binary executable
    _ = std.process.run(allocator, io.io, .{
        .argv = &.{ "chmod", "+x", "/tmp/gitz-update/gitz" },
    }) catch {};

    // Backup current binary
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.bak", .{install_path});
    defer allocator.free(backup_path);

    _ = std.process.run(allocator, io.io, .{
        .argv = &.{ "cp", install_path, backup_path },
    }) catch {};

    // Replace binary
    const install_result = std.process.run(allocator, io.io, .{
        .argv = &.{ "cp", "/tmp/gitz-update/gitz", install_path },
    }) catch {
        // Try to restore backup on failure
        _ = std.process.run(allocator, io.io, .{
            .argv = &.{ "cp", backup_path, install_path },
        }) catch {};
        return error.InstallFailed;
    };
    defer allocator.free(install_result.stdout);
    defer allocator.free(install_result.stderr);

    const install_exited: u8 = switch (install_result.term) {
        .exited => |code| code,
        else => {
            // Try to restore backup
            _ = std.process.run(allocator, io.io, .{
                .argv = &.{ "cp", backup_path, install_path },
            }) catch {};
            return error.InstallFailed;
        },
    };
    if (install_exited != 0) {
        // Try to restore backup
        _ = std.process.run(allocator, io.io, .{
            .argv = &.{ "cp", backup_path, install_path },
        }) catch {};
        return error.InstallFailed;
    }

    // Cleanup
    _ = std.process.run(allocator, io.io, .{
        .argv = &.{ "rm", "-rf", "/tmp/gitz-update" },
    }) catch {};

    // Remove backup on success
    _ = std.process.run(allocator, io.io, .{
        .argv = &.{ "rm", "-f", backup_path },
    }) catch {};
}

/// Check for updates and print a message if available (non-blocking)
pub fn checkForUpdates(allocator: std.mem.Allocator, io: Io) void {
    const latest_version = getLatestVersion(allocator, io) catch return;
    defer if (latest_version) |v| allocator.free(v);

    if (latest_version == null) return;

    const latest = latest_version.?;
    const current = VERSION;

    if (!std.mem.eql(u8, current, latest)) {
        io.print("\x1b[33mNew version available: {s} -> {s}\x1b[0m\n", .{ current, latest }) catch {};
        io.print("\x1b[33m  Run 'gitz update' to install\x1b[0m\n\n", .{}) catch {};
    }
}
