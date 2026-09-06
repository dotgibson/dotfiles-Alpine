#!/usr/bin/env bash
# test/check-packages.sh
# ──────────────────────────────────────────────────────────────────────────────
# Does every package name in install/packages.txt still RESOLVE on this Alpine
# branch — WITHOUT installing anything?
#
# bootstrap.sh's apk_install() is deliberately forgiving: a bulk `apk add` that fails
# retries package-by-package and prints "skipped (unavailable on this box?)" for each
# casualty. That resilience is right for a live box — one dead name
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
# VERSION FLOORS ARE CHECKED, per branch. A name resolving is not the whole story for a
# floored entry: apk resolves `neovim` and `tree-sitter-cli` on all five branches and
# clears their `# min:` floors on only two. Those are different facts and this gate
# reports both.
#
# It did not always. The floors used to be enforced nowhere, on a stated rationale worth
# recording because it was correct at the time: this gate ran against whatever branch the
# box tracked, and CI pinned exactly one — alpine:3.24, the newest supported branch, where
# every floor is already met. A floor check there would have gone green while v3.21,
# v3.22 and v3.23 boxes stayed broken. That is the blind spot Core's PORTING-MATRIX
# footnote 33 names: a check sampling only the newest lane reports every lane healthy.
# Green would have meant less than silence.
#
# The fix was not to weaken the check but to stop sampling one lane —
# .github/workflows/packages.yml now runs this across v3.21…edge. Three tiers, because a
# gate that cannot distinguish them is the useless kind:
#
#   • an unexpected name absence          → FAIL (exit 2). Real drift.
#   • a floor unmet on EDGE               → FAIL (exit 3). Unsatisfiable fleet-wide:
#                                           Core's pin outran the ecosystem.
#   • a floor unmet on a STABLE branch    → REPORT. Known, documented, and unfixable by
#                                           apk on that branch; bootstrap.sh warns on the
#                                           box itself. Failing would be permanent red
#                                           that no one can act on.
#
# The manifest carries the per-branch expectations that make this possible:
#
#   <name>  # since:vX.YY   — absent before branch X.YY BY RECORD, so absence at or below
#                             it is not drift. Probed anyway: a name arriving early is
#                             news (a backport) and is reported so the annotation is
#                             corrected while it is cheap.
#   <name>  # min:X.Y.Z     — a version floor. Its authoritative value lives in
#                             bootstrap.sh; this script asserts the two agree, so the
#                             restatement cannot silently drift.
#
# RUN IT WHERE THE ANSWER IS TRUE. Availability is a property of the apk repositories on
# the box, so v3.21 and edge disagree by design (gron, yazi and friends landed in
# `community` on different branches — see install/packages.txt). Locally this is a smoke
# test against whatever branch you track; the authoritative run is on a pinned Alpine.
#
# Exit codes:
#   0  every expected name resolves and every declared floor is met (or clean skip: no apk)
#   1  usage/environment failure, or a floor that disagrees with bootstrap.sh
#   2  one or more names did NOT resolve — the drift signal
#   3  a declared floor is unmet on edge — unsatisfiable fleet-wide
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

# ── which branch are we on? ───────────────────────────────────────────────────
# Two questions, not one: the human-readable label, and a COMPARABLE key for the
# `# since:` / `# min:` expectations below.
#
# edge must be detected from /etc/apk/repositories, not from VERSION_ID. An edge box
# reports the NEXT release it is heading toward (e.g. 3.25.0_alpha…), so parsing the
# version alone silently classifies edge as some future stable branch and every
# expectation keyed to it reads wrong.
branch="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | head -1 | tr -d "\"'")"
if grep -qE '/edge/' /etc/apk/repositories 2>/dev/null; then
  branch_key="edge"; branch_label="edge (${branch:-?})"
else
  # v3.24.1 → 3.24. Two components: expectations are per BRANCH, not per point release.
  branch_key="$(printf '%s' "${branch:-}" | awk -F. 'NF>=2 { print $1 "." $2 }')"
  branch_label="v${branch_key:-?} (${branch:-unknown})"
fi
say "Alpine branch in view: $branch_label"

