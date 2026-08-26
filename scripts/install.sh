#!/bin/bash
# GitZ Installer — builds gitz and installs it system-wide
# Usage: bash scripts/install.sh [--prefix /usr/local]
set -euo pipefail

BOLD='\033[1m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

log()  { printf "${BOLD}${CYAN}▸${RESET} %s\n" "$1"; }
ok()   { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn() { printf "${YELLOW}!${RESET} %s\n" "$1"; }
fail() { printf "${RED}✗${RESET} %s\n" "$1"; exit 1; }

# ── Parse args ────────────────────────────────────────────────────────────

PREFIX="${PREFIX:-$HOME/.local}"
VERSION="0.4.1"
REPO_URL="https://github.com/jesus-alcala/gitz"
ZIG_VERSION="0.16.0"
ZIG_MIN_VERSION="0.16"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --help|-h)
            echo "GitZ Installer v${VERSION}"
            echo ""
            echo "Usage: bash scripts/install.sh [options]"
            echo ""
            echo "Options:"
            echo "  --prefix DIR    Install prefix (default: ~/.local)"
            echo "  --help          Show this help"
            echo ""
            echo "This script:"
            echo "  1. Checks for Zig 0.16+ (downloads if missing)"
            echo "  2. Builds gitz with ReleaseFast optimization"
            echo "  3. Installs binary to <prefix>/bin/gitz"
            echo "  4. Installs shell completions"
            echo "  5. Adds to PATH if needed"
            exit 0
            ;;
        *) fail "Unknown option: $1 (use --help)" ;;
    esac
done

BIN_DIR="${PREFIX}/bin"
COMPLETIONS_DIR="${PREFIX}/share/bash-completion/completions"
ZSH_DIR="${PREFIX}/share/zsh/site-functions"
FISH_DIR="${PREFIX}/share/fish/vendor_completions.d"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo ""
printf "${BOLD}${CYAN}  GitZ Installer v${VERSION}${RESET}\n"
echo "  ─────────────────────────────"
echo ""

# ── Step 1: Check Zig ────────────────────────────────────────────────────

log "Checking for Zig 0.16+..."

ZIG=""
if command -v zig &>/dev/null; then
    ZIG="$(command -v zig)"
    ZIG_VER="$(zig version 2>/dev/null || echo "unknown")"
    if [[ "$ZIG_VER" == *"$ZIG_MIN_VERSION"* ]] || [[ "$ZIG_VER" > "$ZIG_MIN_VERSION" ]]; then
        ok "Found Zig ${ZIG_VER}"
    else
        warn "Found Zig ${ZIG_VER} but need ${ZIG_MIN_VERSION}+"
        warn "Will download correct version..."
        ZIG=""
    fi
fi

if [[ -z "$ZIG" ]]; then
    log "Downloading Zig ${ZIG_VERSION}..."
    ZIG_CACHE="${HOME}/.cache/gitz/zig"
    mkdir -p "$ZIG_CACHE"

    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64) ARCH="x86_64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        *) fail "Unsupported architecture: $ARCH" ;;
    esac

    OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$OS" in
        linux) OS="linux" ;;
        darwin) OS="macos" ;;
        *) fail "Unsupported OS: $OS" ;;
    esac

    ZIG_TAR="zig-${OS}-${ARCH}-${ZIG_VERSION}.tar.xz"
    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TAR}"
    ZIG_DIR="${ZIG_CACHE}/zig-${OS}-${ARCH}-${ZIG_VERSION}"

    if [[ ! -d "$ZIG_DIR" ]]; then
        log "Fetching ${ZIG_URL}..."
        curl -fSL "$ZIG_URL" -o "${ZIG_CACHE}/${ZIG_TAR}" 2>/dev/null || \
            wget -q "$ZIG_URL" -O "${ZIG_CACHE}/${ZIG_TAR}" 2>/dev/null || \
            fail "Could not download Zig. Please install zig manually."
        tar -xf "${ZIG_CACHE}/${ZIG_TAR}" -C "$ZIG_CACHE"
        rm -f "${ZIG_CACHE}/${ZIG_TAR}"
        ok "Zig ${ZIG_VERSION} downloaded"
    else
        ok "Zig ${ZIG_VERSION} already cached"
    fi

    ZIG="${ZIG_DIR}/zig"
