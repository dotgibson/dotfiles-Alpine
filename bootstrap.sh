#!/usr/bin/env bash
# dotfiles-Alpine/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# Provision an Alpine box (bare-metal / VM / container / WSL) and wire dotfiles.
# Idempotent. OS-NATIVE layer; Core (zsh/tmux/nvim/git) is vendored under core/.
# Alpine is the outlier: musl libc, doas (not sudo), ash default shell, OpenRC.
#
# SHAPE (dotgibson/dotfiles-core#976): this file DECLARES what it is and DEFINES the
# hooks that are Alpine's, then hands over to Core's bootstrap driver, blib_main — the
# shared skeleton every bootstrap.sh in the fleet used to carry by hand (the flag loop,
# the escalator, the sudo keepalive, the Core symlink surface + the OS overlays, the
# managed ~/.zshrc loader, the login shell, the closing report) runs from ONE definition
# in core/lib/bootstrap-lib.sh. What stays here: the Alpine check, the apk phase with
# its musl source-build fallbacks and the 1Password repo, /etc/wsl.conf, and the
# ~/.zshenv ZDOTDIR shim.
#
# Run `./bootstrap.sh --help` for usage — bootstrap_usage() below is this repo's half of
# it (including the one thing a first-time Alpine user must do first: `apk add bash`);
# the driver appends the shared flags.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"

# ── what this bootstrap IS (read by blib_main) ────────────────────────────────
# doas-first: the fact os/alpine.capabilities declares, kept on the rare Alpine box that
# has sudo too. The driver resolves the escalator with `blib_resolve_su --prefer doas`
# (dotfiles-core#879 added the flag for exactly this file; test/check-root-probe.sh pins
# the declaration and the lib's root rule together) — --require on a real run, best-effort
# on --links-only and --dry-run, which change nothing privileged. An explicit BLIB_SU=
# from the caller still wins (CI's --links-only leg sets it empty). Every install below
# is best-effort and recorded in Core's ledger; the closing report lists the misses and
# --strict turns them into exit 1 (STRICT_DEFAULT stays 0: a rate-limited API or a crate
# that fails to build on musl must not strand the rest of a fresh box).
# shellcheck disable=SC2034  # read by the vendored driver, which shellcheck cannot see
BOOTSTRAP_NAME="Alpine"
# shellcheck disable=SC2034
BOOTSTRAP_OS=alpine
# shellcheck disable=SC2034
BOOTSTRAP_SU_PREFER=doas

# The Alpine half of --help; the driver prints the shared flags after it. Every flag
# this repo takes is a shared one, so this half is what the flags cannot say.
# shellcheck disable=SC2329  # called by the vendored driver
bootstrap_usage() {
  cat <<'EOF'
bootstrap.sh — provision an Alpine box (bare-metal / VM / container / WSL) and wire dotfiles.

  ./bootstrap.sh                 full: apk packages + extras + symlinks
  ./bootstrap.sh --links-only    just (re)create symlinks (no apk)
  ./bootstrap.sh --dry-run       preview the wiring; change nothing (provisioning is
                                 skipped rather than faked — it installs packages and
                                 touches system files, which cannot be previewed)
  ./bootstrap.sh --strict        exit 1 if any best-effort install did not complete

Module groups (for --only/--skip): zsh nvim tmux git prompt tools — they affect the
  wiring steps only, never package provisioning; combine with --links-only to re-wire
  a subset of configs without touching apk.

Run as root, OR as a user with doas/sudo configured (Alpine defaults to doas).

PREREQUISITE — bash: this script is bash (it uses arrays + mapfile), but a fresh Alpine
  ships only busybox ash, so bash is NOT present by default. Install it FIRST or the
  kernel can't exec this file ("bad interpreter: bash: not found"):
      apk add bash     # (or: doas apk add bash)
  bash is also listed in install/packages.txt so a full provision keeps it installed.

Env overrides:
  BLIB_SU     privilege escalator. Resolved by Core's blib_resolve_su when unset:
              root runs directly, else doas, else sudo. Set it empty or to `sudo`
              to override the probe.
  BLIB_DRY    set to 1 for the same effect as --dry-run
  DOTFILES_MISE_INSTALL
              1 installs the lean mise runtime set (node pnpm python ruby lua, ~435 MiB);
              all installs every runtime in core/mise/config.toml (~2.3 GiB). Unset: list
              what is missing and change nothing.
EOF
}

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

