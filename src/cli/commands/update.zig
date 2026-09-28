const std = @import("std");
const Io = @import("../../util/io.zig").Io;
const Repo = @import("../../core/repo.zig").Repo;

const GITHUB_REPO = "jesusalcaladev/gitz";
const VERSION = "0.4.0";

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
    // /proc/self/exe is a symlink: it has to be *read*, not opened. The old
    // code used readFileAlloc, which slurped the entire ELF image into memory
    // and then treated those megabytes of binary as the install path -- so the
    // "current version" banner printed the whole binary to stdout and the
    // subsequent `cp` failed with E2BIG.
    if (selfExePath(allocator)) |resolved| {
        return resolved;
    } else |_| {}

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
        const path = std.mem.trimEnd(u8, result.stdout, &[_]u8{ '\n', '\r' });
        return allocator.dupe(u8, path);
    }

    return error.BinaryNotFound;
}

/// Path of the running executable, via readlink on `/proc/self/exe`.
fn selfExePath(allocator: std.mem.Allocator) ![]const u8 {
    const path_z = "/proc/self/exe";
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const written = std.os.linux.readlink(path_z, &buf, buf.len);
    if (written == 0) return error.BinaryNotFound;
    return allocator.dupe(u8, buf[0..written]);
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

    // The staging directory is private to this user and unique per run.
    //
    // It used to be the fixed path /tmp/gitz-update, created with `mkdir -p` and
    // removed with `rm -rf`. Any local user could pre-create that directory (or
    // a symlink to somewhere else), have the tarball extracted into a tree they
    // control, and have `gitz update` install their binary over gitz -- which
    // then runs with the user's privileges. The predictable path also meant two
    // concurrent updates wrote the same tarball into the same place.
    const work_dir = try privateWorkDir(allocator, io);
    defer allocator.free(work_dir);

    // Download to temp file
    const tarball_path = try std.fmt.allocPrint(allocator, "{s}/gitz.tar.gz", .{work_dir});
    defer allocator.free(tarball_path);
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
        .argv = &.{ "tar", "-xzf", tarball_path, "-C", work_dir },
    }) catch return error.ExtractFailed;
    defer allocator.free(extract_result.stdout);
    defer allocator.free(extract_result.stderr);

    const extract_exited: u8 = switch (extract_result.term) {
        .exited => |code| code,
        else => return error.ExtractFailed,
    };
    if (extract_exited != 0) return error.ExtractFailed;

    const unpacked = try std.fmt.allocPrint(allocator, "{s}/gitz", .{work_dir});
    defer allocator.free(unpacked);

    // Make binary executable
    _ = std.process.run(allocator, io.io, .{
        .argv = &.{ "chmod", "+x", unpacked },
    }) catch {};

    // Backup current binary
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.bak", .{install_path});
    defer allocator.free(backup_path);

    _ = std.process.run(allocator, io.io, .{
        .argv = &.{ "cp", install_path, backup_path },
    }) catch {};

    // Replace binary
    const install_result = std.process.run(allocator, io.io, .{
        .argv = &.{ "cp", unpacked, install_path },
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

    // Cleanup. The path is one this process created, so removing it cannot reach
    // anything another user owns.
    io.removeTree(work_dir) catch {};

    // Remove backup on success
    _ = std.process.run(allocator, io.io, .{
        .argv = &.{ "rm", "-f", backup_path },
    }) catch {};
}

/// A staging directory only this user can write to, with a name that cannot be
/// predicted or pre-created by another user.
fn privateWorkDir(allocator: std.mem.Allocator, io: Io) ![]u8 {
    // XDG_RUNTIME_DIR is per-user and already mode 0700; the temporary directory
    // is the fallback for systems that do not set it.
    const base = io.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const base_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{base}, 0);
    defer allocator.free(base_z);

    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        var seed: [8]u8 = undefined;
        if (std.os.linux.errno(std.os.linux.getrandom(&seed, seed.len, 0)) != .SUCCESS) {
            return error.NoPrivateTempDir;
        }

        var name_buf: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&name_buf, "{x}", .{&seed}) catch unreachable;
        const dir = try std.fmt.allocPrint(allocator, "{s}/gitz-update-{s}", .{ base, &name_buf });
        errdefer allocator.free(dir);

        // 0700: nobody else can enter the directory, so nothing they plant in it
        // can be picked up by the extraction or the install.
        std.Io.Dir.cwd().createDir(io.io, dir, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return dir;
    }

    return error.NoPrivateTempDir;
}

/// Check for updates and print a courtesy notice to an interactive stderr.
/// The hot command path calls this only when explicitly enabled by the user.
pub fn checkForUpdates(allocator: std.mem.Allocator, io: Io) void {
    if (!(std.Io.File.stderr().isTty(io.io) catch return)) return;

    const latest_version = getLatestVersion(allocator, io) catch return;
    defer if (latest_version) |v| allocator.free(v);

    if (latest_version == null) return;

    const latest = latest_version.?;
    const current = VERSION;

    if (!std.mem.eql(u8, current, latest)) {
        io.eprint("New version available: {s} -> {s}\n", .{ current, latest }) catch {};
        io.eprint("Run 'gitz update' to install.\n\n", .{}) catch {};
    }
}
