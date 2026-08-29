#!/bin/bash
#
# install.sh — Install gitz on any system
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/gitz/main/install.sh | bash
#   or: ./install.sh
#
# Requirements:
#   - Linux (x86_64, aarch64) or macOS (x86_64, aarch64)
#   - curl or wget (for downloading)
#   - tar (for extracting)
#

set -e

GITHUB_REPO="jesusalcaladev/gitz"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
BINARY_NAME="gitz"
ZIG_VERSION="0.16.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}ℹ${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }

# Detect OS and architecture
detect_platform() {
    local os arch

    case "$(uname -s)" in
        Linux*)     os="linux" ;;
        Darwin*)    os="macos" ;;
        *)          error "Unsupported OS: $(uname -s)" ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)   arch="x86_64" ;;
        aarch64|arm64)  arch="aarch64" ;;
        *)              error "Unsupported architecture: $(uname -m)" ;;
    esac

    echo "${os}-${arch}"
}

# Check if gitz is already installed
check_existing() {
    if command -v "$BINARY_NAME" &>/dev/null; then
        local current_version
        current_version=$("$BINARY_NAME" --version 2>/dev/null || echo "unknown")
        warn "gitz is already installed (version: $current_version)"
        read -p "Overwrite? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Installation cancelled."
            exit 0
        fi
    fi
}

# Download pre-built binary if available
download_binary() {
    info "Attempting to download pre-built binary..."

    local platform
    platform=$(detect_platform)

    # Check for GitHub release
    local latest_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    local download_url

    if command -v curl &>/dev/null; then
        download_url=$(curl -fsSL "$latest_url" 2>/dev/null | grep -o "\"browser_download_url\":\"[^\"]*${platform}[^\"]*\"" | cut -d'"' -f4)
    elif command -v wget &>/dev/null; then
        download_url=$(wget -qO- "$latest_url" 2>/dev/null | grep -o "\"browser_download_url\":\"[^\"]*${platform}[^\"]*\"" | cut -d'"' -f4)
    fi

    if [ -z "$download_url" ]; then
        warn "No pre-built binary found for $platform"
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp)

    info "Downloading from $download_url..."
    if command -v curl &>/dev/null; then
        curl -fsSL "$download_url" -o "$tmp_file"
    elif command -v wget &>/dev/null; then
        wget -q "$download_url" -O "$tmp_file"
    fi

    mkdir -p "$INSTALL_DIR"

    # Check if it's a tar.gz or raw binary
    if file "$tmp_file" | grep -q "gzip\|tar"; then
        tar -xzf "$tmp_file" -C "$INSTALL_DIR"
    else
        mv "$tmp_file" "$INSTALL_DIR/$BINARY_NAME"
    fi

    chmod +x "$INSTALL_DIR/$BINARY_NAME"
    rm -f "$tmp_file"

    ok "gitz downloaded and installed successfully"
}

# Install Zig if not present
ensure_zig() {
    if command -v zig &>/dev/null; then
        local zig_version
        zig_version=$(zig version 2>/dev/null | head -1)
        ok "Zig found: $zig_version"
        return 0
    fi

    info "Zig not found. Installing Zig ${ZIG_VERSION}..."

    local platform
    platform=$(detect_platform)
    local os arch

    IFS='-' read -r os arch <<< "$platform"

    # Map to Zig naming convention
    local zig_arch
    case "$arch" in
        x86_64)  zig_arch="x86_64" ;;
        aarch64) zig_arch="aarch64" ;;
    esac

    local zig_os
    case "$os" in
        linux) zig_os="linux" ;;
        macos) zig_os="macos" ;;
    esac

    local zig_url="https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_os}-${zig_arch}-${ZIG_VERSION}.tar.xz"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    info "Downloading Zig from $zig_url..."
    if command -v curl &>/dev/null; then
        curl -fsSL "$zig_url" | tar -xJ -C "$tmp_dir"
    elif command -v wget &>/dev/null; then
        wget -qO- "$zig_url" | tar -xJ -C "$tmp_dir"
    else
        error "Neither curl nor wget found. Please install one."
    fi

    local zig_dir
    zig_dir=$(find "$tmp_dir" -maxdepth 1 -name "zig-*" -type d | head -1)

    if [ ! -d "$zig_dir" ]; then
        error "Failed to extract Zig"
    fi

    mkdir -p "$INSTALL_DIR"
    cp "$zig_dir/zig" "$INSTALL_DIR/zig"
    chmod +x "$INSTALL_DIR/zig"

    # Add to PATH if not already there
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        export PATH="$INSTALL_DIR:$PATH"
        info "Added $INSTALL_DIR to PATH (add to ~/.bashrc for persistence)"
    fi

    rm -rf "$tmp_dir"
    ok "Zig installed successfully"
}

