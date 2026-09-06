#!/usr/bin/env bash
# test/check-root-probe.sh
# ──────────────────────────────────────────────────────────────────────────────
# Does bootstrap.sh's "are we root?" test still answer correctly when `id` is not
# reachable?
#
# THE BUG THIS EXISTS FOR (dotgibson/dotfiles-core#867). The probe used to be:
#
#     if [[ "$(id -u)" -eq 0 ]]; then SU=""
#
# `-eq` is an ARITHMETIC comparison, and bash evaluates an EMPTY string as 0. So on a
# box where `id` is missing or off PATH — a stripped container, a broken PATH, an
# early-boot shell — the command substitution yields "" and the test concludes WE ARE
# ROOT. SU is set empty, and every `doas apk add` in the rest of the run executes as the
# invoking user: the provision fails, or half-succeeds, with no message pointing at the
# cause. The failure is silent in the worst way — the script says nothing is wrong.
#
# The fix is `[[ "$EUID" == "0" ]]`: $EUID is a bash BUILTIN, so it needs no PATH lookup,
# no fork, and cannot be shadowed by a function or an alias; the STRING compare is what
# stops an empty value reading as zero.
#
# WHY A TEST AND NOT A COMMENT. This is a one-character class of mistake (`-eq` vs `==`)
# in a line nobody re-reads, and no linter sees it: the broken form is valid bash,
# `bash -n` passes it, and ShellCheck has nothing to say. It also cannot be caught by
# running the bootstrap normally, because on any box that HAS `id` both forms agree. The
# only way it surfaces is on the box least able to report it.
#
# BEHAVIOURAL, NOT TEXTUAL. The condition is EXTRACTED from bootstrap.sh — whatever
# currently guards the `SU=""` root arm — and then evaluated with `id` stubbed to produce
# nothing. Asserting on the shipped TEXT would pass the moment someone reworded the fix;
# asserting on its ANSWER tracks what the script will actually do. The historical form is
# evaluated alongside, and must answer WRONGLY: a regression test that cannot distinguish
# the bug from the fix proves nothing, and this one would otherwise pass on both.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT="$HERE/bootstrap.sh"
rc=0
ok()   { printf '   ok   %s\n' "$1"; }
bad()  { printf '   FAIL %s\n' "$1"; rc=1; }
note() { printf '   --   %s\n' "$1"; }

[ -f "$BOOT" ] || { printf '!! no bootstrap.sh at %s\n' "$BOOT"; exit 2; }

# The condition guarding the root arm, taken from the file rather than restated here.
cond="$(awk '
  /^if .*then$/ { last = $0 }
  /^[ \t]*SU=""$/ && last != "" {
    sub(/^if[ \t]+/, "", last); sub(/;[ \t]*then$/, "", last); print last; exit
  }' "$BOOT")"

if [ -z "$cond" ]; then
  printf '!! could not find the root arm in bootstrap.sh — the privilege block was\n'
  printf '   restructured and this gate now checks nothing. Re-point it.\n'
  exit 2
fi
note "root condition under test: $cond"

# `id` stubbed to print nothing: the exact shape of a box with no id on PATH.
# shellcheck disable=SC2329  # called below; the stub `id` is reached via eval, not directly
_answer() { ( id() { :; }; eval "if $1; then printf 'root'; else printf 'notroot'; fi" ); }

shipped="$(_answer "$cond")"
# shellcheck disable=SC2016  # single quotes are the POINT: eval expands this, not this line
historic="$(_answer '[[ "$(id -u)" -eq 0 ]]')"

if [ "$EUID" -eq 0 ]; then
  # Running as real root. The interesting assertion here is the MINIMAL-ROOT contract:
  # a root shell with no `id` must still be recognised as root, or the bootstrap would
  # try to escalate as root and demand a tool it does not need.
  if [ "$shipped" = root ]; then
    ok "as real root with no \`id\`, the probe still says root (minimal-root contract)"
  else
    bad "as real root with no \`id\`, the probe said '$shipped' — a root box would try to escalate"
  fi
  note "the non-root arm needs an unprivileged user; skipped on this run"
else
  if [ "$shipped" = notroot ]; then
    ok "with no \`id\` on PATH, an unprivileged run is NOT mistaken for root"
  else
    bad "with no \`id\` on PATH the probe said '$shipped' — the whole provision would run unescalated (dotfiles-core#867)"
  fi
  # Non-vacuity: the historical form must get this wrong, here, now.
  if [ "$historic" = root ]; then
    ok "the historical \`-eq\` form is still demonstrably wrong (this gate is not vacuous)"
  else
    bad "the historical \`-eq\` form no longer misbehaves — this gate can no longer tell the bug from the fix; re-derive it"
  fi
fi

# The belt to that braces: no arithmetic root test anywhere else in the file. A second
# copy of the shape, added later beside the fixed one, is exactly how this recurs.
#
# COMMENTS ARE STRIPPED FIRST, and that is not politeness — the first run of this gate
# failed on bootstrap.sh's own explanation of the fix, which quotes the broken form twice
# on purpose. A guard that reds the paragraph documenting it is a guard someone deletes.
_arith_re='\[\[[^]]*\$\((id[ \t]+-u|/usr/bin/id[ \t]+-u)\)[^]]*-eq'
_arith_hits="$(grep -vE '^[ \t]*#' "$BOOT" | grep -nE "$_arith_re" || true)"
if [ -n "$_arith_hits" ]; then
  bad "an arithmetic \`id -u\` root test is back in bootstrap.sh (comment-stripped line numbers):"
  printf '%s\n' "$_arith_hits" | sed 's/^/        /'
else
  ok "no arithmetic \`id -u\` root test remains in bootstrap.sh"
fi

exit "$rc"
