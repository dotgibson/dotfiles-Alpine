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
#   ./bootstrap.sh --dry-run       # preview the wiring; change nothing
#   ./bootstrap.sh --only zsh,nvim # link ONLY these Core module groups
#   ./bootstrap.sh --skip tmux     # link everything EXCEPT these groups
#
# --dry-run implies --links-only: provisioning installs packages and touches system
# files, which cannot be meaningfully previewed, so it is skipped rather than faked.
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
DRY=0
# --only/--skip are validated by the shared lib (blib_select), which is sourced
# AFTER this loop — so capture the raw values now and apply them below.
ONLY_RAW="" SKIP_RAW="" ONLY_SEEN=0 SKIP_SEEN=0

# ── pinned third-party material ────────────────────────────────────────────────
# The 1Password apk signing key. Adding a third-party repo + key to apk means every
# later `apk add` on this box trusts whatever that key signs, so fetching it without
# verification is the widest supply-chain hole this script could open. Pin the digest
# and fail CLOSED (skip op) on a mismatch. The key ID is part of the filename, so a
# genuine upstream rotation changes the URL — not this digest silently.
OP_APK_KEY_URL="https://downloads.1password.com/linux/keys/alpinelinux/support@1password.com-61ddfc31.rsa.pub"
# The trailing gitleaks:allow is deliberate: this is the SHA-256 of a PUBLIC signing
# key, published by 1Password at the URL above. It is a checksum to compare against,
# not a credential — worthless to an attacker, and it must be committed for the check
# to mean anything. gitleaks' generic-api-key rule cannot tell a pinned digest from a
# token, so annotate this one line rather than weaken the rule for the whole repo.
OP_APK_KEY_SHA256="0e88171d9f8b7630763f70cbf69f2a01b4ba8ea1d8e79487f59c162db255eb84" # gitleaks:allow

# nvim-treesitter (core/nvim, pinned to `main`) hard-requires this tree-sitter-cli
# version. Named once here because it is asserted in three places that must agree:
# _dotfiles_ts_meets_floor below, install/packages.txt's note on the apk entry, and
# core/PORTING-MATRIX.md footnote 5. Bump it only when Core's floor actually moves.
TREESITTER_FLOOR="0.26.1"

while [[ $# -gt 0 ]]; do case "$1" in
  --links-only) LINKS_ONLY=1 ;;
  --dry-run | -n) DRY=1; LINKS_ONLY=1 ;;
  --only) [[ $# -ge 2 ]] || { echo "--only requires module names, e.g. --only zsh,nvim" >&2; exit 1; }; ONLY_RAW="$2"; ONLY_SEEN=1; shift ;;
  --only=*) ONLY_RAW="${1#*=}"; ONLY_SEEN=1 ;;
  --skip) [[ $# -ge 2 ]] || { echo "--skip requires module names, e.g. --skip tmux" >&2; exit 1; }; SKIP_RAW="$2"; SKIP_SEEN=1; shift ;;
  --skip=*) SKIP_RAW="${1#*=}"; SKIP_SEEN=1 ;;
  -h | --help)
    # Print the whole header block, not a hardcoded line range: the previous
    # `sed -n '2,19p'` stopped before the PREREQUISITE paragraph, hiding the one
    # thing a first-time Alpine user must do (`apk add bash`) because a fresh box
    # has only busybox ash. Walking to the first non-comment line can't drift again.
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); if ($0 !~ /^─+$/) print; next } NR > 1 { exit }' "$0"
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

# ── PATH prelude: make the presence guards below tell the TRUTH ───────────────
# bootstrap runs in BASH, before any Core shell exists, so the user-local bindirs the
# installs below WRITE INTO are not on PATH yet — ~/.local/bin, ~/.cargo/bin and GOBIN
# reach PATH only via core/zsh/00-tools.zsh and os/alpine.zsh, i.e. only inside a Core
# zsh. Every `command -v <tool>` guard in this script was therefore answered by the PATH
# of whatever shell launched it, and on a fresh box that is bash with none of them.
#
# That is not a tidiness point here. mise.run drops its binary in ~/.local/bin, so the
# bare `command -v mise` in _dotfiles_go_install was FALSE for the mise this script had
# installed moments earlier — both arms of the Go fallback missed and the else branch
# announced "needs Go" on a box that had one. openSUSE shipped exactly that and exited 2
# on every bootstrap (dotgibson/dotfiles-core#748); here it stayed invisible only because
# `go` is in install/packages.txt and arm 1 always won. Drop that package and this repo
# loses tools silently, with a green CI.
#
# blib_user_bindirs_on_path is Core's helper for precisely this, resolving CARGO_HOME and
# GOBIN/GOPATH rather than hard-coding them (core/lib/bootstrap-lib.sh). It adds only
# directories that EXIST, so it is called AGAIN inside provision() once the installers
# have created them — see there.
blib_user_bindirs_on_path

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
elif ((DRY)); then
  # A preview changes nothing, so it must not demand the privilege it never uses.
  SU=""
  echo "note: no doas/sudo found — fine for --dry-run, required for a real run." >&2
