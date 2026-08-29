# 📦 Installation Guide

GitZ provides pre-built binaries for all major platforms, so you don't need Zig installed to use it.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/gitz/main/install.sh | bash
```

This script will:
1. Detect your platform (OS and architecture)
2. Download the appropriate pre-built binary
3. Install it to `~/.local/bin`
4. Add it to your PATH

## Pre-built Binaries

Download the latest binary for your platform from [GitHub Releases](https://github.com/jesusalcaladev/gitz/releases).

### Available Platforms

| Platform | Architecture | Binary |
|----------|--------------|--------|
| Linux | x86_64 | `gitz-linux-x86_64.tar.gz` |
| Linux | aarch64 | `gitz-linux-aarch64.tar.gz` |
| macOS | x86_64 (Intel) | `gitz-macos-x86_64.tar.gz` |
| macOS | aarch64 (Apple Silicon) | `gitz-macos-aarch64.tar.gz` |

### Manual Download

```bash
# Example for Linux x86_64
curl -fsSL https://github.com/jesusalcaladev/gitz/releases/latest/download/gitz-linux-x86_64.tar.gz -o gitz.tar.gz
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