# Build gitz from source
build_from_source() {
    info "Building gitz from source..."

    local tmp_dir
    tmp_dir=$(mktemp -d)

    info "Cloning gitz repository..."
    git clone --depth 1 "https://github.com/${GITHUB_REPO}.git" "$tmp_dir/gitz" 2>/dev/null

    cd "$tmp_dir/gitz"

    info "Compiling (this may take a moment)..."
    zig build -Doptimize=ReleaseFast

    mkdir -p "$INSTALL_DIR"
    cp zig-out/bin/gitz "$INSTALL_DIR/$BINARY_NAME"
    chmod +x "$INSTALL_DIR/$BINARY_NAME"

    cd /
    rm -rf "$tmp_dir"

    ok "gitz built and installed successfully"
}

# Add to PATH
setup_path() {
    if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
        ok "$INSTALL_DIR is already in PATH"
        return 0
    fi

    local shell_rc=""
    case "$SHELL" in
        */bash)  shell_rc="$HOME/.bashrc" ;;
        */zsh)   shell_rc="$HOME/.zshrc" ;;
        */fish)  shell_rc="$HOME/.config/fish/config.fish" ;;
    esac

    if [ -n "$shell_rc" ]; then
        if [ "$shell_rc" = "$HOME/.config/fish/config.fish" ]; then
            echo "set -gx PATH $INSTALL_DIR \$PATH" >> "$shell_rc"
        else
            echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$shell_rc"
        fi
        ok "Added $INSTALL_DIR to $shell_rc"
        info "Run 'source $shell_rc' or restart your terminal"
    else
        warn "Could not detect shell. Add $INSTALL_DIR to your PATH manually."
    fi
}

# Configure git to use gitz
configure_gitz() {
    info "Configuring git to use gitz as core.fsmonitor..."

    # Set gitz as the default git dir
    git config --global gitz.defaultGitDir ".gitz" 2>/dev/null || true

    ok "Configuration complete"
}

# Print usage
print_usage() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}  🎉 gitz installed successfully!${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo ""
    echo "  Quick start:"
    echo "    gitz init              # Initialize a new repo"
    echo "    gitz add .             # Stage all files"
    echo "    gitz commit -m 'msg'   # Commit"
    echo "    gitz status            # Show status"
    echo "    gitz log --oneline     # Show log"
    echo "    gitz clone <url>       # Clone from GitHub"
    echo ""
    echo "  Full documentation:"
    echo "    https://github.com/${GITHUB_REPO}"
    echo ""
    echo "  Binary location: $INSTALL_DIR/$BINARY_NAME"
    echo ""
}

# Main
main() {
    echo ""
    echo -e "${BLUE}  ⚡ Installing gitz - A faster Git replacement in Zig${NC}"
    echo ""

    check_existing

    # Try pre-built binary first, fall back to source build
    if ! download_binary; then
        info "Falling back to source build..."
        ensure_zig
        build_from_source
    fi

    setup_path
    configure_gitz
    print_usage
}

main "$@"