else
  echo "Need root: run as root, or 'apk add doas' and configure /etc/doas.d." >&2
  exit 1
fi
export BLIB_SU="$SU"

# Hand the preview flag to the shared lib: blib_link / blib_seed / blib_link_core and
# the loader writer all honour BLIB_DRY by planning instead of mutating, and
# blib_wire_summary prefixes its tally with "(dry run)".
if ((DRY)); then export BLIB_DRY=1; fi

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
  local gobin="$HOME/.local/bin"
  mkdir -p "$gobin" 2>/dev/null || true
  if command -v go >/dev/null 2>&1; then
    GOBIN="$gobin" go install "$1" >/dev/null 2>&1 ||
      echo "   $2: go install failed — retry later: GOBIN=$gobin go install $1"
  elif command -v mise >/dev/null 2>&1; then
    # Unreliable: `go@latest` can resolve to mise's go *backend* (a module installer)
    # rather than a Go runtime, in which case nothing is installed and the exec fails.
    # `go` is in Alpine community and is listed in packages.txt — prefer that.
    GOBIN="$gobin" mise exec go@latest -- go install "$1" >/dev/null 2>&1 ||
      echo "   $2: no Go runtime (mise fallback failed) — install it: ${SU:+$SU }apk add go"
  else
    echo "   $2: needs Go — install later with: GOBIN=$gobin go install $1"
  fi
  return 0
}

# ── tree-sitter version floor ─────────────────────────────────────────────────
# nvim-treesitter (pinned to `main` in core/nvim) hard-requires tree-sitter-cli
# >= 0.26.1. Alpine's `community` package IS the musl build, but it only CLEARS
# that floor on v3.24 (0.26.7-r0) and edge (0.26.7-r1) — v3.21 ships 0.24.4-r0
# and v3.22/v3.23 ship 0.25.10-r0. So on three of the four supported stable
# branches, `apk add tree-sitter-cli` succeeds and leaves the box BELOW the floor.
#
# That is why the cargo fallback below is version-guarded and not merely
# presence-guarded: apk's 0.25.10 satisfies `command -v tree-sitter`, so a
# presence guard short-circuits the build and the box lands below the floor
# silently — no error, no warning, nvim-treesitter quietly broken.
#
# The fix works because ~/.cargo/bin is PREPENDED ahead of /usr/bin by
# core/zsh/00-tools.zsh (and by os/alpine.zsh), so a cargo-built 0.26.7 SHADOWS
# apk's older /usr/bin/tree-sitter rather than losing to it. Without that
# ordering this block would build a binary nothing would ever run.

