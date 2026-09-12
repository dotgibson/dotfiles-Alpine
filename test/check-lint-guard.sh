#!/usr/bin/env bash
# test/check-lint-guard.sh
# ──────────────────────────────────────────────────────────────────────────────
# Do the Makefile's lint targets FAIL when git cannot enumerate the repo, instead of
# reporting a pass over zero files?
#
# THE BUG THIS EXISTS FOR. The file lists are computed at parse time:
#
#     SH_FILES  := $(shell git ls-files '*.sh' ':!:core/**')
#
# `$(shell ...)` discards exit status. So "git refused" and "this repo has no *.sh" both
# arrive as the empty string, and the targets read empty as nothing-to-do and exit 0:
#
#     $ make shell SH_FILES=
#     - no repo-owned *.sh
#     $ echo $?
#     0
#
# A CI status check gated on that is GREEN while linting NOTHING. The trigger is not
# hypothetical: inside a GitHub Actions container the checkout is owned by a different
# uid, git declines with "detected dubious ownership", and every containerized `make`
# tripped it three times — once per list. It was visible in the packages workflow logs
# from the day that workflow landed.
#
# WHY A TEST AND NOT A COMMENT. The failure mode is a PASS. Nothing about a green run
# distinguishes "checked 3 files, all clean" from "checked 0 files"; the exit status is
# identical and the only tell is one easily-missed line of output. No linter finds this,
# because the Makefile is not wrong in any way a parser can see — it is wrong about what
# an empty string MEANS.
#
# BEHAVIOURAL, NOT TEXTUAL. This runs the real targets through `make` with `git` stubbed,
# rather than asserting on the Makefile's text, so a reworded guard still tracks. Both
# halves of the disambiguation are asserted, because a guard that only fails is as broken
# as one that only passes:
#
#     git ERRORS          → must FAIL   (the bug)
#     git ok, list empty  → must SKIP 0 (a repo that genuinely has no such files)
#
# NON-VACUOUS BY CONSTRUCTION. The old behaviour is exercised alongside via `make <t>
# SH_FILES=`, which forces the empty list WITHOUT breaking git — the exact state the
# targets used to accept — and it must still exit 0. If that ever starts failing, this
# gate is no longer distinguishing the bug from the fix and is asserting nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 2
rc=0
ok()   { printf '   ok   %s\n' "$1"; }
bad()  { printf '   FAIL %s\n' "$1"; rc=1; }
note() { printf '   --   %s\n' "$1"; }

command -v make >/dev/null 2>&1 || { note "no make on PATH — SKIP"; exit 0; }
[ -f Makefile ] || { printf '!! no Makefile at %s\n' "$HERE"; exit 2; }

# The targets under test: every one whose work is driven by a git-derived file list.
# Derived from the Makefile rather than hardcoded, so a new list-driven target that
# forgets the guard is caught here instead of shipping unguarded.
mapfile -t TARGETS < <(awk '
  /^[a-z-]+:/ { t = $0; sub(/:.*/, "", t) }
  /GIT_GUARD/ && t != "" { print t; t = "" }
' Makefile | sort -u)

if ((${#TARGETS[@]} == 0)); then
  printf '!! no target in the Makefile references GIT_GUARD — either the guard was\n'
  printf '   removed or it was renamed, and this gate now checks nothing. Re-point it.\n'
  exit 2
fi
note "guarded targets under test: ${TARGETS[*]}"

STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT

# A git that FAILS the way a container's does: non-zero, no output.
printf '#!/bin/sh\nexit 128\n' >"$STUB/git"
chmod +x "$STUB/git"

for t in "${TARGETS[@]}"; do
  if PATH="$STUB:$PATH" make "$t" >/dev/null 2>&1; then
    bad "\`make $t\` reported success with git broken — it linted ZERO files and said nothing"
  else
    ok "\`make $t\` FAILS when git cannot list the repo"
  fi
done

# A git that SUCCEEDS but lists nothing: a real repo that genuinely has no such files.
# This must still be a clean skip, or the guard has made the Makefile unusable in a
# perfectly valid state.
printf '#!/bin/sh\nexit 0\n' >"$STUB/git"
for t in "${TARGETS[@]}"; do
  if PATH="$STUB:$PATH" make "$t" >/dev/null 2>&1; then
    ok "\`make $t\` still skips cleanly when git works and the list is genuinely empty"
  else
    bad "\`make $t\` failed on an empty-but-valid file list — the guard is too aggressive"
  fi
done

# The gate is only meaningful if the two states above are actually DIFFERENT. Force the
# empty list without breaking git — the precise condition the targets used to accept —
# and require the old, permissive answer. If this fails, both branches above are failing
# for the same reason and neither proves anything.
for t in "${TARGETS[@]}"; do
  case "$t" in
  shell) var=SH_FILES ;;
  zsh)   var=ZSH_FILES ;;
  md)    var=MD_FILES ;;
  *)     continue ;;
  esac
  if make "$t" "$var=" >/dev/null 2>&1; then
    ok "control: \`make $t $var=\` (git healthy) still exits 0 — the gate distinguishes the two"
  else
    bad "control: \`make $t $var=\` failed, so the two states are indistinguishable and this gate is vacuous"
  fi
done

exit "$rc"