# Neovim itself. nvim-treesitter's `main` branch does not merely prefer 0.12 — it
# will not load below it, so this floor and TREESITTER_FLOOR above are two halves of
# ONE requirement, and only one of them used to be checked. Read by
# _dotfiles_nvim_meets_floor below; the fleet-wide version table lives in
# core/PORTING-MATRIX.md footnote 33. Bump it only when Core's floor actually moves.
NEOVIM_FLOOR="0.12.0"

# ── core/ subtree present? (inline: can't source a lib out of core/ before this) ─
# Validate the SPECIFIC paths we depend on below — the zsh modules the driver
# symlinks, plus the two libs sourced next — so a missing or partially-vendored
# subtree fails HERE with a precise message, not later with a cryptic
# `source: No such file`.
for _req in core/zsh/loader.zsh core/lib/ux.sh core/lib/bootstrap-lib.sh; do
  if [[ ! -e "$DOTFILES/$_req" ]]; then
    echo "vendored core/ missing or incomplete (need $_req). To populate it:" >&2
    echo "  make sync          # in dotfiles-core — the fan-out that also stamps core.lock" >&2
    echo "If core/ does not exist AT ALL the fan-out skips this repo; do the one-time" >&2
    echo "vendor first, from a RELEASED TAG (never main, or core-integrity reports the" >&2
    echo "fresh tree as TAMPERED), then sync:" >&2
    echo "  git subtree add --prefix=core <dotfiles-core remote> refs/tags/v7 --squash" >&2
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

# ── PATH prelude ──────────────────────────────────────────────────────────────
# The driver runs blib_user_bindirs_on_path before any probe, so the `command -v`
# guards below see ~/.local/bin, ~/.cargo/bin and GOBIN on a box that has them
# (dotgibson/dotfiles-core#748 — the mise.run miss that exited openSUSE 2 on every run).
# It adds only directories that EXIST, so bootstrap_provision calls it AGAIN once the
# installers have created them — see there.

# ── guard: the Alpine check ───────────────────────────────────────────────────
# shellcheck disable=SC2329
bootstrap_guard() {
  # ── sanity: confirm we're on Alpine ────────────────────────────────────────────
  if ! grep -qiE '^ID=alpine' /etc/os-release 2>/dev/null; then
    echo "This bootstrap targets Alpine Linux (expects ID=alpine in /etc/os-release)." >&2
    exit 1
  fi
}

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
    $SU apk add "$p" || blib_note_fail "package '$p' — unavailable on this box? check: apk search $p"
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
      blib_note_fail "$2 — go install failed; retry later: GOBIN=$gobin go install $1"
  elif command -v mise >/dev/null 2>&1; then
    # Unreliable: `go@latest` can resolve to mise's go *backend* (a module installer)
    # rather than a Go runtime, in which case nothing is installed and the exec fails.
    # `go` is in Alpine community and is listed in packages.txt — prefer that.
    # `mise install go@latest` FIRST: Core's mise/config.toml sets auto_install = false,
    # and mise (verified 2026.10.7) carries that into exec_auto_install, so a bare
    # `mise exec go@latest` on a box with no Go fails in ~2s instead of downloading it
    # (dotgibson/dotfiles-Fedora#209). It is a no-op once Go is present.
    { mise install go@latest && GOBIN="$gobin" mise exec go@latest -- go install "$1"; } >/dev/null 2>&1 ||
      blib_note_fail "$2 — Go via mise failed (toolchain install or build); install Go with: ${SU:+$SU }apk add go, or retry: mise install go@latest && GOBIN=$gobin mise exec go@latest -- go install $1"
  else
    blib_note_fail "$2 — needs Go; install later with: GOBIN=$gobin go install $1"
  fi
  return 0
}

