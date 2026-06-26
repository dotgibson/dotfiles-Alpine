#!/usr/bin/env bash
# dotfiles-Alpine/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# Provision an Alpine box (bare-metal / VM / container / WSL) and wire dotfiles.
# Idempotent. OS-NATIVE layer; Core (zsh/tmux/nvim/git) is vendored under core/.
# Alpine is the outlier: musl libc, doas (not sudo), ash default shell, OpenRC.
# The shared symlink/loader/login-shell scaffold lives in core/lib/bootstrap-lib.sh.
#
# Usage:
#   ./bootstrap.sh                 # full: apk packages + extras + symlinks
#   ./bootstrap.sh --links-only    # just (re)create symlinks
#
# Run as root, OR as a user with doas/sudo configured (Alpine defaults to doas).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LINKS_ONLY=0

for a in "$@"; do case "$a" in
  --links-only) LINKS_ONLY=1 ;;
  -h | --help)
    sed -n '2,13p' "$0"
    exit 0
    ;;
  *)
    echo "unknown arg: $a" >&2
    exit 1
    ;;
  esac; done

# ── core/ subtree present? (inline: can't source a lib out of core/ before this) ─
# Validate the SPECIFIC paths we depend on below — the zsh modules wire_links
# symlinks, plus the two libs sourced next — so a missing or partially-vendored
# subtree fails HERE with a precise message, not later with a cryptic
# `source: No such file`.
for _req in core/zsh/loader.zsh core/lib/ux.sh core/lib/bootstrap-lib.sh; do
  if [[ ! -e "$DOTFILES/$_req" ]]; then
    echo "core/ subtree missing or incomplete (need $_req). One-time, run:" >&2
    echo "  git subtree add  --prefix=core <dotfiles-core remote> main --squash   # first time" >&2
    echo "  git subtree pull --prefix=core <dotfiles-core remote> main --squash   # to update" >&2
    exit 1
  fi
done
unset _req

# Shared bash UX palette + the provisioning scaffold (link/read_pkgs/WSL-detect/
# Core-symlink/loader/login-shell), both vendored under core/lib. ux.sh first so the
# blib_* messages pick up its palette.
# shellcheck source=core/lib/ux.sh
source "$DOTFILES/core/lib/ux.sh"
# shellcheck source=core/lib/bootstrap-lib.sh
source "$DOTFILES/core/lib/bootstrap-lib.sh"

# ── privilege tool: Alpine defaults to doas, not sudo. Use nothing if root. ─────
# BLIB_SU hands the same escalator to bootstrap-lib (blib_set_login_shell).
if [[ "$(id -u)" -eq 0 ]]; then
  SU=""
elif command -v doas >/dev/null 2>&1; then
  SU="doas"
elif command -v sudo >/dev/null 2>&1; then
  SU="sudo"
else
  echo "Need root: run as root, or 'apk add doas' and configure /etc/doas.d." >&2
  exit 1
fi
export BLIB_SU="$SU"

# ── sanity: confirm we're on Alpine ────────────────────────────────────────────
if ! grep -qiE '^ID=alpine' /etc/os-release 2>/dev/null; then
  echo "This bootstrap targets Alpine Linux (expects ID=alpine in /etc/os-release)." >&2
  exit 1
fi

IS_WSL=0
if blib_is_wsl; then IS_WSL=1; fi

# ── resilient install: apk fails the whole transaction on one unknown package.
# Bulk first, then per-package so a missing name is skipped, not fatal. ──────────
apk_install() {
  local -a pkgs=("$@")
  # shellcheck disable=SC2086  # $SU is a single token (doas/sudo) or empty (root)
  if $SU apk add "${pkgs[@]}"; then return 0; fi
  blib_say "bulk install hit a snag — retrying package-by-package"
  local p
  for p in "${pkgs[@]}"; do
    # shellcheck disable=SC2086  # see above
    $SU apk add "$p" || echo "   skipped (unavailable on this box?): $p"
  done
}

provision() {
  # shellcheck disable=SC2086  # $SU: single token or empty (root)
  blib_say "apk update"
  # shellcheck disable=SC2086
  $SU apk update

  blib_say "apk packages (from install/packages.txt)"
  local -a pkgs=()
  mapfile -t pkgs < <(blib_read_pkgs "$DOTFILES/install/packages.txt")
  apk_install "${pkgs[@]}"
  blib_ok "apk packages requested: ${#pkgs[@]}"

  # Tools not packaged (or that we build from source on musl). The starship and
  # mise installers detect musl and pull the correct *-musl build — safe here.
  # atuin is in Alpine repos (in packages.txt); installer below is just a fallback.
  if ! command -v starship >/dev/null; then
    blib_say "starship (official installer — musl build)"
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y >/dev/null
  fi
  if ! command -v atuin >/dev/null; then
    blib_say "atuin (official installer — fallback; usually apk-installed)"
    curl -fsSL https://setup.atuin.sh | sh >/dev/null 2>&1 || true
  fi
  if ! command -v mise >/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
    blib_say "mise (official installer — musl build)"
    curl -fsSL https://mise.run | sh >/dev/null 2>&1 || true
  fi
  # yazi + tree-sitter-cli: not packaged → build from source via cargo. On musl
  # this compiles against the musl target (needs build-base, in packages.txt).
  if ! command -v yazi >/dev/null && command -v cargo >/dev/null; then
    blib_say "yazi (cargo build — slow on musl)"
    cargo install --locked yazi-fs yazi-cli >/dev/null 2>&1 || true
  fi
  if ! command -v tree-sitter >/dev/null && command -v cargo >/dev/null; then
    blib_say "tree-sitter-cli (cargo build)"
    cargo install --locked tree-sitter-cli >/dev/null 2>&1 ||
      echo "   tree-sitter-cli build failed; retry later: cargo install tree-sitter-cli"
  fi

  # ── WSL: install /etc/wsl.conf. NOTE: no systemd=true — Alpine uses OpenRC. ───
  if ((IS_WSL)); then
    blib_say "installing /etc/wsl.conf (default user + interop; OpenRC, not systemd)"
    local user
    user="$(id -un)"
    # shellcheck disable=SC2086  # $SU: single token or empty (root)
    sed "s/__WSL_USER__/$user/" "$DOTFILES/wsl/wsl.conf" | $SU tee /etc/wsl.conf >/dev/null
    blib_ok "wsl.conf written — run 'wsl.exe --shutdown' from Windows, then reopen"
  fi
}

wire_links() {
  # The whole shared symlink surface + the Alpine OS overlays + the managed .zshrc
  # loader + the default-login-shell switch now live in core/lib/bootstrap-lib.sh.
  blib_link_core "$DOTFILES" "$CONFIG"
  blib_link_os_layer "$DOTFILES" "$CONFIG" alpine
  # shellcheck disable=SC2119  # no args is intentional — writes the default module set
  blib_write_zshrc_loader
  blib_set_login_shell
  blib_ok "symlinks wired"
}

((LINKS_ONLY)) || provision
wire_links
blib_ok "Alpine bootstrap complete — open a new shell or: exec zsh"
