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
#   ./bootstrap.sh --only zsh,nvim # link ONLY these Core module groups
#   ./bootstrap.sh --skip tmux     # link everything EXCEPT these groups
#
# Module groups (for --only/--skip): zsh nvim tmux git prompt tools — they affect
# the wiring steps only, never package provisioning; combine with --links-only to
# re-wire a subset of configs without touching apk.
#
# Run as root, OR as a user with doas/sudo configured (Alpine defaults to doas).
#
# PREREQUISITE — bash: this script is bash (shebang above; it uses arrays + mapfile),
# but a fresh Alpine ships only busybox ash, so bash is NOT present by default. Install
# it FIRST or the kernel can't exec this file ("bad interpreter: bash: not found"):
#     apk add bash     # (or: doas apk add bash)
# bash is also listed in install/packages.txt so a full provision keeps it installed.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LINKS_ONLY=0
# --only/--skip are validated by the shared lib (blib_select), which is sourced
# AFTER this loop — so capture the raw values now and apply them below.
ONLY_RAW="" SKIP_RAW="" ONLY_SEEN=0 SKIP_SEEN=0

while [[ $# -gt 0 ]]; do case "$1" in
  --links-only) LINKS_ONLY=1 ;;
  --only) [[ $# -ge 2 ]] || { echo "--only requires module names, e.g. --only zsh,nvim" >&2; exit 1; }; ONLY_RAW="$2"; ONLY_SEEN=1; shift ;;
  --only=*) ONLY_RAW="${1#*=}"; ONLY_SEEN=1 ;;
  --skip) [[ $# -ge 2 ]] || { echo "--skip requires module names, e.g. --skip tmux" >&2; exit 1; }; SKIP_RAW="$2"; SKIP_SEEN=1; shift ;;
  --skip=*) SKIP_RAW="${1#*=}"; SKIP_SEEN=1 ;;
  -h | --help)
    sed -n '2,19p' "$0"
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    exit 1
    ;;
  esac; shift; done

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

# Apply any --only/--skip module selection now the validator (blib_select) exists;
# it aborts on a malformed selector or an unknown group.
if ((ONLY_SEEN)); then blib_select --only "$ONLY_RAW"; fi
if ((SKIP_SEEN)); then blib_select --skip "$SKIP_RAW"; fi

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

# ── go-installed tools: presence-guarded, best-effort. Used for core-doctor tools
# that live only in Alpine's `testing` repo (duf, glow), plus sesh — none packaged in
# `community`. `go install` produces a static (musl-safe) binary; if Go is absent we
# defer via mise, else print a hint. Never aborts (errexit-exempt). ──────────────
# go install drops binaries in ~/go/bin, which the shell layer does NOT put on
# PATH (it prefixes ~/.local/bin + ~/.cargo/bin) — so point GOBIN at ~/.local/bin.
_dotfiles_go_install() { # <import-path@version> <binary-name>
  [ "$#" -ge 2 ] || return 0
  if command -v "$2" >/dev/null 2>&1; then return 0; fi
  gobin="$HOME/.local/bin"
  mkdir -p "$gobin" 2>/dev/null || true
  if command -v go >/dev/null 2>&1; then
    GOBIN="$gobin" go install "$1" >/dev/null 2>&1 ||
      echo "   $2: go install failed — retry later: GOBIN=$gobin go install $1"
  elif command -v mise >/dev/null 2>&1; then
    GOBIN="$gobin" mise exec go@latest -- go install "$1" >/dev/null 2>&1 ||
      echo "   $2: go install failed — retry later: GOBIN=$gobin go install $1"
  else
    echo "   $2: needs Go — install later with: GOBIN=$gobin go install $1"
  fi
  return 0
}

