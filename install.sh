#!/usr/bin/env bash
#
# install.sh — Fast installer for gitz.
#
# Quick install (a single download for a fresh install, no GitHub API):
#   curl -fsSL https://raw.githubusercontent.com/jesusalcaladev/gitz/main/install.sh | bash
#
# With options:
#   curl -fsSL .../install.sh | bash -s -- --help
#   curl -fsSL .../install.sh | bash -s -- --dir "$HOME/bin"
#
# Pin a release:
#   curl -fsSL .../install.sh | GITZ_VERSION=0.4.0 bash
#
# Requirements:
#   - Linux (x86_64, aarch64) or macOS (x86_64, aarch64)
#   - curl or wget, tar and gzip
#
set -Eeuo pipefail

GITHUB_REPO="jesusalcaladev/gitz"
BINARY_NAME="gitz"
INSTALL_DIR="${INSTALL_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}"
ZIG_VERSION="0.16.0"
INSTALLER_VERSION="2.0.0"

ASSUME_YES=0
FORCE=0
SKIP_PATH=0
FROM_SOURCE=0
DO_UNINSTALL=0
PINNED="${GITZ_VERSION:-}"

OS=""
ARCH=""
PLATFORM=""
CURRENT_VERSION=""
LATEST_VERSION=""
RELEASE_TAG=""
DOWNLOAD_URL=""
TMP_DIR=""
STAGED_FILE=""
BIN_SRC=""

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
    C_BOLD=$'\033[1m'
else
    C_RESET=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
    C_BOLD=""
fi

info()  { printf '%s→%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
step()  { STEP_NO=$((STEP_NO + 1)); printf '%s[%s]%s %s\n' "$C_CYAN" "$STEP_NO" "$C_RESET" "$*"; }

STEP_NO=0
SECONDS=0

on_err() {
    printf '%s✗%s Unexpected error at line %s\n' "$C_RED" "$C_RESET" "$1" >&2
    printf '  Please report: https://github.com/%s/issues\n' "$GITHUB_REPO" >&2
}

cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    if [ -n "$STAGED_FILE" ] && [ -e "$STAGED_FILE" ]; then
        rm -f "$STAGED_FILE"
    fi
}

trap 'on_err $LINENO' ERR
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

human_size() {
    awk -v b="$1" 'BEGIN {
        split("B KB MB GB TB", u, " ")
        i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]
        else printf "%.1f %s", b, u[i]
    }'
}

file_size() {
    wc -c < "$1" | tr -d '[:space:]'
}

now() {
    date +%s
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    fi
}

# ---------------------------------------------------------------------------
# Networking (curl preferred, wget fallback)
# ---------------------------------------------------------------------------

has_downloader() {
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

http_get() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=30 --tries=2 "$1"
    else
        return 1
    fi
}

# First redirect target of a URL, without following it (cheap tag discovery).
http_head_location() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSI --connect-timeout 10 --max-time 20 --retry 2 "$1" 2>/dev/null \
            | tr -d '\r' \
            | awk 'tolower($1) == "location:" { print $2; exit }'
    elif command -v wget >/dev/null 2>&1; then
        wget -S --spider --max-redirect=0 --timeout=20 --tries=2 "$1" 2>&1 \
            | awk 'tolower($1) == "location:" { print $2; exit }'
    else
        return 1
    fi
}

download_file() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        if [ -t 2 ]; then
            curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --progress-bar -o "$dest" "$url"
        else
            curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 600 -o "$dest" "$url"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if [ -t 2 ]; then
            wget --tries=3 --timeout=30 -O "$dest" "$url"
        else
            wget -q --tries=3 --timeout=30 -O "$dest" "$url"
        fi
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------

detect_platform() {
    local u_s u_m
    u_s=$(uname -s)
    u_m=$(uname -m)

    case "$u_s" in
        Linux)  OS="linux" ;;
        Darwin) OS="macos" ;;
        *)      return 1 ;;
    esac

    case "$u_m" in
        x86_64|amd64)  ARCH="x86_64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        *)             return 1 ;;
    esac

    PLATFORM="${OS}-${ARCH}"
    return 0
}