# _dotfiles_ver_lt <a> <b> — true when version a sorts BELOW version b.
# Field-wise integer compare, mirroring ver_cmp in dotfiles-core's
# scripts/research/verify-atuin-guard.sh (not vendored here): no `sort -V`
# (GNU-only; Alpine ships busybox sort) and no string compare, which would
# wrongly rank 0.26.10 below 0.26.9. Non-numeric or missing fields read as 0, so
# a pre-release suffix degrades to "build it" rather than to a parse error.
_dotfiles_ver_lt() { # <a> <b>
  local i x y
  local -a A B
  local IFS=.
  # shellcheck disable=SC2206  # deliberate word-splitting on IFS=. — that IS the parse
  A=(${1%%-*})
  # shellcheck disable=SC2206
  B=(${2%%-*})
  unset IFS
  for ((i = 0; i < 4; i++)); do
    x="${A[i]:-0}"
    y="${B[i]:-0}"
    [[ "$x" =~ ^[0-9]+$ ]] || x=0
    [[ "$y" =~ ^[0-9]+$ ]] || y=0
    ((10#$x < 10#$y)) && return 0
    ((10#$x > 10#$y)) && return 1
  done
  return 1 # equal — the floor is >=, so equality is NOT below it
}

# _dotfiles_ts_meets_floor <floor> — true when SOME already-installed tree-sitter
# clears <floor>. Checks the PATH binary AND ~/.cargo/bin explicitly, because the
# PATH prelude adds only directories that already exist — on a box whose first cargo
# build happens in THIS run, ~/.cargo/bin was created after the prelude and is not on
# this shell's PATH. The same two-part guard the yazi block above relies on. A binary
# whose `--version` cannot be run or parsed counts as NOT meeting the floor.
_dotfiles_ts_meets_floor() { # <floor>
  local floor="$1" cand out ver
  for cand in "$(command -v tree-sitter 2>/dev/null)" "$HOME/.cargo/bin/tree-sitter"; do
    [[ -n "$cand" && -x "$cand" ]] || continue
    out="$("$cand" --version 2>/dev/null)" || continue
    # `tree-sitter --version` prints "tree-sitter 0.26.7"; take the last field.
    ver="${out##* }"
    [[ "$ver" =~ ^[0-9] ]] || continue
    _dotfiles_ver_lt "$ver" "$floor" || return 0
  done
  return 1
}

# ── fetch a file only if it matches a pinned SHA-256 ───────────────────────────
# Downloads to a temp path, verifies, and only then installs to <dest>. Returns
# non-zero WITHOUT writing anything on any failure (fetch, checksum, or install), so
# callers can — and must — fail closed. Mirrors the SHA-256 discipline Core already
# applies to every downloaded release asset (scripts/tool-versions.env +
# .github/actions/setup-core-tools); this script's third-party fetches predate it.
_fetch_verified() { # <url> <sha256> <dest>
  local url="$1" want="$2" dest="$3" tmp got
  tmp="$(mktemp)" || return 1
  # curl first, wget (busybox) as the fallback — a minimal Alpine may have only one.
  if ! curl -fsSL "$url" -o "$tmp" 2>/dev/null && ! wget -qO "$tmp" "$url" 2>/dev/null; then
    echo "   fetch failed: $url" >&2
    rm -f "$tmp"
    return 1
  fi
  got="$(sha256sum <"$tmp" | cut -d' ' -f1)"
  if [[ "$got" != "$want" ]]; then
    echo "   SHA-256 MISMATCH — refusing to install $url" >&2
    echo "     expected: $want" >&2
    echo "     got:      $got" >&2
    rm -f "$tmp"
    return 1
  fi
  # shellcheck disable=SC2086  # $SU: single token (doas/sudo) or empty (root)
  $SU install -m 0644 "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
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

  # Source-build fallbacks. starship, yazi, tree-sitter-cli and viddy now ship in
  # `community` (listed in packages.txt) so apk installs the native musl build first;
  # the presence-guarded blocks below only fire on a box where apk missed the package.
  # The starship/mise installers detect musl and pull the correct *-musl build; atuin
  # is in Alpine repos too — its installer below is likewise just a fallback.
  if ! command -v starship >/dev/null; then
    blib_say "starship (official installer — musl build)"
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y >/dev/null || true
  fi
  if ! command -v atuin >/dev/null; then
    blib_say "atuin (official installer — fallback; usually apk-installed)"
    curl -fsSL https://setup.atuin.sh | sh >/dev/null 2>&1 || true
  fi
  # Only reachable via the fallback above: apk puts atuin in /usr/bin, but the installer
  # hard-codes ~/.atuin/bin (install.sh: ATUIN_BIN="$HOME/.atuin/bin/atuin") and appends its
  # init line to ~/.zshrc — which wire_links() then REPLACES with the managed loader. Since
  # core/zsh/00-tools.zsh prepends only ~/.local/bin before probing for tools, an
  # installer-provisioned atuin would be invisible to a Core shell: no HAVE_ATUIN, no cached
  # init, no Ctrl+E, and the daemon exports in os/alpine.zsh inert. Link it where Core looks.
  # (Same fix as dotfiles-Fedora#80, where the installer path is the NORM rather than a fallback.)
  # Best-effort like every installer fallback around it: this script runs under
  # `set -euo pipefail`, and a convenience symlink must not abort a bootstrap because
  # ~/.local/bin is read-only, HOME is mounted oddly, or something already occupies the
  # target. Warn instead — the failure is recoverable by hand and the warning says how.
  if [[ -x "$HOME/.atuin/bin/atuin" ]] && ! command -v atuin >/dev/null 2>&1; then
    if mkdir -p "$HOME/.local/bin" 2>/dev/null &&
      ln -sf "$HOME/.atuin/bin/atuin" "$HOME/.local/bin/atuin" 2>/dev/null; then
      blib_ok "linked ~/.atuin/bin/atuin -> ~/.local/bin/atuin (so 00-tools.zsh can see it)"
    else
      blib_warn "could not link ~/.atuin/bin/atuin into ~/.local/bin — atuin stays invisible to Core's tool detection; add ~/.atuin/bin to PATH by hand"
    fi
  fi
  # atuin daemon (dotfiles-core#335): there is nothing to INSTALL here — OpenRC has no
  # per-user supervision, so os/alpine.zsh sets ATUIN_DAEMON__AUTOSTART and the atuin client
  # supervises its own daemon. What is worth doing once, here, is telling the operator when
  # the installed build cannot honour that, rather than leaving a silently-inert export: a
  # per-shell probe would cost a fork on every startup, which is the budget this stack guards.
  if command -v atuin >/dev/null 2>&1 && ! atuin daemon --help >/dev/null 2>&1; then
    blib_warn "installed atuin has no 'daemon' subcommand — daemon mode will stay off (upgrade atuin to use it)"
  fi
  if ! command -v mise >/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
    blib_say "mise (official installer — musl build)"
    curl -fsSL https://mise.run | sh >/dev/null 2>&1 || true
  fi
  # Re-run the PATH prelude: the helper adds only directories that already EXIST, and
  # ~/.local/bin is the one mise.run may have just created. Without this second call the
  # `command -v mise` fallback in _dotfiles_go_install below is still blind to it — the
  # whole point of the prelude, one install too late. Idempotent by construction.
  blib_user_bindirs_on_path
  # yazi + tree-sitter-cli: apk installs the community musl build first (packages.txt);
  # this cargo build is the fallback if apk missed it. On musl it compiles against the
  # musl target (needs build-base, in packages.txt).
  #
  # `yazi-build` is the ONLY crate that installs yazi from crates.io. This block previously
  # asked for `yazi-fs`, which is a library crate (no [[bin]]) and can never produce the
  # `yazi` binary the guard above tests for — so the guard stayed false forever and every
  # bootstrap rebuilt the whole yazi workspace (a hundred-plus crates) only to discard it.
  # `yazi-fm` is not the fix either: yazi-cli's build.rs panics on purpose telling you to use
  # `cargo install --force yazi-build`. --force is upstream's own instruction. On musl that
  # rebuild is many minutes, and under `>/dev/null 2>&1` it was indistinguishable from a hang
  # — so let the build talk. (Matches dotfiles-Fedora/bootstrap.sh, documented there at length.)
  #
  # The guard checks ~/.cargo/bin/yazi as well as PATH, and that second test is what makes
  # --force safe: the PATH prelude adds only directories that already exist, so on a box
  # whose first cargo build is in THIS run ~/.cargo/bin was created after it. On PATH alone,
  # a box that already built yazi here would fail `command -v` and --force would rebuild it
  # from source on EVERY bootstrap.
  # Same two-part guard dotfiles-Offense already uses.
  if ! command -v yazi >/dev/null && [[ ! -x "$HOME/.cargo/bin/yazi" ]] && command -v cargo >/dev/null; then
    blib_say "yazi (cargo build from source — slow on musl, output below)"
    cargo install --force --locked yazi-build || true
  fi
  # tree-sitter is VERSION-guarded, not presence-guarded — see the floor helpers
  # near the top of this file for why apk's own package is not enough on v3.21,
  # v3.22 or v3.23. Best-effort like its neighbours: a build hiccup must never
  # abort bootstrap, but it must not pass silently either.
  if ! _dotfiles_ts_meets_floor "$TREESITTER_FLOOR"; then
    if command -v cargo >/dev/null; then
      blib_say "tree-sitter-cli (cargo build — apk's build is below the >=$TREESITTER_FLOOR floor, or absent)"
      cargo install --locked tree-sitter-cli >/dev/null 2>&1 ||
        echo "   tree-sitter-cli build failed; retry later: cargo install --locked tree-sitter-cli"
    else
      # Do NOT let this one go quiet. The whole bug this guard fixes was a box
      # sitting below the floor with nvim-treesitter broken and nothing said.
      blib_warn "tree-sitter-cli is absent or below nvim-treesitter's >=$TREESITTER_FLOOR floor and cargo is not installed — install it (${SU:+$SU }apk add cargo) then: cargo install --locked tree-sitter-cli (or: mise use -g tree-sitter)"
    fi
  fi
  # tealdeer (tldr): `testing`-only on Alpine (never in `community`), so not in
  # packages.txt — build from source via cargo. Presence-guarded on the `tldr`
  # binary; best-effort so a build hiccup never aborts bootstrap.
  if ! command -v tldr >/dev/null && [[ ! -x "$HOME/.cargo/bin/tldr" ]] && command -v cargo >/dev/null; then
    blib_say "tealdeer (cargo build — tldr client; testing-only on Alpine)"
    cargo install --locked tealdeer >/dev/null 2>&1 ||
      echo "   tealdeer build failed; retry later: cargo install --locked tealdeer"
  fi
  # viddy (watch replacement; Core aliases watch->viddy, HAVE_VIDDY-guarded) now ships
  # in `community` (packages.txt) — apk installs it first; this cargo build is the
  # fallback. On musl it compiles the musl target (static, musl-safe), presence-guarded.
  if ! command -v viddy >/dev/null && [[ ! -x "$HOME/.cargo/bin/viddy" ]] && command -v cargo >/dev/null; then
    blib_say "viddy (cargo build — watch replacement; Rust)"
    cargo install --locked viddy >/dev/null 2>&1 ||
      echo "   viddy build failed; retry later: cargo install --locked viddy"
  fi
  # jnv (interactive jq filter): not packaged by Alpine in main, community OR edge, so
  # cargo is its only source here. Plain build — no special flags needed.
  if ! command -v jnv >/dev/null && [[ ! -x "$HOME/.cargo/bin/jnv" ]] && command -v cargo >/dev/null; then
    blib_say "jnv (cargo build — interactive jq filter; unpackaged on Alpine)"
    cargo install --locked jnv >/dev/null 2>&1 ||
      echo "   jnv build failed; retry later: cargo install --locked jnv"
  fi
  # ouch (archive (de)compressor): `testing`-only on Alpine (edge/testing 0.6.1-r0,
  # absent from every stable branch), so cargo is its real source here — the same
  # shape as duf/glow below, which go-install for the same reason.
  #
  # DO NOT "simplify" this to a plain `cargo install --locked ouch`: it FAILS on musl.
  # ouch's DEFAULT features include bzip3, whose libbzip3-sys build script runs bindgen,
  # and bindgen dlopen()s libclang. Rust's musl toolchain builds static binaries, where
  # dlopen is unavailable — so the build dies with "Unable to find libclang: ... Dynamic
  # loading not supported" even though libclang IS installed. Installing clang does not
  # help; the blocker is static linking, not a missing package.
  #
  # Dropping bzip3 avoids bindgen entirely and keeps a static (musl-safe) binary. The
  # alternative — RUSTFLAGS="-C target-feature=-crt-static" — would restore dlopen but
  # give up static linking for every crate in the build. Cost of this choice: no .bz3
  # archives. tar/zip/gz/xz/zstd/bz2/7z all still work.
  if ! command -v ouch >/dev/null && [[ ! -x "$HOME/.cargo/bin/ouch" ]] && command -v cargo >/dev/null; then
    blib_say "ouch (cargo build — archive tool; bzip3 dropped, see comment)"
    cargo install --locked ouch --no-default-features \
      --features unrar,use_zlib,use_zstd_thin >/dev/null 2>&1 ||
      echo "   ouch build failed; retry later: cargo install --locked ouch --no-default-features --features unrar,use_zlib,use_zstd_thin"
  fi

  # ── go-installed core-doctor tools. sesh is unpackaged on Alpine; duf + glow are
  # `testing`-only (NOT in `community` on current stable), so `apk add` skips them —
  # `go install` here is their REAL source, not a fallback. `go install` yields a
  # static (musl-safe) binary; presence-guarded + best-effort, so it no-ops when a
  # tool is already present, and a box without Go just gets a hint. The banner is
  # guarded the same way (those guards live INSIDE the helper, so announcing the step
  # unconditionally would claim work on a box where all three are already installed).
  if ! command -v duf >/dev/null 2>&1 ||
    ! command -v glow >/dev/null 2>&1 ||
    ! command -v sesh >/dev/null 2>&1; then
    blib_say "duf / glow / sesh (go install — testing-only/unpackaged on Alpine; musl-safe static)"
  fi
  _dotfiles_go_install github.com/muesli/duf@latest duf
  # charm.land, NOT github.com: Charm moved its tools off GitHub as a MODULE HOST
  # (glow is charm.land/glow/v3 as of v3.0.0, 2026-08-11; core/PORTING-MATRIX.md
  # records the move). The old github.com/charmbracelet/glow/v2 path still resolves,
  # which is exactly why this went unnoticed — `@latest` on it quietly pins the newest
  # v2 tag, so the box got a stale MAJOR rather than an error.
  _dotfiles_go_install charm.land/glow/v3@latest glow
  _dotfiles_go_install github.com/joshmedeski/sesh/v2@latest sesh

  # ── op (1Password CLI): native musl apk from 1Password's official Alpine repo —
  # NOT a glibc vendor binary. Presence-guarded; best-effort so a fetch/network hiccup
  # never aborts bootstrap. ────────────────────────────────────────────────────────
  # ORDER MATTERS: verify and install the signing key FIRST, and only add the
  # repository once it is trusted. The reverse order — the old one — left a window
  # where /etc/apk/repositories named a third-party repo whose key had silently
  # failed to download (the fetch was `|| true`), and it never removed the repo line.
  if ! command -v op >/dev/null 2>&1; then
    blib_say "op — 1Password CLI (official Alpine repo — native musl apk)"
    local op_key_dest="/etc/apk/keys/${OP_APK_KEY_URL##*/}"
    local have_key=0
    # An ALREADY-PRESENT key is re-verified, not assumed good: every box bootstrapped
    # by the previous version of this script installed this key without ever checking
    # it, so "the file exists" says nothing about what it contains.
    if [[ -f "$op_key_dest" ]]; then
      if [[ "$(sha256sum <"$op_key_dest" | cut -d' ' -f1)" == "$OP_APK_KEY_SHA256" ]]; then
        have_key=1
      else
        # QUARANTINE BEFORE RE-FETCHING, not after. Overwriting on success alone left
        # a hole: if the key on disk is wrong AND the re-fetch then fails (no network,
        # no downloader), the unverified key stays in /etc/apk/keys — and on a box
        # bootstrapped by the old script the repo line is ALREADY present, so apk goes
        # on trusting it. "Failed closed" has to mean the bad key is gone, not merely
        # that we declined to add a new one. Moved OUT of the keys directory (apk
        # matches keys by filename, but leaving it in there invites a manual restore)
        # and kept for forensics rather than deleted.
        # shellcheck disable=SC2086  # $SU: single token or empty (root)
        $SU mv "$op_key_dest" "/etc/apk/${OP_APK_KEY_URL##*/}.untrusted.$(date +%s)" || true
        blib_warn "op: existing signing key did NOT match the pinned digest — quarantined out of /etc/apk/keys"
      fi
    fi
    if ((have_key == 0)) &&
      _fetch_verified "$OP_APK_KEY_URL" "$OP_APK_KEY_SHA256" "$op_key_dest"; then
      have_key=1
    fi
    if ((have_key)); then
      if ! grep -q '1password.com/linux/alpinelinux' /etc/apk/repositories 2>/dev/null; then
        # Back up before the first append: the grep above keeps this idempotent, but
        # idempotent is not recoverable — /etc/apk/repositories is the file that
        # decides what this box will install.
        if [[ -f /etc/apk/repositories ]]; then
          # shellcheck disable=SC2086  # $SU: single token or empty (root)
          $SU cp -p /etc/apk/repositories "/etc/apk/repositories.pre-dotfiles.$(date +%s)" || true
        fi
        # shellcheck disable=SC2086
        echo "https://downloads.1password.com/linux/alpinelinux/stable/" | $SU tee -a /etc/apk/repositories >/dev/null || true
      fi
      # shellcheck disable=SC2086
      { $SU apk update >/dev/null 2>&1 && $SU apk add 1password-cli >/dev/null 2>&1; } ||
        echo "   op: install skipped — add it later with: ${SU:+$SU }apk add 1password-cli"
    else
      # Fail closed. An unverified key would be trusted for EVERY later `apk add` on
      # this box, so a bad or substituted download must cost us `op`, not the
      # integrity of the package manager.
      blib_warn "op: signing key failed verification — repo NOT added, op NOT installed"
    fi
  fi

  # ── WSL: install /etc/wsl.conf. NOTE: no systemd=true — Alpine uses OpenRC. ───
  if ((IS_WSL)); then
    blib_say "installing /etc/wsl.conf (default user + interop; OpenRC, not systemd)"
    local user rendered backup
    user="$(id -un)"
    rendered="$(sed "s/__WSL_USER__/$user/" "$DOTFILES/wsl/wsl.conf")"
    if [[ -f /etc/wsl.conf ]] && printf '%s\n' "$rendered" | cmp -s - /etc/wsl.conf; then
      blib_ok "/etc/wsl.conf already current — left alone"
    else
      # This was the ONE unbacked-up destructive write in the stack: every other
      # writer here backs up first (blib_link moves real files aside as
      # .pre-dotfiles.<epoch>, blib_write_zshrc_loader cp's before rewriting). A
      # hand-tuned /etc/wsl.conf — custom [automount] options, mounts, memory
      # limits — was destroyed silently on every re-run. Same convention, so
      # .gitignore's *.pre-dotfiles.* already covers it.
      if [[ -e /etc/wsl.conf ]]; then
        backup="/etc/wsl.conf.pre-dotfiles.$(date +%s)"
        # shellcheck disable=SC2086  # $SU: single token or empty (root)
        $SU cp -p /etc/wsl.conf "$backup"
        blib_warn "existing /etc/wsl.conf backed up -> $backup"
      fi
      # shellcheck disable=SC2086
      printf '%s\n' "$rendered" | $SU tee /etc/wsl.conf >/dev/null
      blib_ok "wsl.conf written — run 'wsl.exe --shutdown' from Windows, then reopen"
    fi
  fi
}

wire_links() {
  # The whole shared symlink surface + the Alpine OS overlays + the managed .zshrc
  # loader + the default-login-shell switch now live in core/lib/bootstrap-lib.sh.
  blib_link_core "$DOTFILES" "$CONFIG"
  blib_link_os_layer "$DOTFILES" "$CONFIG" alpine
  # shellcheck disable=SC2119  # no args is intentional — writes the default module set
  blib_write_zshrc_loader
  # ~/.zshenv (Alpine-only): sets ZDOTDIR so /etc/zsh/zshrc's XDG nudge stops warning
  # about "startup files both in ~/ and ~/.config/zsh/" — a false positive, since Core
  # seeds the latter as a symlink to the former. See zsh/zshenv.zsh for the rationale.
  # AFTER blib_write_zshrc_loader: that writes ~/.zshrc, which this file's ZDOTDIR
  # then points at.
  blib_say "symlinking zsh/zshenv.zsh (Alpine ZDOTDIR shim)"
  blib_link "$DOTFILES/zsh/zshenv.zsh" "$HOME/.zshenv"
  blib_set_login_shell
  # Local guardrail against hand-editing the vendored subtree. The hook lives in
  # .git/hooks, which is not version-controlled — so a fresh clone has NO protection
  # until something installs it. sync-core.sh reinstalls it on every fan-out, but
  # that only ever runs on the maintainer's machine; a bootstrap is the other place
  # a clone becomes a working repo. CI's core-integrity check is the backstop, not
  # the first line. Skipped under --dry-run: it writes a file.
  if ((DRY)); then
    blib_say "(dry run) would install the core/ pre-commit guard"
  else
    blib_install_core_guard "$DOTFILES"
  fi
  if ((DRY)); then
    blib_ok "dry run complete — nothing was changed$(blib_selected_note)"
  else
    blib_ok "symlinks wired$(blib_selected_note)"
  fi
  blib_wire_summary
}

((LINKS_ONLY)) || provision
wire_links
if ((DRY)); then
  blib_ok "dry run finished — re-run without --dry-run to apply"
else
  blib_ok "Alpine bootstrap complete — open a new shell or: exec zsh"
fi
