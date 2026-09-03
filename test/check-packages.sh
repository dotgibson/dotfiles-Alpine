#!/usr/bin/env bash
# test/check-packages.sh
# ──────────────────────────────────────────────────────────────────────────────
# Does every package name in install/packages.txt still RESOLVE on this Alpine
# branch — WITHOUT installing anything?
#
# bootstrap.sh's apk_install is deliberately forgiving: a bulk `apk add` that fails
# retries package-by-package and prints "skipped (unavailable on this box?)" for each
# casualty (bootstrap.sh:144). That resilience is right for a live box — one dead name
# should not sink the whole install — but it means a typo, a rename, or a package that
# moved out of `community` is easy to miss: the run is noisy, never fatal, and reads as
# success. This turns that drift into a gate. It installs NOTHING.
#
# RESOLUTION, via `apk add --simulate`, NOT `apk search` or `apk policy`:
#   • `apk policy <unknown>` exits 0 and prints an empty policy — useless as a gate.
#   • `apk search -e -x <name>` matches on the index's NAME field only, so it misses
#     single-provider virtuals and `provides=` names (e.g. openssh-client-default,
#     yq-go) that `apk add` resolves perfectly happily — a false "missing".
#   • `apk add --simulate` runs apk's REAL resolver without touching the system, so it
#     agrees with what `apk add` would actually do: real packages and single-provider
#     virtuals resolve, unknown names error. It is the Alpine analogue of Debian's
#     `apt-get install -s`.
#
# There is deliberately NO version-floor check here (unlike the Debian sibling). Alpine
# carries no `# min:X.Y.Z` floors in install/packages.txt: the one floor that matters,
# tree-sitter-cli's, lives in bootstrap.sh as TREESITTER_FLOOR and is enforced there by
# a version guard, precisely because apk resolves the name on every branch but only
# clears the floor on some (see install/packages.txt). Resolution is the whole check.
#
# RUN IT WHERE THE ANSWER IS TRUE. Availability is a property of the apk repositories on
# the box, so v3.21 and edge disagree by design (gron, yazi and friends landed in
# `community` on different branches — see install/packages.txt). Locally this is a smoke
# test against whatever branch you track; the authoritative run is on a pinned Alpine.
#
# Exit codes:
#   0  every name resolves (or a clean skip: no apk on this host)
#   1  usage/environment failure
#   2  one or more names did NOT resolve — the drift signal
#
# Usage:
#   test/check-packages.sh                      # install/packages.txt
#   test/check-packages.sh install/packages.txt
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# `set -e` is deliberately off here (the exit code IS the result), so guard the cd
# explicitly — continuing in the wrong directory would read the wrong manifest.
cd -- "$REPO_ROOT" || exit 1

if [[ -r core/lib/ux.sh ]]; then
  # shellcheck source=core/lib/ux.sh
  source core/lib/ux.sh
fi
say() { printf '%s::%s %s\n' "${UX_BLU:-}" "${UX_RST:-}" "$*"; }
ok() { printf '%s%s%s %s\n' "${UX_GRN:-}" "${UX_OK:-+}" "${UX_RST:-}" "$*"; }
bad() { printf '%s%s%s %s\n' "${UX_YEL:-}" "${UX_WARN:-!}" "${UX_RST:-}" "$*" >&2; }

command -v apk >/dev/null 2>&1 || {
  say "no apk on this host — skipping (run this on Alpine, or in CI)."
  exit 0
}

manifest="${1:-install/packages.txt}"
[[ -f "$manifest" ]] || { bad "manifest not found: $manifest"; exit 1; }

# Reuse Core's parser rather than re-implementing the comment/whitespace rules: it is
# the SAME function bootstrap.sh feeds apk, so this checks exactly the names that would
# really be installed, including inline-comment stripping.
if [[ -r core/lib/bootstrap-lib.sh ]]; then
  # shellcheck source=core/lib/bootstrap-lib.sh
  source core/lib/bootstrap-lib.sh
else
  bad "core/lib/bootstrap-lib.sh not found — is the core/ subtree vendored?"
  exit 1
fi

# Name the branch so a local run's answer is interpretable.
branch="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | head -1 | tr -d "\"'")"
say "Alpine branch in view: ${branch:-unknown}"

mapfile -t pkgs < <(blib_read_pkgs "$manifest")
((${#pkgs[@]})) || { bad "$manifest parsed to zero package names"; exit 1; }
say "$manifest — ${#pkgs[@]} names"

# apk resolves against the cached index; a box that never ran `apk update` has none.
if [[ -z "$(ls -A /var/cache/apk 2>/dev/null)" && ! -s /lib/apk/db/installed ]]; then
  say "apk index looks empty — running apk update first"
  apk update >/dev/null 2>&1 || bad "apk update failed; results may be wrong"
fi

# --simulate touches nothing, so it needs no root; but it still reads apk's lock, which
# a bare non-root shell cannot on some setups. In CI apk runs as root; locally, fall
# through the doas/su that bootstrap.sh already assumes for apk.
sim() { apk add --simulate --quiet "$@" 2>&1; }

# ── resolution ────────────────────────────────────────────────────────────────
# Bulk first, then per-name — the same bulk-then-retry shape as bootstrap.sh's
# apk_install, and for the same reason. The bulk pass proves something no per-name
# probe can: that the whole set is CO-INSTALLABLE (no two names conflict).
missing=()
if sim "${pkgs[@]}" >/dev/null 2>&1; then
  ok "all ${#pkgs[@]} names resolve, and the set is co-installable."
else
  bad "the bulk resolve failed — narrowing down per package"
  for p in "${pkgs[@]}"; do
    # Capture output and status in separate statements: `out=$(...)` does set $? to the
    # command's status, but that is easy to break with any later edit that inserts a
    # statement between the two. Test the call directly instead.
    if out="$(sim "$p")"; then continue; fi
    case "$out" in
    *"no such package"*)            missing+=("$p — absent from ${branch:-this branch}") ;;
    *"unable to select packages"*)  missing+=("$p — unsatisfiable (conflict or missing dependency)") ;;
    *)                              missing+=("$p — $(printf '%s' "$out" | grep -iE 'ERROR' | head -1)") ;;
    esac
  done
fi

echo
if ((${#missing[@]})); then
  bad "${#missing[@]} package name(s) did NOT resolve against ${branch:-this branch}:"
  printf '    %s\n' "${missing[@]}" >&2
  cat >&2 <<'EOF'

A non-resolving name is one of:
  • a rename    — find the new name and update install/packages.txt
  • a drop      — remove it, or build it from source in bootstrap.sh (as duf/glow are)
  • a typo      — fix it
  • branch drift — real in `community` on one branch, absent on another (gron, yazi, …)

apk_install (bootstrap.sh) skips an unresolvable name per-package rather than aborting,
so a box still provisions — but the tool it names silently never arrives. Fix the list.
EOF
  exit 2
fi

ok "all ${#pkgs[@]} names resolve on ${branch:-this branch}."
exit 0