# ── mise runtimes: foundry excluded system-wide, the install itself opt-in ────
# core doctor only checks that the mise BINARY exists, so a box could report all green
# with every runtime in core/mise/config.toml still `(missing)`: bootstrap installed
# mise but never asked it to install anything (auto_install = false).
#
# foundry first. mise pulls it as a glibc-linked prebuilt that cannot run on musl, and
# core/mise/config.toml says to exclude it with disable_tools. WHERE that setting lives is
# the whole question:
#   · MISE_DISABLE_TOOLS in zsh/zshenv.zsh never reaches the daily maint runner — it is
#     bash under a scheduler, so `mise upgrade --yes` there would still trip on foundry.
#   · ~/.config/mise/conf.d/ OUTRANKS config.toml, so `mise use -g` would start writing
#     THERE (see blib_adopt in core/lib/bootstrap-lib.sh).
#   · editing the adopted ~/.config/mise/config.toml shows up as drift on every re-run.
# The system config (/etc/mise/config.toml) has none of those problems: every mise process
# reads it, it ranks below the user's global config, and `mise use -g` never writes it.
#
# Then the runtimes. On musl mise compiles ruby from source (all_compile — see the headers
# block in install/packages.txt; node and python are pulled as musl prebuilts instead), so a
# plain bootstrap only says what is missing. DOTFILES_MISE_INSTALL=1 installs the LEAN set
# below; DOTFILES_MISE_INSTALL=all installs every runtime Core declares.
#
# LEAN BY DEFAULT (dotfiles-Alpine#221). The full [tools] set lands at ~2.3 GiB under $HOME on
# this layer — zig 369 MiB, java 344 MiB, go 243 MiB, terraform 115 MiB, rust ~780 MiB even on
# rustup's minimal profile — and it filled an 8 GiB VM. Two of those are second toolchains
# here: install/packages.txt already provides `go` and `cargo` via apk. So bootstrap installs
# only the interpreters this layer leans on (~435 MiB) and DEFERS the rest. Nothing is removed
# from Core's config and nothing is hidden with disable_tools: the deferred tools stay
# declared, `mise ls --missing` keeps naming them, and `mise install java` (or =all) brings
# them in later. The deferred set is "everything not lean" rather than a second hard-coded
# list, so a tool Core adds later is deferred by default, not installed.
ALPINE_MISE_LEAN="node pnpm python ruby lua"