# Pre-built binaries link against glibc; on musl we build from source instead.
is_musl() {
    [ "$OS" = "linux" ] || return 1
    ls /lib/ld-musl-* >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Release discovery
# ---------------------------------------------------------------------------

latest_asset_url() {
    printf 'https://github.com/%s/releases/latest/download/%s-%s.tar.gz' \
        "$GITHUB_REPO" "$BINARY_NAME" "$PLATFORM"
}

pinned_asset_url() {
    printf 'https://github.com/%s/releases/download/%s/%s-%s.tar.gz' \
        "$GITHUB_REPO" "$RELEASE_TAG" "$BINARY_NAME" "$PLATFORM"
}

# Resolve the latest release tag using one tiny HEAD request (no API rate
# limit). Sets RELEASE_TAG, LATEST_VERSION and DOWNLOAD_URL.
resolve_release() {
    if [ -n "$PINNED" ]; then
        RELEASE_TAG="v${PINNED#v}"
        LATEST_VERSION="${RELEASE_TAG#v}"
        DOWNLOAD_URL=$(pinned_asset_url)
        return 0
    fi

    local loc req_url origin
    req_url=$(latest_asset_url)
    loc=$(http_head_location "$req_url") || loc=""

    # Redirects may be relative ("/releases/...") — resolve them against the
    # request origin so the download URL is always absolute.
    if [ -n "$loc" ]; then
        case "$loc" in
            http://*|https://*) ;;
            /*)
                origin=$(printf '%s' "$req_url" | awk -F/ '{ print $1 "//" $3 }')
                loc="${origin}${loc}"
                ;;
            *)
                origin=$(printf '%s' "$req_url" | awk -F/ '{ print $1 "//" $3 }')
                loc="${origin}/${loc}"
                ;;
        esac
    fi

    case "$loc" in
        *"/releases/download/"*)
            DOWNLOAD_URL="$loc"
            RELEASE_TAG=$(printf '%s' "${loc#*/releases/download/}" | cut -d/ -f1)
            LATEST_VERSION="${RELEASE_TAG#v}"
            if [ -n "$LATEST_VERSION" ]; then
                return 0
            fi
            ;;
    esac

    # Fallback: official API (rate limited, but also reports missing releases)
    local json tag
    json=$(http_get "https://api.github.com/repos/${GITHUB_REPO}/releases/latest") || return 1
    tag=$(printf '%s' "$json" | grep -o '"tag_name":[[:space:]]*"[^"]*"' | head -n1 | cut -d'"' -f4) || true
    [ -n "$tag" ] || return 1

    RELEASE_TAG="$tag"
    LATEST_VERSION="${tag#v}"
    DOWNLOAD_URL=$(pinned_asset_url)
    return 0
}

