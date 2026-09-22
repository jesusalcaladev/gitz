# 📦 Installation Guide

GitZ provides pre-built binaries for all major platforms, so you don't need Zig installed to use it.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/gitz/main/install.sh | bash
```

This script will:
1. Detect your platform (OS and architecture)
2. Download the latest pre-built binary (a single request — no GitHub API, no rate limits)
3. Verify its SHA-256 checksum when the release publishes `SHA256SUMS`
4. Install it atomically to `~/.local/bin` and check that it runs
5. Add it to your PATH and configure git (`gitz.defaultGitDir`)

A fresh install takes well under a second on a normal connection, and existing
installs are detected and upgraded automatically (no prompts when piped).

### Installer Options

Run the script directly to pass options:

```bash
./install.sh --help              # Show all options
./install.sh --dir "$HOME/bin"   # Custom install directory
./install.sh --force             # Reinstall even if up to date
./install.sh --source            # Build from source instead of downloading
./install.sh --no-path           # Do not touch shell configuration
./install.sh --uninstall -y      # Remove gitz non-interactively
```

### Pinned Versions

```bash
curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/gitz/main/install.sh | GITZ_VERSION=0.4.0 bash
```

### Environment Variables

| Variable | Effect |
|----------|--------|
| `INSTALL_DIR` | Same as `--dir` (default: `~/.local/bin`) |
| `GITZ_VERSION` | Install a specific release instead of the latest |
| `NO_COLOR` | Disable colored output |

## Pre-built Binaries

Download the latest binary for your platform from [GitHub Releases](https://github.com/jesusalcaladev/gitz/releases).

### Available Platforms

| Platform | Architecture | Binary |
|----------|--------------|--------|
| Linux | x86_64 | `gitz-linux-x86_64.tar.gz` |
| Linux | aarch64 | `gitz-linux-aarch64.tar.gz` |
| macOS | x86_64 (Intel) | `gitz-macos-x86_64.tar.gz` |
| macOS | aarch64 (Apple Silicon) | `gitz-macos-aarch64.tar.gz` |

Every release also publishes a `SHA256SUMS` file; the install script verifies
the download against it automatically.

### Manual Download

```bash
# Example for Linux x86_64
curl -fsSL https://github.com/jesusalcaladev/gitz/releases/latest/download/gitz-linux-x86_64.tar.gz -o gitz.tar.gz
curl -fsSL https://github.com/jesusalcaladev/gitz/releases/latest/download/SHA256SUMS -o SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS   # shasum -a 256 -c on macOS
tar -xzf gitz.tar.gz
mkdir -p ~/.local/bin
mv gitz ~/.local/bin/
chmod +x ~/.local/bin/gitz
```

## Build from Source

If you prefer to build from source or need a custom build:

### Prerequisites

- [Zig 0.16.0](https://ziglang.org/download/) or later
- Git (for cloning)

### Build Steps

```bash
# Clone the repository
git clone https://github.com/jesusalcaladev/gitz.git
cd gitz

# Build with optimizations
zig build -Doptimize=ReleaseFast

# The binary will be at:
ls -la zig-out/bin/gitz

# Install to PATH
mkdir -p ~/.local/bin
cp zig-out/bin/gitz ~/.local/bin/
export PATH="$HOME/.local/bin:$PATH"  # Add to ~/.bashrc for persistence
```

### Build Options

```bash
# Debug build (with debug symbols)
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Release build with safety checks
zig build -Doptimize=ReleaseSafe

# Build for specific target (cross-compilation)
zig build -Dtarget=aarch64-linux-gnu  # ARM64 Linux
zig build -Dtarget=x86_64-macos       # Intel macOS
```

## PATH Configuration

After installation, ensure `~/.local/bin` is in your PATH:

```bash
# Check if in PATH
echo $PATH | grep -q "$HOME/.local/bin" && echo "✓ In PATH" || echo "✗ Not in PATH"

# Add to PATH (bash)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Add to PATH (zsh)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Add to PATH (fish)
fish_add_path ~/.local/bin
```

## Verify Installation

```bash
gitz --version
gitz init --help
```

## Troubleshooting

### "command not found: gitz"

The `gitz` binary is not in your PATH. Add it:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Permission Denied

Make the binary executable:

```bash
chmod +x ~/.local/bin/gitz
```

### Wrong Architecture

If you see "Exec format error", you downloaded the wrong binary for your architecture. Check your platform:

```bash
uname -m  # x86_64 or aarch64
```

## Uninstalling

```bash
rm ~/.local/bin/gitz
```

To remove PATH configuration, edit your shell rc file (~/.bashrc, ~/.zshrc, etc.) and remove the line adding `~/.local/bin` to PATH.