# _alpine_mise_select <mode> <missing…> — print the tools bootstrap will install, in the
# order given: mode `1` keeps those in ALPINE_MISE_LEAN, `all` keeps every tool, anything
# else keeps none. Pure (no mise, no filesystem), so test/check-mise-select.sh can evaluate
# it directly rather than stub mise.
_alpine_mise_select() { # <mode> <missing…>
  local mode="$1" t
  shift
  local -a keep=()
  for t in "$@"; do
    case "$mode" in
      all) keep+=("$t") ;;
      1) [[ " $ALPINE_MISE_LEAN " == *" $t "* ]] && keep+=("$t") ;;
    esac
  done
  ((${#keep[@]})) && printf '%s\n' "${keep[*]}"
  return 0
}

_alpine_mise_runtimes() {
  local mise_bin missing sysconf=/etc/mise/config.toml
  mise_bin="$(command -v mise 2>/dev/null)" || mise_bin="$HOME/.local/bin/mise"
  [[ -x $mise_bin ]] || return 0

  # Rewritten whenever it differs, so a box bootstrapped before a setting landed picks it up.
  # A file WITHOUT this script's marker line is an admin's, not ours: back it up first,
  # same .pre-dotfiles.<epoch> convention as /etc/wsl.conf below.
  local marker='# Written by dotfiles-Alpine bootstrap.sh' settings_ok=1 backup
  local want
  want="$(printf '%s\n' \
    "$marker — re-run bootstrap to update; do not edit." \
    '# System-level so the scheduled maint runner (bash, not zsh) sees it too.' \
    '[settings]' \
    '# foundry ships only a glibc prebuilt, which cannot run on musl.' \
    'disable_tools = ["foundry"]' \
    '# mise defaults to 8 parallel installs; on musl that is 3 concurrent source builds,' \
    '# which OOM-hangs a small VM outright (1 GB, no swap). One at a time.' \
    'jobs = 1' \
    '# node: unofficial-builds.nodejs.org ships musl prebuilts, so skip the 20+ min compile.' \
    'node.flavor = "musl"' \
    'node.mirror_url = "https://unofficial-builds.nodejs.org/download/release/"' \
    'node.compile = false' \
    '# python: python-build-standalone ships musl prebuilts (dynamic — musllinux wheels load).' \
    '# Explicit, because mise only implies all_compile=true on Alpine until 2027.8.0.' \
    'python.compile = false' \
    '# ruby: no musl prebuilt exists (jdx/ruby ships glibc + macOS only), so compile. Explicit' \
    '# for the same reason — without it, ruby errors out once that implicit default goes away.' \
    'ruby.compile = true')"
  if [[ "$(cat "$sysconf" 2>/dev/null)" != "$want" ]]; then
    blib_say "mise: writing musl settings (no foundry, jobs=1, prebuilt node/python) to $sysconf"
    if [[ -e $sysconf ]] && ! grep -qsF "$marker" "$sysconf"; then
      backup="$sysconf.pre-dotfiles.$(date +%s)"
      # shellcheck disable=SC2086  # $SU: single token or empty (root)
      if $SU cp -p "$sysconf" "$backup"; then
        blib_warn "existing $sysconf was not bootstrap's — backed up -> $backup (merge any settings you need back in)"
      else
        settings_ok=0
      fi
    fi
    # shellcheck disable=SC2086
    if ((settings_ok)) && ! { $SU mkdir -p "${sysconf%/*}" && printf '%s\n' "$want" | $SU tee "$sysconf" >/dev/null; }; then
      settings_ok=0
    fi
    ((settings_ok)) ||
      blib_note_fail "mise musl settings — could not back up or write $sysconf; re-run bootstrap as a user with ${SU:-root} access"
  fi

  # From $HOME, not the repo: mise walks up from the cwd for project configs.
  missing="$(cd "$HOME" && "$mise_bin" ls --missing 2>/dev/null | awk '{print $1}' | paste -sd' ' -)" || true
  [[ -n $missing ]] || return 0
  local mode="${DOTFILES_MISE_INSTALL:-0}" tools deferred="" t
  if [[ $mode != 1 && $mode != all ]]; then
    blib_say "mise runtimes not installed: $missing — run \`mise install\`, or re-bootstrap with DOTFILES_MISE_INSTALL=1 (lean: $ALPINE_MISE_LEAN) or DOTFILES_MISE_INSTALL=all"
    return 0
  fi
  # shellcheck disable=SC2086  # $missing: space-separated tool names, word-split on purpose
  tools="$(_alpine_mise_select "$mode" $missing)"
  for t in $missing; do
    [[ " $tools " == *" $t "* ]] || deferred+="${deferred:+ }$t"
  done
  # ruby still compiles from source. Below ~2 GiB of RAM+swap that compile is
  # what hangs the box, so refuse rather than brick it; swap is enough to get past it.
  local mem_kib
  mem_kib="$(awk '/^(MemTotal|SwapTotal):/ {t += $2} END {print t + 0}' /proc/meminfo 2>/dev/null)" || mem_kib=0
  # Disk: the full set lands at ~2.3 GiB under $HOME (zig/java/go/node are 200-370 MiB
  # each, rust ~780 MiB on the minimal profile below) plus downloads and ruby's build tree
  # in flight — so ~4 GiB free for `all`. The lean set is ~435 MiB installed; ~2 GiB free
  # covers it with the same in-flight margin. An 8 GiB VM with swap ran out mid-install,
  # and rustup reports that only as "failed to extract package: IO receiver … disconnected"
  # — so check up front.
  local disk_kib need_gib=2
  [[ $mode == all ]] && need_gib=4
  disk_kib="$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 {print $4 + 0}')" || disk_kib=0
  # Without those settings the install is the 8-way parallel source build that hangs the
  # box — the exact thing this function exists to prevent — so don't run it.
  if [[ -z $tools ]]; then
    : # nothing in this mode's set is missing; the deferred line below covers the rest
  elif ((settings_ok == 0)); then
    blib_note_fail "mise runtimes — skipped: $sysconf is not in place (see above), and without it mise builds in parallel; fix that, then re-run with DOTFILES_MISE_INSTALL=$mode"
  elif ((mem_kib < 2 * 1024 * 1024)); then
    blib_note_fail "mise runtimes — skipped: $((mem_kib / 1024)) MiB RAM+swap is too little to compile ruby (needs ~2 GiB). Add swap (${SU:+$SU }fallocate -l 2G /swapfile && ${SU:+$SU }chmod 600 /swapfile && ${SU:+$SU }mkswap /swapfile && ${SU:+$SU }swapon /swapfile), then re-run with DOTFILES_MISE_INSTALL=$mode"
  elif ((disk_kib < need_gib * 1024 * 1024)); then
    blib_note_fail "mise runtimes — skipped: $((disk_kib / 1024)) MiB free under $HOME; the $([[ $mode == all ]] && echo full || echo lean) set needs ~$need_gib GiB while installing. Grow the disk (or free space), then re-run with DOTFILES_MISE_INSTALL=$mode"
  else
    # rust: mise installs rustup only when it is absent, then reads `rustup show profile`
    # and, on `default`, adds clippy + rust-docs + rustfmt — 1.5 GiB. Pre-installing rustup
    # on the minimal profile makes mise skip its own rustup-init and install a bare
    # toolchain (~780 MiB); rustfmt is added back after, since conform's rustfmt needs it.
    # Only when rust is about to be installed (it is not in the lean set, so only under
    # =all today), so an existing box's profile is left alone.
    local rust_new=0 rustup_bin="${CARGO_HOME:-$HOME/.cargo}/bin/rustup"
    if [[ " $tools " == *" rust "* ]]; then
      rust_new=1
      if [[ -x $rustup_bin ]]; then
        "$rustup_bin" set profile minimal >/dev/null 2>&1
      elif command -v rustup-init >/dev/null 2>&1; then
        rustup-init -y --no-modify-path --default-toolchain none --profile minimal >/dev/null 2>&1
      fi
      # Fail closed: on any other profile mise pulls the 1.5 GiB default set, which is the
      # disk-exhaustion this exists to prevent. Install everything else; leave rust out.
      if [[ "$("$rustup_bin" show profile 2>/dev/null)" != minimal ]]; then
        rust_new=0
        tools="$(tr ' ' '\n' <<<"$tools" | grep -vx rust | paste -sd' ' -)"
        blib_note_fail "rust — skipped: could not put rustup on the minimal profile (apk rustup missing, or rustup-init / rustup set profile failed); retry: ${SU:+$SU }apk add rustup && rustup-init -y --no-modify-path --default-toolchain none --profile minimal && mise install rust"
      fi
    fi
    if [[ -n $tools ]]; then
      blib_say "mise runtimes ($([[ $mode == all ]] && echo full || echo lean) set): $tools (ruby builds from source on musl — this takes a while)"
      # shellcheck disable=SC2086  # $tools: space-separated tool names, word-split on purpose
      (cd "$HOME" && "$mise_bin" install $tools) ||
        blib_note_fail "mise runtimes — some failed to install; retry: mise install $tools"
    fi
    if ((rust_new)) && [[ -x $rustup_bin ]]; then
      # `mise exec` pins RUSTUP_TOOLCHAIN to whatever version the config resolved to.
      (cd "$HOME" && "$mise_bin" exec rust -- rustup component add rustfmt >/dev/null 2>&1) ||
        blib_note_fail "rustfmt — could not add it to mise's rust; retry: mise exec rust -- rustup component add rustfmt"
    fi
  fi
  # By design, so blib_say and not blib_note_fail: --strict must not turn a deferral into exit 1.
  if [[ -n $deferred ]]; then
    blib_say "mise runtimes deferred (not in the lean set): $deferred — install with DOTFILES_MISE_INSTALL=all, or later: mise install $deferred"
  fi
  return 0
}

# ── nvim-treesitter version floors (tree-sitter-cli AND neovim) ───────────────
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

# _dotfiles_nvim_meets_floor <floor> — true when the nvim that will actually RUN
# clears <floor>. PATH-only on purpose, unlike its tree-sitter sibling: there is no
# cargo/user-local neovim to also probe here (no cargo crate ships the binary, and the
# PATH prelude already puts mise shims and ~/.local/bin ahead of /usr/bin), so whatever
# `command -v nvim` resolves to IS what Core's config loads. An nvim whose --version
# cannot be run or parsed counts as NOT meeting the floor — same fail-loud default.
_dotfiles_nvim_meets_floor() { # <floor>
  local floor="$1" cand out ver
  cand="$(command -v nvim 2>/dev/null)" || return 1
  [[ -n "$cand" && -x "$cand" ]] || return 1
  out="$("$cand" --version 2>/dev/null)" || return 1
  # `nvim --version` prints "NVIM v0.12.2" on its first line; take that line's last
  # field and drop the leading "v". Dev builds print "NVIM v0.12.0-dev-1234+gabc123",
  # which _dotfiles_ver_lt truncates at the first "-" — 0.12.0-dev reads as 0.12.0.
  out="${out%%$'\n'*}"
  ver="${out##* }"
  ver="${ver#v}"
  [[ "$ver" =~ ^[0-9] ]] || return 1
  _dotfiles_ver_lt "$ver" "$floor" && return 1
  return 0
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

# Script scope, so cleanup only ever consumes a dir THIS invocation's mktemp made: a
# --links-only or --dry-run run never calls _boot_tmp_setup but still reaches
# bootstrap_closing, and must not act on a _BOOT_TMP inherited from the environment.
_BOOT_TMP=""
export -n _BOOT_TMP 2>/dev/null || true

# ── cargo builds go to DISK, not /tmp (dotfiles-Fedora#208) ────────────────────
# `cargo install` builds in $TMPDIR (default /tmp), and yazi-build nests a second build
# there too. Where /tmp is a tmpfs (systemd's default, often with a per-user quota) a few
# crates fill it on a small box, and every later build and download fails with EDQUOT /
# ENOSPC. _boot_tmp_setup points TMPDIR at a per-run dir on disk for the rest of
# provisioning — unique per run (mktemp -d), so the sweeps below never reach into a
# second bootstrap running at the same time. Ported from dotfiles-Fedora.
_boot_tmp_setup() {
  _BOOT_TMPDIR_ORIG="${TMPDIR-}"
  _BOOT_TMPDIR_WAS_SET="${TMPDIR+1}"
  _BOOT_TMP=""
  local base="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles-bootstrap"
  if ! mkdir -p "$base" 2>/dev/null; then
    _BOOT_TMP=""
    return 0
  fi
  # Stale run dirs first. The EXIT trap below covers `set -e` and signals, but not SIGKILL,
  # the OOM killer or a power-off — exactly the small-VM deaths #222 is about — and each of
  # those strands a run dir holding mise's scratch and ruby's build tree (dotfiles-Alpine#221
  # measured ~1.2 GB of it). Only dirs older than a day, so a concurrent run still compiling
  # ruby is never touched; busybox find (-mtime +0 = more than 24 h).
  /usr/bin/find "$base" -mindepth 1 -maxdepth 1 -type d -name 'run.*' -mtime +0 -exec rm -rf {} + 2>/dev/null || true
  if _BOOT_TMP="$(mktemp -d "$base/run.XXXXXX" 2>/dev/null)"; then
    export TMPDIR="$_BOOT_TMP"
  else
    _BOOT_TMP=""
    return 0
  fi
  # Clean up on an ABORT too (a hard exit, or set -e), not only via bootstrap_closing —
  # else every interrupted run strands a multi-GB run dir that no later run removes.
  # Chain onto the EXIT trap already set (Core's sudo-keepalive stop); never replace it.
  # `trap -p` prints `trap -- '<cmd>' EXIT`, shell-quoted; eval re-splits it safely.
  local prev
  local -a parts=()
  prev="$(trap -p EXIT)"
  eval "parts=(${prev:-})"
  # shellcheck disable=SC2064  # expand NOW, on purpose: it embeds the existing command
  trap "${parts[2]:+${parts[2]}; }_boot_tmp_cleanup" EXIT
  return 0
}

# cargo_install <args…> — `cargo install`, then sweep its build dirs even on FAILURE:
# cargo keeps cargo-install* when a build dies, and yazi-build keeps its nested
# yazi-build-*, so one failed crate would strand GBs for the rest of the run.
cargo_install() {
  local rc=0
  cargo install "$@" || rc=$?
  if [[ -n "${_BOOT_TMP:-}" ]]; then
    rm -rf -- "$_BOOT_TMP"/cargo-install* "$_BOOT_TMP"/yazi-build-*
  fi
  return "$rc"
}

# _boot_tmp_cleanup — called from bootstrap_closing and the EXIT trap: drop the per-run dir and hand the
# caller's TMPDIR back. The path guard keeps this rm from ever aiming at anything else.
_boot_tmp_cleanup() {
  if [[ "${_BOOT_TMP:-}" == */dotfiles-bootstrap/run.* ]]; then
    rm -rf -- "$_BOOT_TMP"
    if [[ -n "${_BOOT_TMPDIR_WAS_SET:-}" ]]; then
      export TMPDIR="$_BOOT_TMPDIR_ORIG"
    else
      unset TMPDIR
    fi
    _BOOT_TMP="" # once only: the EXIT trap calls this again after bootstrap_closing
  fi
  return 0
}

# ── the apk phase (full runs only; the driver runs it under the sudo keepalive) ─
# The keepalive is a no-op for doas (no refreshable timestamp) and for root — this
# box's normal case.
# shellcheck disable=SC2329
bootstrap_provision() {
  _boot_tmp_setup
  # $SU is what every privileged line below invokes: a single token (an absolute path to
  # doas or sudo) or empty when root — the value the driver resolved and escalates with.
  SU="$BLIB_SU"
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
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y >/dev/null ||
      blib_note_fail "starship — installer failed; retry: curl -fsSL https://starship.rs/install.sh | sh -s -- -y"
  fi
  if ! command -v atuin >/dev/null; then
    blib_say "atuin (official installer — fallback; usually apk-installed)"
    curl -fsSL https://setup.atuin.sh | sh >/dev/null 2>&1 ||
      blib_note_fail "atuin — installer failed; retry: curl -fsSL https://setup.atuin.sh | sh"
  fi
  # Only reachable via the fallback above: apk puts atuin in /usr/bin, but the installer
  # hard-codes ~/.atuin/bin (install.sh: ATUIN_BIN="$HOME/.atuin/bin/atuin") and appends its
  # init line to ~/.zshrc — which the driver then REPLACES with the managed loader. Since
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
      blib_note_fail "could not link ~/.atuin/bin/atuin into ~/.local/bin — atuin stays invisible to Core's tool detection; add ~/.atuin/bin to PATH by hand"
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
    curl -fsSL https://mise.run | sh >/dev/null 2>&1 ||
      blib_note_fail "mise — installer failed; retry: curl -fsSL https://mise.run | sh"
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
    cargo_install --force --locked yazi-build ||
      blib_note_fail "yazi — cargo build failed; retry: cargo install --force --locked yazi-build"
  fi
  # tree-sitter is VERSION-guarded, not presence-guarded — see the floor helpers
  # near the top of this file for why apk's own package is not enough on v3.21,
  # v3.22 or v3.23. Best-effort like its neighbours: a build hiccup must never
  # abort bootstrap, but it must not pass silently either.
  if ! _dotfiles_ts_meets_floor "$TREESITTER_FLOOR"; then
    if command -v cargo >/dev/null; then
      blib_say "tree-sitter-cli (cargo build — apk's build is below the >=$TREESITTER_FLOOR floor, or absent)"
      cargo_install --locked tree-sitter-cli >/dev/null 2>&1 ||
        blib_note_fail "tree-sitter-cli — cargo build failed; retry later: cargo install --locked tree-sitter-cli"
    else
      # Do NOT let this one go quiet. The whole bug this guard fixes was a box
      # sitting below the floor with nvim-treesitter broken and nothing said.
      blib_warn "tree-sitter-cli is absent or below nvim-treesitter's >=$TREESITTER_FLOOR floor and cargo is not installed — install it (${SU:+$SU }apk add cargo) then: cargo install --locked tree-sitter-cli (or: mise use -g tree-sitter)"
    fi
  fi
  # neovim: the OTHER half of the nvim-treesitter requirement, and the half that had
  # no guard at all. The block above version-checks tree-sitter-cli for nvim-treesitter's
  # sake, then packages.txt installs a `neovim` that nvim-treesitter will not load on at
  # all on v3.21 (0.10.4), v3.22 (0.11.1) and v3.23 (0.11.7) — the dependency was
  # checked, the thing it is a dependency OF was not (dotfiles-Alpine#170).
  #
  # Warn-only, deliberately: there is no cargo or musl-safe prebuilt fallback to offer.
  # Neovim's own releases are glibc-linked AppImages, which do not run here, so building
  # from source is the only route and that is a minutes-long job with its own toolchain
  # — not something to start unasked mid-bootstrap. Point at the two real fixes and let
  # the operator choose. The one thing this must NOT do is stay silent, which is exactly
  # the failure mode the tree-sitter guard above exists to prevent.
  if ! _dotfiles_nvim_meets_floor "$NEOVIM_FLOOR"; then
    blib_warn "neovim is absent or below nvim-treesitter's >=$NEOVIM_FLOOR floor (v3.21/v3.22/v3.23 ship 0.10.x-0.11.x) — nvim-treesitter will not load. Fix: move this box to v3.24+ or edge, or install a newer nvim (mise use -g neovim@0.12)"
  fi
  # tealdeer (tldr): `testing`-only on Alpine (never in `community`), so not in
  # packages.txt — build from source via cargo. Presence-guarded on the `tldr`
  # binary; best-effort so a build hiccup never aborts bootstrap.
  if ! command -v tldr >/dev/null && [[ ! -x "$HOME/.cargo/bin/tldr" ]] && command -v cargo >/dev/null; then
    blib_say "tealdeer (cargo build — tldr client; testing-only on Alpine)"
    cargo_install --locked tealdeer >/dev/null 2>&1 ||
      blib_note_fail "tealdeer — cargo build failed; retry later: cargo install --locked tealdeer"
  fi
  # viddy (watch replacement; Core aliases watch->viddy, HAVE_VIDDY-guarded) now ships
  # in `community` (packages.txt) — apk installs it first; this cargo build is the
  # fallback. On musl it compiles the musl target (static, musl-safe), presence-guarded.
  # Note apk's viddy is the pre-rewrite Go 0.4.0 on every branch (v3.21 through edge),
  # not upstream's Rust 1.x — and since this guard checks presence only, the Rust build
  # never runs once apk has installed it. Harmless: Core uses only `watch`->`viddy`.
  if ! command -v viddy >/dev/null && [[ ! -x "$HOME/.cargo/bin/viddy" ]] && command -v cargo >/dev/null; then
    blib_say "viddy (cargo build — watch replacement; Rust)"
    cargo_install --locked viddy >/dev/null 2>&1 ||
      blib_note_fail "viddy — cargo build failed; retry later: cargo install --locked viddy"
  fi
  # jnv (interactive jq filter): not packaged by Alpine in main, community OR edge, so
  # cargo is its only source here. Plain build — no special flags needed.
  if ! command -v jnv >/dev/null && [[ ! -x "$HOME/.cargo/bin/jnv" ]] && command -v cargo >/dev/null; then
    blib_say "jnv (cargo build — interactive jq filter; unpackaged on Alpine)"
    cargo_install --locked jnv >/dev/null 2>&1 ||
      blib_note_fail "jnv — cargo build failed; retry later: cargo install --locked jnv"
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
    cargo_install --locked ouch --no-default-features \
      --features unrar,use_zlib,use_zstd_thin >/dev/null 2>&1 ||
      blib_note_fail "ouch — cargo build failed; retry later: cargo install --locked ouch --no-default-features --features unrar,use_zlib,use_zstd_thin"
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
        blib_note_fail "op — install skipped; add it later with: ${SU:+$SU }apk add 1password-cli"
    else
      # Fail closed. An unverified key would be trusted for EVERY later `apk add` on
      # this box, so a bad or substituted download must cost us `op`, not the
      # integrity of the package manager.
      blib_note_fail "op — signing key failed verification; repo NOT added, op NOT installed"
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

# ── after the managed ~/.zshrc, before the login shell ────────────────────────
# shellcheck disable=SC2329
bootstrap_wire_post_loader() {
  # ~/.zshenv (Alpine-only): sets ZDOTDIR so /etc/zsh/zshrc's XDG nudge stops warning
  # about "startup files both in ~/ and ~/.config/zsh/" — a false positive, since Core
  # seeds the latter as a symlink to the former. See zsh/zshenv.zsh for the rationale.
  # AFTER blib_write_zshrc_loader: that writes ~/.zshrc, which this file's ZDOTDIR
  # then points at.
  blib_say "symlinking zsh/zshenv.zsh (Alpine ZDOTDIR shim)"
  blib_link "$DOTFILES/zsh/zshenv.zsh" "$HOME/.zshenv"

  # mise runtimes run HERE, not in bootstrap_provision: `mise ls --missing` reads
  # ~/.config/mise/config.toml, which blib_link_core only seeds in the wire phase. Called
  # from provision, a fresh box had no config yet, saw nothing missing, and silently
  # installed nothing. Provisioning, so skipped on --links-only and --dry-run like it.
  if [[ ${BLIB_LINKS_ONLY:-0} == 0 ]] && ! _blib_dry; then _alpine_mise_runtimes; fi
}

# Runs after the wire phase. The per-run build dir (see "cargo builds go to DISK") goes
# away here, and TMPDIR is restored.
# shellcheck disable=SC2329
bootstrap_closing() {
  _boot_tmp_cleanup
  return 0
}

blib_main "$@"