# _branch_lt <a> <b> — true when branch a is OLDER than b. Both are "3.21"-style keys or
# the literal "edge", which sorts above every numbered branch. Field-wise integer
# compare, not string: "3.9" must not outrank "3.21".
_branch_lt() { # <a> <b>
  local a="${1#v}" b="${2#v}"
  [[ "$a" == "$b" ]] && return 1
  [[ "$a" == "edge" ]] && return 1   # edge is never older than anything
  [[ "$b" == "edge" ]] && return 0   # anything numbered is older than edge
  local am="${a%%.*}" bm="${b%%.*}" an="${a#*.}" bn="${b#*.}"
  ((10#${am:-0} < 10#${bm:-0})) && return 0
  ((10#${am:-0} > 10#${bm:-0})) && return 1
  ((10#${an:-0} < 10#${bn:-0}))
}

# _ver_lt <a> <b> — version compare for `# min:` floors, field-wise so 0.26.10 does not
# rank below 0.26.9. Deliberately the same shape as bootstrap.sh's _dotfiles_ver_lt; a
# pre-release/`-rN` suffix is truncated at the first '-' rather than parsed.
_ver_lt() { # <a> <b>
  local i x y; local -a A B; local IFS=.
  # shellcheck disable=SC2206  # deliberate word-splitting on IFS=. — that IS the parse
  A=(${1%%-*})
  # shellcheck disable=SC2206
  B=(${2%%-*})
  unset IFS
  for ((i = 0; i < 4; i++)); do
    x="${A[i]:-0}"; y="${B[i]:-0}"
    [[ "$x" =~ ^[0-9]+$ ]] || x=0
    [[ "$y" =~ ^[0-9]+$ ]] || y=0
    ((10#$x < 10#$y)) && return 0
    ((10#$x > 10#$y)) && return 1
  done
  return 1 # equal is NOT below a >= floor
}

# ── the manifest's per-branch expectations ────────────────────────────────────
# blib_read_pkgs gives the NAMES apk would really be fed; it strips comments, which is
# right for it and useless here. This second pass reads the annotations those comments
# carry, so the two views cannot disagree about which names exist:
#
#   <name>  # since:vX.YY   — not in the repos before branch X.YY. Absence at or below
#                             that branch is EXPECTED, not drift.
#   <name>  # min:X.Y.Z     — nvim-treesitter-style version floor. The name resolving is
#                             not enough; the version has to clear the floor.
declare -A PKG_SINCE=() PKG_MIN=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  name="${line%%#*}"; name="${name//[[:space:]]/}"
  [[ -n "$name" ]] || continue
  cmt="${line#*#}"
  [[ "$cmt" == "$line" ]] && continue          # no inline comment on this line
  [[ "$cmt" =~ since:(v?[0-9]+\.[0-9]+|edge) ]] && PKG_SINCE["$name"]="${BASH_REMATCH[1]#v}"
  [[ "$cmt" =~ min:([0-9][0-9.]*) ]] && PKG_MIN["$name"]="${BASH_REMATCH[1]}"
done <"$manifest"

mapfile -t all_pkgs < <(blib_read_pkgs "$manifest")
((${#all_pkgs[@]})) || { bad "$manifest parsed to zero package names"; exit 1; }
say "$manifest — ${#all_pkgs[@]} names"

# Split by branch expectation. A name annotated `# since:vX.YY` is NOT required to
# resolve on an older branch — that is the manifest describing reality, not drift, and
# failing on it would make this gate permanently red on v3.21 for yazi and gron. They
# are still PROBED below, because a name appearing EARLIER than recorded is real news
# (a backport, or a promotion out of `testing`) and the annotation should then be
# corrected. News is reported; it is not a failure.
pkgs=(); deferred=()
for p in "${all_pkgs[@]}"; do
  since="${PKG_SINCE[$p]:-}"
  if [[ -n "$since" ]] && _branch_lt "${branch_key:-0.0}" "$since"; then
    deferred+=("$p")
  else
    pkgs+=("$p")
  fi
done
if ((${#deferred[@]})); then
  say "${#deferred[@]} name(s) not expected on this branch (checked separately): ${deferred[*]}"
fi
((${#pkgs[@]})) || { bad "every name is deferred on this branch — the manifest cannot be right"; exit 1; }

# ── the floors must agree with bootstrap.sh ───────────────────────────────────
# A `# min:` here restates a constant whose authoritative value lives in bootstrap.sh, so
# the copy can drift the moment someone bumps one and not the other — and a stale floor
# is worse than no floor, because it reads as verified. Assert the two agree, in the same
# spirit as check-root-probe.sh: a duplicated fact is only safe if something checks it.
declare -A FLOOR_SOURCE=([tree-sitter-cli]=TREESITTER_FLOOR [neovim]=NEOVIM_FLOOR)
for p in "${!FLOOR_SOURCE[@]}"; do
  var="${FLOOR_SOURCE[$p]}"
  want="$(sed -n "s/^${var}=\"\([^\"]*\)\".*/\1/p" bootstrap.sh | head -1)"
  have="${PKG_MIN[$p]:-}"
  [[ -n "$want" ]] || { bad "bootstrap.sh no longer defines $var — this gate's floor for $p is unanchored"; exit 1; }
  [[ -n "$have" ]] || { bad "install/packages.txt dropped the '# min:' on $p, but bootstrap.sh still sets $var=$want"; exit 1; }
  [[ "$have" == "$want" ]] || {
    bad "floor disagreement on $p: install/packages.txt says min:$have, bootstrap.sh says $var=$want"
    bad "One of the two was bumped without the other. They must match."
    exit 1
  }
done

# apk resolves against the cached index; a box that never ran `apk update` has none.
if [[ -z "$(ls -A /var/cache/apk 2>/dev/null)" && ! -s /lib/apk/db/installed ]]; then
  say "apk index looks empty — running apk update first"
  apk update >/dev/null 2>&1 || bad "apk update failed; results may be wrong"
fi

# Privilege: mirror bootstrap.sh's selection — root uses nothing, else doas (Alpine's
# default), else sudo. But --simulate WRITES nothing and on a normal box apk's db is
# world-readable, so the unprivileged call is the fast common path (it is why this gate
# runs green as a plain user). We escalate through $SU only when apk cannot OPEN its own
# lock/db — never gratuitously, which would make the gate prompt for a doas password it
# does not need.
if [[ "$(id -u)" -eq 0 ]]; then SU=""
elif command -v doas >/dev/null 2>&1; then SU="doas"
elif command -v sudo >/dev/null 2>&1; then SU="sudo"
else SU=""; fi

# A lock/permission error is apk failing to read its OWN database — an environment
# problem (unprivileged with no working escalator, a held lock), NOT a bad package name.
# Misreporting it as drift (exit 2) is exactly the false failure this must avoid.
env_failure() { printf '%s' "$1" | grep -qiE 'permission denied|unable to lock|failed to open apk database|could not (open|read)'; }

# apk's real resolver, run without root first; on a lock/permission error, retry once
# under $SU (if any). Prints the final combined output and returns apk's status.
sim() {
  local out rc
  out="$(apk add --simulate --quiet "$@" 2>&1)"; rc=$?
  if ((rc != 0)) && [[ -n "$SU" ]] && env_failure "$out"; then
    out="$($SU apk add --simulate --quiet "$@" 2>&1)"; rc=$?
  fi
  printf '%s' "$out"
  return "$rc"
}

# Turn a lock/permission failure into a clean env exit (1), the way a missing manifest
# or empty parse already does — distinct from the drift exit (2) below.
bail_env() {
  bad "apk could not open its database (lock/permission), even under '${SU:-root}' — this"
  bad "is an ENVIRONMENT failure, not package drift. Run as root, or configure doas/sudo:"
  printf '%s\n' "$1" | grep -iE 'ERROR|denied' | head -3 | sed 's/^/    /' >&2
  exit 1
}

# ── resolution ────────────────────────────────────────────────────────────────
# Bulk first, then per-name — the same bulk-then-retry shape as bootstrap.sh's
# apk_install, and for the same reason. The bulk pass proves something no per-name
# probe can: that the whole set is CO-INSTALLABLE (no two names conflict).
missing=() news=() met=() below=()
# Capture output and status in separate statements: `out=$(...)` does set $? to the
# command's status, but that is easy to break with any later edit that inserts a
# statement between the two. Assign, then read $? on its own line.
bulk_out="$(sim "${pkgs[@]}")"; bulk_rc=$?
if ((bulk_rc == 0)); then
  ok "all ${#pkgs[@]} names resolve, and the set is co-installable."
elif env_failure "$bulk_out"; then
  bail_env "$bulk_out"
else
  bad "the bulk resolve failed — narrowing down per package"
  for p in "${pkgs[@]}"; do
    out="$(sim "$p")" && continue
    env_failure "$out" && bail_env "$out"
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

ok "all ${#pkgs[@]} names resolve on $branch_label."

# ── deferred names: did any land EARLY? ───────────────────────────────────────
# Not a failure in either direction. Absent is what the annotation predicted; present
# means the package moved and the annotation is now stale, which someone should fix
# while it is cheap.
for p in "${deferred[@]}"; do
  if sim "$p" >/dev/null 2>&1; then
    news+=("$p resolves on $branch_label, but is annotated 'since:v${PKG_SINCE[$p]}' — the annotation is stale")
  fi
done

# ── declared version floors ───────────────────────────────────────────────────
# Resolution is not the whole story for a floored name: apk resolves tree-sitter-cli and
# neovim on every branch and clears their floors on only two. This is the check that
# distinguishes those two facts, per branch, which is the entire reason this gate runs
# as a matrix instead of once on the newest image.
#
# `apk search -x -e` is right HERE and wrong for resolution: it matches the index's NAME
# field only, so it misses provides-names (the reason the resolution pass above uses
# --simulate) — but floored names are real packages, and it is the only probe that
# reports a VERSION rather than a yes/no.
pkg_version() { # <name> → prints upstream version, or nothing
  local out; out="$(apk search -x -e "$1" 2>/dev/null | head -1)" || return 1
  [[ -n "$out" ]] || return 1
  out="${out#"$1"-}"      # neovim-0.12.2-r0 → 0.12.2-r0
  printf '%s' "${out%-r*}" # → 0.12.2
}

floor_fail=()
for p in "${!PKG_MIN[@]}"; do
  floor="${PKG_MIN[$p]}"
  # A deferred name has no version to read on this branch; its absence is already
  # accounted for above.
  [[ " ${deferred[*]} " == *" $p "* ]] && continue
  have="$(pkg_version "$p")" || {
    floor_fail+=("$p — declares min:$floor but no version could be read from the index")
    continue
  }
  if _ver_lt "$have" "$floor"; then
    if [[ "$branch_key" == "edge" ]]; then
      # edge is where a fix must exist. Below the floor HERE means the requirement is
      # unsatisfiable anywhere in the fleet — Core's pin outran the ecosystem, or the
      # package regressed. That is a real failure, not a known-old branch.
      floor_fail+=("$p $have is BELOW its min:$floor on edge — unsatisfiable fleet-wide")
    else
      below+=("$p $have < min:$floor")
    fi
  else
    met+=("$p $have >= min:$floor")
  fi
done

((${#met[@]})) && { echo; say "floors met on $branch_label:"; printf '    %s\n' "${met[@]}"; }
if ((${#below[@]})); then
  echo
  say "below floor on $branch_label — expected on older branches, and NOT a failure here:"
  printf '    %s\n' "${below[@]}"
  say "bootstrap.sh warns on such a box (NEOVIM_FLOOR / TREESITTER_FLOOR); there is no"
  say "apk fix on this branch, so red CI would be permanent and would mean nothing."
fi

if ((${#news[@]})); then
  echo
  bad "${#news[@]} stale annotation(s) — availability improved, install/packages.txt did not:"
  printf '    %s\n' "${news[@]}" >&2
  bad "Not fatal. Update the 'since:' annotation (and promote the package if it is now"
  bad "available on every supported branch)."
fi

if ((${#floor_fail[@]})); then
  echo
  bad "${#floor_fail[@]} floor failure(s) on $branch_label:"
  printf '    %s\n' "${floor_fail[@]}" >&2
  exit 3
fi

exit 0