# Report which version (if any) is already on this machine.
probe_installed() {
    local bin raw
    bin=$(command -v "$BINARY_NAME" 2>/dev/null || true)
    if [ -z "$bin" ] && [ -x "$INSTALL_DIR/$BINARY_NAME" ]; then
        bin="$INSTALL_DIR/$BINARY_NAME"
    fi
    if [ -z "$bin" ] || [ ! -x "$bin" ]; then
        return 0
    fi

    raw=$("$bin" --version 2>/dev/null | head -n1 || true)
    raw=${raw#gitz version }
    raw=${raw#gitz }
    CURRENT_VERSION="$raw"
    INSTALLED_BIN="$bin"
}
INSTALLED_BIN=""

# ---------------------------------------------------------------------------
# Install steps
# ---------------------------------------------------------------------------

verify_checksum() {
    # $1 = tarball, $2 = asset file name. Best effort: older releases may not
    # publish SHA256SUMS, in which case we only note that verification was skipped.
    local tarball="$1" asset_name="$2" sums expected actual
    sums="$TMP_DIR/SHA256SUMS"

    if [ -n "$RELEASE_TAG" ]; then
        download_file "https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/SHA256SUMS" "$sums" 2>/dev/null || true
    fi
    if [ ! -s "$sums" ]; then
        download_file "https://github.com/${GITHUB_REPO}/releases/latest/download/SHA256SUMS" "$sums" 2>/dev/null || true
    fi
    if [ ! -s "$sums" ]; then
        info "No SHA256SUMS published for this release — skipping verification"
        return 0
    fi

    expected=$(grep -F " ${asset_name}" "$sums" | head -n1 | awk '{print $1}') || true
    if [ -z "$expected" ]; then
        info "No checksum entry for ${asset_name} — skipping verification"
        return 0
    fi

    actual=$(sha256_of "$tarball")
    if [ -z "$actual" ]; then
        warn "No SHA-256 tool available (sha256sum/shasum/openssl) — skipping verification"
        return 0
    fi

    if [ "$expected" != "$actual" ]; then
        die "Checksum mismatch for ${asset_name}: expected ${expected}, got ${actual}"
    fi
    ok "Checksum verified (SHA-256)"
}

extract_binary() {
    local tarball="$1"
    tar -xzf "$tarball" -C "$TMP_DIR" || return 1

    if [ -f "$TMP_DIR/$BINARY_NAME" ]; then
        BIN_SRC="$TMP_DIR/$BINARY_NAME"
    else
        BIN_SRC=$(find "$TMP_DIR" -type f -name "$BINARY_NAME" 2>/dev/null | head -n1) || true
    fi

    if [ -z "$BIN_SRC" ] || [ ! -f "$BIN_SRC" ]; then
        return 1
    fi

    chmod +x "$BIN_SRC" 2>/dev/null || true
    "$BIN_SRC" --version >/dev/null 2>&1 || return 1
    return 0
}

# Copy to a staged name inside the target directory, then rename atomically so
# a running gitz is never half-overwritten.
place_binary() {
    mkdir -p "$INSTALL_DIR" || return 1
    STAGED_FILE="$INSTALL_DIR/.${BINARY_NAME}.$$"
    cp -f "$BIN_SRC" "$STAGED_FILE" || return 1
    chmod 755 "$STAGED_FILE" || return 1
    mv -f "$STAGED_FILE" "$INSTALL_DIR/$BINARY_NAME" || return 1
    STAGED_FILE=""
    return 0
}

# Returns 0 only if the binary was downloaded, verified and installed.
install_prebuilt() {
    local tarball asset size t0 dur

    [ -n "$DOWNLOAD_URL" ] || return 1
    asset="${BINARY_NAME}-${PLATFORM}.tar.gz"
    tarball="$TMP_DIR/${asset}"

    info "Downloading ${DOWNLOAD_URL}"
    t0=$(now)
    if ! download_file "$DOWNLOAD_URL" "$tarball"; then
        return 1
    fi
    if [ ! -s "$tarball" ]; then
        return 1
    fi
    dur=$(( $(now) - t0 ))
    size=$(file_size "$tarball")
    ok "Downloaded ${asset} — $(human_size "$size") in ${dur}s"

    verify_checksum "$tarball" "$asset"

    info "Extracting…"
    if ! extract_binary "$tarball"; then
        warn "Could not extract a runnable ${BINARY_NAME} from the archive (tar/gzip required)"
        return 1
    fi

    if ! place_binary; then
        warn "Could not write to ${INSTALL_DIR}"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Build from source (fallback)
# ---------------------------------------------------------------------------

ensure_zig() {
    if command -v zig >/dev/null 2>&1; then
        ok "Using Zig $(zig version 2>/dev/null | head -n1)"
        return 0
    fi

    local toolchain zig_url
    toolchain="${XDG_DATA_HOME:-$HOME/.local/share}/gitz/zig-${ZIG_VERSION}"

    if [ -x "$toolchain/zig" ]; then
        PATH="$toolchain:$PATH"
        export PATH
        ok "Using toolchain Zig ${ZIG_VERSION} (${toolchain})"
        return 0
    fi

    info "Zig not found — installing Zig ${ZIG_VERSION} (build only)"
    zig_url="https://ziglang.org/download/${ZIG_VERSION}/zig-${OS}-${ARCH}-${ZIG_VERSION}.tar.xz"
    info "Downloading ${zig_url}"

    download_file "$zig_url" "$TMP_DIR/zig.tar.xz" || return 1
    tar -xJf "$TMP_DIR/zig.tar.xz" -C "$TMP_DIR" || return 1

    local extracted
    extracted=$(find "$TMP_DIR" -maxdepth 1 -type d -name 'zig-*' | head -n1) || true
    if [ -z "$extracted" ] || [ ! -x "$extracted/zig" ]; then
        return 1
    fi

    mkdir -p "$(dirname "$toolchain")"
    rm -rf "$toolchain"
    mv "$extracted" "$toolchain" 2>/dev/null || cp -R "$extracted" "$toolchain" || return 1

    PATH="$toolchain:$PATH"
    export PATH
    ok "Zig ${ZIG_VERSION} ready (${toolchain})"
    return 0
}

build_from_source() {
    step "Building gitz from source"

    # Only treat the current directory as the gitz source tree when it really
    # is one (build.zig must reference the gitz package).
    if [ -f build.zig ] && [ -d src/cli ] && grep -q '"gitz"' build.zig; then
        BIN_SRC_DIR="$PWD"
        info "Using local source tree: ${BIN_SRC_DIR}"
    else
        if ! command -v git >/dev/null 2>&1; then
            warn "git is required to build from source"
            return 1
        fi
        BIN_SRC_DIR="$TMP_DIR/gitz-src"
        info "Cloning https://github.com/${GITHUB_REPO}"
        rm -rf "$BIN_SRC_DIR"
        git clone --depth 1 --quiet "https://github.com/${GITHUB_REPO}.git" "$BIN_SRC_DIR" || return 1
    fi

    ensure_zig || return 1

    local t0
    t0=$(now)
    info "Compiling (ReleaseFast)…"
    if ! (cd "$BIN_SRC_DIR" && zig build -Doptimize=ReleaseFast); then
        warn "Compilation failed"
        return 1
    fi

    if [ ! -x "$BIN_SRC_DIR/zig-out/bin/$BINARY_NAME" ]; then
        return 1
    fi
    BIN_SRC="$BIN_SRC_DIR/zig-out/bin/$BINARY_NAME"

    place_binary || return 1
    ok "Built and installed in $(( $(now) - t0 ))s"
    return 0
}
BIN_SRC_DIR=""

# ---------------------------------------------------------------------------
# Post-install configuration
# ---------------------------------------------------------------------------

setup_path() {
    if [ "$SKIP_PATH" -eq 1 ]; then
        info "Skipping PATH setup (--no-path)"
        return 0
    fi

    case ":$PATH:" in
        *":$INSTALL_DIR:"*)
            ok "PATH already includes ${INSTALL_DIR}"
            return 0
            ;;
    esac

    local rc=""
    case "${SHELL:-}" in
        */bash) rc="$HOME/.bashrc" ;;
        */zsh)  rc="$HOME/.zshrc" ;;
        */fish) rc="$HOME/.config/fish/config.fish" ;;
        *)      rc="" ;;
    esac

    if [ -n "$rc" ] && grep -qF "$INSTALL_DIR" "$rc" 2>/dev/null; then
        ok "PATH already configured in ${rc}"
        export PATH="$INSTALL_DIR:$PATH"
        return 0
    fi

    if [ -z "$rc" ]; then
        warn "Unknown shell — add ${INSTALL_DIR} to your PATH manually"
        return 0
    fi

    mkdir -p "$(dirname "$rc")"
    case "${SHELL:-}" in
        */fish)
            printf '\n# gitz installer\nfish_add_path %s\n' "$INSTALL_DIR" >> "$rc"
            ;;
        *)
            printf '\n# gitz installer\nexport PATH="%s:$PATH"\n' "$INSTALL_DIR" >> "$rc"
            ;;
    esac

    export PATH="$INSTALL_DIR:$PATH"
    ok "Added ${INSTALL_DIR} to ${rc}"
    info "Run: source ${rc}  (or open a new terminal)"
}

