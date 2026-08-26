#!/bin/bash
# GitZ Release Builder — cross-compiles for all platforms
# Usage: bash scripts/release.sh [version]
set -euo pipefail

BOLD='\033[1m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

log()  { printf "${BOLD}${CYAN}▸${RESET} %s\n" "$1"; }
ok()   { printf "${GREEN}✓${RESET} %s\n" "$1"; }
fail() { printf "${RED}✗${RESET} %s\n" "$1"; exit 1; }

VERSION="${1:-0.5.0}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${PROJECT_DIR}/dist"
ZIG="${ZIG:-zig}"

echo ""
printf "${BOLD}${CYAN}  GitZ Release Builder v${VERSION}${RESET}\n"
echo "  ──────────────────────────────────────"
echo ""

# Clean previous builds
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Platform targets
declare -A PLATFORMS=(
    ["x86_64-linux"]="linux-x86_64"
    ["aarch64-linux"]="linux-aarch64"
    ["x86_64-macos"]="macos-x86_64"
    ["aarch64-macos"]="macos-aarch64"
    ["x86_64-windows"]="windows-x86_64.exe"
)

cd "$PROJECT_DIR"

for target in "${!PLATFORMS[@]}"; do
    tag="${PLATFORMS[$target]}"
    log "Building for ${target}..."

    "$ZIG" build -Dtarget="$target" -Doptimize=ReleaseFast 2>/dev/null || {
        warn "Skipping ${target} (cross-compilation toolchain not available)"
        continue
    }

    # Copy binary
    BINARY="zig-out/bin/gitz"
    if [[ "$target" == *"windows"* ]]; then
        BINARY="zig-out/bin/gitz.exe"
    fi

    if [[ -f "$BINARY" ]]; then
        cp "$BINARY" "${DIST_DIR}/gitz-${tag}"
        chmod 755 "${DIST_DIR}/gitz-${tag}"
        ok "gitz-${tag}"
    else
        warn "Binary not found for ${target}"
    fi
done

# Create checksums
cd "$DIST_DIR"
log "Generating checksums..."
sha256sum gitz-* > SHA256SUMS 2>/dev/null || shasum -a 256 gitz-* > SHA256SUMS 2>/dev/null || true
ok "SHA256SUMS"

echo ""
printf "${BOLD}${GREEN}  ✓ Release build complete!${RESET}\n"
echo ""
echo "  Binaries:  ${DIST_DIR}/"
echo "  Checksums: ${DIST_DIR}/SHA256SUMS"
echo ""

# List all builds
ls -lh gitz-* 2>/dev/null || echo "  (no binaries built)"
echo ""