fi

# ── Step 2: Build ────────────────────────────────────────────────────────

log "Building gitz (ReleaseFast)..."
cd "$PROJECT_DIR"

"$ZIG" build -Doptimize=ReleaseFast 2>&1 | tail -1

BINARY="zig-out/bin/gitz"
if [[ ! -f "$BINARY" ]]; then
    # Fallback: check if build output is elsewhere
    BINARY="zig-out/gitz"
fi
if [[ ! -f "$BINARY" ]]; then
    fail "Build failed — binary not found at zig-out/bin/gitz"
fi

ok "Build successful"

# ── Step 3: Install binary ───────────────────────────────────────────────

log "Installing to ${BIN_DIR}/gitz ..."
mkdir -p "$BIN_DIR"
cp "$BINARY" "${BIN_DIR}/gitz"
chmod 755 "${BIN_DIR}/gitz"

# Verify it runs
"${BIN_DIR}/gitz" --version >/dev/null 2>&1 || fail "Installed binary failed to run"
INSTALLED_VER=$("${BIN_DIR}/gitz" --version 2>&1 | head -1)
ok "Installed ${INSTALLED_VER} → ${BIN_DIR}/gitz"

# ── Step 4: Install completions ──────────────────────────────────────────

log "Installing shell completions..."

# Bash completions
mkdir -p "$COMPLETIONS_DIR"
cp "${PROJECT_DIR}/completions/gitz.bash" "${COMPLETIONS_DIR}/gitz" 2>/dev/null && \
    ok "Bash completions → ${COMPLETIONS_DIR}/gitz" || \
    warn "Could not install bash completions"

# Zsh completions
mkdir -p "$ZSH_DIR"
cp "${PROJECT_DIR}/completions/gitz.zsh" "${ZSH_DIR}/_gitz" 2>/dev/null && \
    ok "Zsh completions → ${ZSH_DIR}/_gitz" || \
    warn "Could not install zsh completions"

# Fish completions
mkdir -p "$FISH_DIR"
cp "${PROJECT_DIR}/completions/gitz.fish" "${FISH_DIR}/gitz.fish" 2>/dev/null && \
    ok "Fish completions → ${FISH_DIR}/gitz.fish" || \
    warn "Could not install fish completions"

# ── Step 5: PATH injection ──────────────────────────────────────────────

log "Checking PATH..."

if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
    warn "${BIN_DIR} is not in your PATH"
    echo ""

    # Detect shell and config file
    SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
    case "$SHELL_NAME" in
        bash)
            SHELL_RC="${HOME}/.bashrc"
            [[ -f "${HOME}/.bash_profile" ]] && SHELL_RC="${HOME}/.bash_profile"
            ;;
        zsh)  SHELL_RC="${HOME}/.zshrc" ;;
        fish) SHELL_RC="${HOME}/.config/fish/config.fish" ;;
        *)    SHELL_RC="${HOME}/.profile" ;;
    esac

    # Build the export line
    if [[ "$SHELL_NAME" == "fish" ]]; then
        EXPORT_LINE="set -gx PATH \"${BIN_DIR}\" \$PATH"
    else
        EXPORT_LINE="export PATH=\"${BIN_DIR}:\$PATH\""
    fi

    # Check if already in config
    if grep -qF "${BIN_DIR}" "$SHELL_RC" 2>/dev/null; then
        ok "PATH entry already in ${SHELL_RC}"
    else
        log "Adding to ${SHELL_RC}..."
        echo "" >> "$SHELL_RC"
        echo "# GitZ — added by gitz installer $(date +%Y-%m-%d)" >> "$SHELL_RC"
        echo "${EXPORT_LINE}" >> "$SHELL_RC"
        ok "Added to ${SHELL_RC}"
    fi

    # Also export for current session
    export PATH="${BIN_DIR}:${PATH}"
    ok "PATH updated for current session"
else
    ok "PATH already includes ${BIN_DIR}"
fi

# ── Done ─────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}${GREEN}  ✓ GitZ installed successfully!${RESET}\n"
echo ""
echo "  Run:  gitz --help"
echo "  Docs: ${REPO_URL}#readme"
echo ""

# Verify
VER=$("${BIN_DIR}/gitz" --version 2>&1 || echo "unknown")
echo "  Version: ${VER}"
echo ""
