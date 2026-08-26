#!/bin/bash
# GitZ Uninstaller — removes gitz binary, completions, and PATH entry
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

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="${PREFIX}/bin"
COMPLETIONS_DIR="${PREFIX}/share/bash-completion/completions"
ZSH_DIR="${PREFIX}/share/zsh/site-functions"
FISH_DIR="${PREFIX}/share/fish/vendor_completions.d"

echo ""
printf "${BOLD}${CYAN}  GitZ Uninstaller${RESET}\n"
echo "  ──────────────────────"
echo ""

# ── Remove binary ────────────────────────────────────────────────────────

if [[ -f "${BIN_DIR}/gitz" ]]; then
    log "Removing ${BIN_DIR}/gitz ..."
    rm -f "${BIN_DIR}/gitz"
    ok "Binary removed"
else
    warn "Binary not found at ${BIN_DIR}/gitz"
fi

# ── Remove completions ───────────────────────────────────────────────────

for f in "${COMPLETIONS_DIR}/gitz" "${ZSH_DIR}/_gitz" "${FISH_DIR}/gitz.fish"; do
    if [[ -f "$f" ]]; then
        rm -f "$f"
        ok "Removed $f"
    fi
done

# ── Remove PATH entry from shell config ──────────────────────────────────

log "Checking shell configs for PATH entries..."

SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
case "$SHELL_NAME" in
    bash)
        for rc in "${HOME}/.bashrc" "${HOME}/.bash_profile"; do
            [[ -f "$rc" ]] || continue
            if grep -qF "GitZ" "$rc" 2>/dev/null; then
                sed -i '/# GitZ — added by gitz installer/d' "$rc"
                sed -i "\|${BIN_DIR}.*PATH|d" "$rc"
                ok "Cleaned PATH from $rc"
            fi
        done
        ;;
    zsh)
        if [[ -f "${HOME}/.zshrc" ]]; then
            if grep -qF "GitZ" "${HOME}/.zshrc" 2>/dev/null; then
                sed -i '/# GitZ — added by gitz installer/d' "${HOME}/.zshrc"
                sed -i "\|${BIN_DIR}.*PATH|d" "${HOME}/.zshrc"
                ok "Cleaned PATH from ~/.zshrc"
            fi
        fi
        ;;
    fish)
        if [[ -f "${HOME}/.config/fish/config.fish" ]]; then
            if grep -qF "GitZ" "${HOME}/.config/fish/config.fish" 2>/dev/null; then
                sed -i '/# GitZ — added by gitz installer/d' "${HOME}/.config/fish/config.fish"
                sed -i "\|${BIN_DIR}.*PATH|d" "${HOME}/.config/fish/config.fish"
                ok "Cleaned PATH from ~/.config/fish/config.fish"
            fi
        fi
        ;;
esac

# ── Remove cached Zig (optional) ─────────────────────────────────────────

ZIG_CACHE="${HOME}/.cache/gitz/zig"
if [[ -d "$ZIG_CACHE" ]]; then
    read -p "Remove downloaded Zig cache (${ZIG_CACHE})? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$ZIG_CACHE"
        ok "Zig cache removed"
    fi
fi

# ── Done ─────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}${GREEN}  ✓ GitZ uninstalled${RESET}\n"
echo "  Restart your shell or run:  exec $SHELL_NAME"
echo ""
