#!/usr/bin/env bash
# test/check-core-freshness.sh — is the vendored core/ subtree BEHIND upstream?
# ──────────────────────────────────────────────────────────────────────────────
# The vendored core/ here is a git-subtree copy of dotfiles-core. Nothing on THIS
# side tracked whether that copy had fallen behind upstream — so a security/bugfix
# landing in Core could sit un-pulled here indefinitely. This is the consumer-side
# freshness watcher: it asks whether the vendored commit is now BEHIND upstream's
# tip, i.e. there are Core updates this repo hasn't pulled. A behind result is the
# NUDGE to run a `git subtree pull`, not a hard error in normal development — so it
# lives in a SCHEDULED workflow, exiting non-zero only there to surface the drift.
#
# Best-effort + graceful (offline/restricted → skip, exit 0). Override the upstream
# and the branch with CORE_UPSTREAM / CORE_BRANCH.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

# Palette from the VENDORED shared bash UX lib (core/lib/ux.sh) — ONE colour rule instead
# of a hand-rolled TTY/NO_COLOR block that drifts. Guarded: this script SKIPs when core/ is
# absent, so fall back to no colour rather than fail to source it.
if [[ -r "$REPO/core/lib/ux.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO/core/lib/ux.sh"
  c_g=$UX_GRN c_y=$UX_YEL c_r=$UX_RED c_0=$UX_RST
else
  c_g='' c_y='' c_r='' c_0=''
fi
skip() {
  printf '%s–%s %s\n' "$c_y" "$c_0" "$*"
  exit 0
}

command -v git >/dev/null 2>&1 || skip "check-core-freshness: git unavailable"
# Prefer the O(1) offline provenance stamp (core.lock, written by dotfiles-core's
# sync-core.sh); fall back to the subtree-split marker (which needs full history) when it's
# absent. Either yields the commit the vendored core/ was last synced from.
SPLIT=""
if [[ -r core.lock ]]; then
  SPLIT="$(sed -n 's/^core_sha=//p' core.lock | head -n1)"
  # A present-but-malformed lock would make the TIP-vs-SPLIT compare below report a false
  # "behind" (e.g. a short SHA never equals the full tip). This is an automated freshness
  # signal, so fail CLEARLY on an invalid lock rather than emit a misleading verdict.
  if [[ ! "$SPLIT" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s✗%s check-core-freshness: core.lock has an invalid core_sha (%s) — expected a 40-char hex SHA\n' \
      "$c_r" "$c_0" "${SPLIT:-empty}" >&2
    exit 1
  fi
fi
[[ -n "$SPLIT" ]] || SPLIT="$(git log --grep='git-subtree-dir: core' -n1 --format='%b' 2>/dev/null |
  sed -n 's/^[[:space:]]*git-subtree-split:[[:space:]]*//p' | head -n1)"
[[ -n "$SPLIT" ]] || skip "check-core-freshness: no core.lock or git-subtree-split marker (not a subtree checkout?)"

UPSTREAM="${CORE_UPSTREAM:-https://github.com/Gerrrt/dotfiles-core}"
BRANCH="${CORE_BRANCH:-main}"

# The upstream tip we'd be pulling. ls-remote needs no clone and is the source of truth.
TIP="$(git ls-remote "$UPSTREAM" "$BRANCH" 2>/dev/null | awk 'NR==1{print $1}')"
[[ -n "$TIP" ]] || skip "check-core-freshness: cannot reach $UPSTREAM ($BRANCH) — offline/restricted?"

if [[ "$TIP" == "$SPLIT" ]]; then
  printf '%s✓%s vendored core/ is current with %s@%s (%s)\n' "$c_g" "$c_0" "$UPSTREAM" "$BRANCH" "${SPLIT:0:12}"
  exit 0
fi

# Behind (or diverged). Report the SHAs and how to update. Exit non-zero so a scheduled
# run surfaces it (the workflow turns this into a step-summary nudge). This repo has no
# Makefile, so the remediation is the raw subtree pull + a links-only bootstrap re-run.
printf '%s⚠%s vendored core/ is behind upstream %s@%s\n' "$c_y" "$c_0" "$UPSTREAM" "$BRANCH" >&2
printf '    vendored: %s\n    upstream: %s\n' "${SPLIT:0:12}" "${TIP:0:12}" >&2
printf '    update:   git subtree pull --prefix=core %s %s --squash, then ./bootstrap.sh --links-only\n' "$UPSTREAM" "$BRANCH" >&2
exit 1
