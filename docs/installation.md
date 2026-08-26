# Installation

## One-line Install (Linux/macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/gitz/main/scripts/install.sh | bash
```

This will:
1. Detect your platform (x86_64/aarch64, Linux/macOS)
2. Download Zig 0.16 if not installed (cached in `~/.cache/gitz/zig`)
3. Build GitZ with `ReleaseFast` optimization
4. Install the binary to `~/.local/bin/gitz`
5. Install shell completions (bash/zsh/fish)
6. Add `~/.local/bin` to your PATH

## Manual Install

### Prerequisites

- **Zig 0.16+** — [Download](https://ziglang.org/download/)
- **git** (optional) — needed only for SSH clone/push operations

### Build from Source

```bash
git clone git@github.com:jesusalcaladev/gitz.git
cd gitz

# Build with optimizations
zig build -Doptimize=ReleaseFast

# The binary is at:
ls zig-out/bin/gitz
```

### Install Globally

```bash
# Option 1: Copy to PATH
mkdir -p ~/.local/bin
cp zig-out/bin/gitz ~/.local/bin/gitz

# Option 2: Symlink
ln -s $(pwd)/zig-out/bin/gitz ~/.local/bin/gitz

# Make sure ~/.local/bin is in your PATH
export PATH="$HOME/.local/bin:$PATH"

# Verify
gitz --version
```

### Install Shell Completions

#### Bash
```bash
# Add to ~/.bashrc
source /path/to/gitz/completions/gitz.bash

# Or copy to system location
sudo cp completions/gitz.bash /etc/bash_completion.d/gitz
```

#### Zsh
```bash
# Add to ~/.zshrc
fpath=(/path/to/gitz/completions $fpath)
autoload -Uz compinit && compinit

# Or copy to system location
sudo cp completions/gitz.zsh /usr/local/share/zsh/site-functions/_gitz
```

#### Fish
```bash
cp completions/gitz.fish ~/.config/fish/completions/
```

## Cross-Platform Build

Build for specific platforms using Zig's cross-compilation:

```bash
# Linux x86_64
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast

# Linux aarch64
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseFast

# macOS x86_64
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast

# macOS ARM64
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast

# Windows x86_64
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
```

## Uninstall

```bash
bash /path/to/gitz/scripts/uninstall.sh
```

Or manually:

```bash
rm ~/.local/bin/gitz
rm -rf ~/.cache/gitz
```

## Verify Installation

```bash
gitz --version
# gitz v0.7.0

gitz --help
# Shows all available commands
```