configure_git() {
    if ! command -v git >/dev/null 2>&1; then
        info "git not found — skipping optional git configuration"
        return 0
    fi

    if git config --global gitz.defaultGitDir ".gitz" 2>/dev/null; then
        ok "git configured: gitz.defaultGitDir = .gitz"
    else
        warn "Could not write git global config (continuing)"
    fi
}

verify_install() {
    local out
    out=$("$INSTALL_DIR/$BINARY_NAME" --version 2>/dev/null | head -n1) \
        || die "The installed binary did not run — wrong architecture? See docs/INSTALL.md"
    ok "Verified: ${out}"
}

print_summary() {
    local version="$1"
    version="${version#v}"
    printf '\n'
    printf '%s──────────────────────────────────────%s\n' "$C_GREEN" "$C_RESET"
    printf '%s  gitz v%s installed in %ss%s\n' "$C_GREEN" "$version" "$SECONDS" "$C_RESET"
    printf '  %s\n' "$INSTALL_DIR/$BINARY_NAME"
    printf '%s──────────────────────────────────────%s\n' "$C_GREEN" "$C_RESET"
    printf '\n'
    printf '  Quick start:\n'
    printf '    gitz init              # Create a repository\n'
    printf '    gitz add .             # Stage files\n'
    printf "    gitz commit -m 'msg'   # Commit\n"
    printf '    gitz status            # Show status\n'
    printf '    gitz log --oneline     # Show history\n'
    printf '\n'
    printf '  Docs: https://github.com/%s\n' "$GITHUB_REPO"
    printf '\n'
}