provision() {
  # shellcheck disable=SC2086  # $SU: single token or empty (root)
  blib_say "apk update"
  # shellcheck disable=SC2086
  $SU apk update

  blib_say "apk packages (from install/packages.txt)"
  local -a pkgs=()
  mapfile -t pkgs < <(blib_read_pkgs "$DOTFILES/install/packages.txt")
  # Guard the empty case: an all-comment/blank packages.txt yields a zero-length
  # array. apk_install wraps `apk add` in `if …; then` (errexit-exempt), so an
  # empty list wouldn't abort — but it WOULD run `apk add` with no args, trip the
  # "bulk install hit a snag" per-package fallback, and then log a misleading
  # "0 requested" success. Skip the install instead and carry on.
  if ((${#pkgs[@]})); then
    apk_install "${pkgs[@]}"
    blib_ok "apk packages requested: ${#pkgs[@]}"
  else
    blib_warn "install/packages.txt lists no packages — skipping apk install"
  fi

  # Tools not packaged (or that we build from source on musl). The starship and
  # mise installers detect musl and pull the correct *-musl build — safe here.
  # atuin is in Alpine repos (in packages.txt); installer below is just a fallback.
  if ! command -v starship >/dev/null; then
    blib_say "starship (official installer — musl build)"
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y >/dev/null || true
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
      echo "   tree-sitter-cli build failed; retry later: cargo install --locked tree-sitter-cli"
  fi
  # tealdeer (tldr): `testing`-only on Alpine (never in `community`), so not in
  # packages.txt — build from source via cargo. Presence-guarded on the `tldr`
  # binary; best-effort so a build hiccup never aborts bootstrap.
  if ! command -v tldr >/dev/null && command -v cargo >/dev/null; then
    blib_say "tealdeer (cargo build — tldr client; testing-only on Alpine)"
    cargo install --locked tealdeer >/dev/null 2>&1 ||
      echo "   tealdeer build failed; retry later: cargo install --locked tealdeer"
  fi

  # ── go-installed core-doctor tools. sesh is unpackaged on Alpine; duf + glow are
  # `testing`-only (NOT in `community` on current stable), so `apk add` skips them —
  # `go install` here is their REAL source, not a fallback. `go install` yields a
  # static (musl-safe) binary; presence-guarded + best-effort, so it no-ops when a
  # tool is already present, and a box without Go just gets a hint. ────────────────
  blib_say "duf / glow / sesh (go install — testing-only/unpackaged on Alpine; musl-safe static)"
  _dotfiles_go_install github.com/muesli/duf@latest duf
  _dotfiles_go_install github.com/charmbracelet/glow/v2@latest glow
  _dotfiles_go_install github.com/joshmedeski/sesh/v2@latest sesh

  # ── op (1Password CLI): native musl apk from 1Password's official Alpine repo —
  # NOT a glibc vendor binary. Presence-guarded; best-effort so a fetch/network hiccup
  # never aborts bootstrap. ────────────────────────────────────────────────────────
  if ! command -v op >/dev/null 2>&1; then
    blib_say "op — 1Password CLI (official Alpine repo — native musl apk)"
    # shellcheck disable=SC2086  # $SU: single token (doas/sudo) or empty (root)
    if ! grep -q '1password.com/linux/alpinelinux' /etc/apk/repositories 2>/dev/null; then
      echo "https://downloads.1password.com/linux/alpinelinux/stable/" | $SU tee -a /etc/apk/repositories >/dev/null || true
    fi
    # shellcheck disable=SC2086
    $SU wget -q https://downloads.1password.com/linux/keys/alpinelinux/support@1password.com-61ddfc31.rsa.pub -P /etc/apk/keys 2>/dev/null || true
    # shellcheck disable=SC2086
    { $SU apk update >/dev/null 2>&1 && $SU apk add 1password-cli >/dev/null 2>&1; } ||
      echo "   op: install skipped — add it later with: $SU apk add 1password-cli"
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
  blib_ok "symlinks wired$(blib_selected_note)"
}

((LINKS_ONLY)) || provision
wire_links
blib_ok "Alpine bootstrap complete — open a new shell or: exec zsh"