uninstall_gitz() {
    local target="$INSTALL_DIR/$BINARY_NAME"

    if [ ! -e "$target" ]; then
        if INSTALLED_BIN=$(command -v "$BINARY_NAME" 2>/dev/null); then
            die "gitz is installed at ${INSTALLED_BIN}, not in ${INSTALL_DIR} — remove it manually"
        fi
        die "gitz not found in ${INSTALL_DIR}"
    fi

    if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
        printf 'Remove %s? [y/N] ' "$target"
        read -r reply
        case "$reply" in
            y|Y|yes|YES) ;;
            *) info "Cancelled."; exit 0 ;;
        esac
    elif [ "$ASSUME_YES" -eq 0 ]; then
        die "Refusing to uninstall non-interactively — re-run with --uninstall -y"
    fi

    rm -f "$target"
    ok "Removed ${target}"
    info "PATH entries in your shell rc were left untouched"
    exit 0
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

print_help() {
    cat <<EOF
gitz installer ${INSTALLER_VERSION}

Usage:
  curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh | bash
  ./install.sh [options]

Options:
  -y, --yes       Non-interactive install (implicit when piped)
  -f, --force     Reinstall even if already up to date
  --dir DIR       Install into DIR (default: ${INSTALL_DIR})
  --source        Build from source instead of downloading a binary
  --no-path       Do not touch shell configuration
  --uninstall     Remove gitz from the install directory
  -V, --version   Print installer version and exit
  -h, --help      Show this help and exit

Environment:
  INSTALL_DIR     Same as --dir
  GITZ_VERSION    Pin a release (e.g. 0.4.0 or v0.4.0)
  NO_COLOR        Disable colored output

Existing installs are upgraded automatically; no prompts are used when the
script is piped into bash.
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)   ASSUME_YES=1 ;;
            -f|--force) FORCE=1 ;;
            --source)   FROM_SOURCE=1 ;;
            --no-path)  SKIP_PATH=1 ;;
            --uninstall) DO_UNINSTALL=1 ;;
            --dir)
                shift
                [ $# -gt 0 ] || die "--dir requires a value"
                INSTALL_DIR="$1"
                ;;
            --dir=*)
                INSTALL_DIR="${1#--dir=}"
                ;;
            -V|--version)
                printf 'gitz installer %s\n' "$INSTALLER_VERSION"
                exit 0
                ;;
            -h|--help)
                print_help
                exit 0
                ;;
            *)
                die "Unknown option: $1 (see --help)"
                ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    # Allow "~/bin" style values passed via --dir or INSTALL_DIR.
    case "$INSTALL_DIR" in
        "~")   INSTALL_DIR="$HOME" ;;
        "~/"*) INSTALL_DIR="$HOME/${INSTALL_DIR#\~/}" ;;
    esac

    SECONDS=0
    STEP_NO=0

    printf '\n'
    printf '%s gitz installer %s%s\n' "$C_BOLD" "$INSTALLER_VERSION" "$C_RESET"
    printf '\n'

    if [ "$DO_UNINSTALL" -eq 1 ]; then
        uninstall_gitz
    fi

    if ! has_downloader; then
        warn "Neither curl nor wget found — will try to build from source instead"
        FROM_SOURCE=1
    fi

    detect_platform \
        || die "Unsupported platform: $(uname -s)/$(uname -m) — see docs/INSTALL.md"
    info "Platform: ${PLATFORM}"

    probe_installed
    if [ -n "$CURRENT_VERSION" ]; then
        info "Installed: v${CURRENT_VERSION}"
    fi

    TMP_DIR=$(mktemp -d)

    # Decide whether we can skip the download entirely.
    if [ "$FROM_SOURCE" -eq 0 ]; then
        if [ -n "$CURRENT_VERSION" ] && [ "$FORCE" -eq 0 ]; then
            if resolve_release; then
                info "Latest release: v${LATEST_VERSION}"
                if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
                    ok "gitz v${CURRENT_VERSION} is already up to date"
                    setup_path
                    print_summary "$CURRENT_VERSION"
                    return 0
                fi
            else
                warn "Could not reach GitHub releases — will try the latest shortcut URL"
                RELEASE_TAG=""
                LATEST_VERSION=""
            fi
        elif [ -n "$PINNED" ]; then
            resolve_release || die "Could not resolve pinned release ${PINNED}"
            info "Pinned release: v${LATEST_VERSION}"
        fi

        if [ -z "$DOWNLOAD_URL" ]; then
            DOWNLOAD_URL=$(latest_asset_url)
        fi
    fi

    if is_musl; then
        info "musl libc detected — pre-built binaries need glibc, building from source"
        FROM_SOURCE=1
    fi

    local installed_ok=0
    if [ "$FROM_SOURCE" -eq 0 ]; then
        if [ -n "$LATEST_VERSION" ]; then
            step "Installing gitz v${LATEST_VERSION} for ${PLATFORM}"
        else
            step "Installing gitz for ${PLATFORM}"
        fi
        if install_prebuilt; then
            installed_ok=1
        else
            warn "No pre-built binary available for ${PLATFORM}"
        fi
    fi

    if [ "$installed_ok" -eq 0 ]; then
        # Fresh temp dir: a failed download may have left junk behind.
        rm -rf "$TMP_DIR"
        TMP_DIR=$(mktemp -d)
        build_from_source || die "Could not obtain gitz for ${PLATFORM}"
    fi

    verify_install
    setup_path
    configure_git

    local final_version
    final_version=$("$INSTALL_DIR/$BINARY_NAME" --version 2>/dev/null | head -n1 || true)
    final_version=${final_version#gitz version }
    final_version=${final_version#gitz }

    print_summary "$final_version"
    return 0
}

main "$@"
