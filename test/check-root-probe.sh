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
# BEHAVIOURAL, NOT TEXTUAL. The condition is EXTRACTED from the code that decides —
# whatever currently guards the `BLIB_SU=""` root arm — and then evaluated with `id`
# stubbed to produce nothing. Asserting on the shipped TEXT would pass the moment someone
# reworded the fix; asserting on its ANSWER tracks what the script will actually do. The
# historical form is evaluated alongside, and must answer WRONGLY: a regression test that
# cannot distinguish the bug from the fix proves nothing, and this one would otherwise
# pass on both.
#
# WHERE THE DECISION LIVES NOW. bootstrap.sh no longer probes for root itself: it calls
# Core's blib_resolve_su (`--prefer doas`, dotgibson/dotfiles-core#973), and the root arm
# is in the VENDORED core/lib/bootstrap-lib.sh. So the condition is extracted from there —
# a Core sync that changed the rule would change what this gate evaluates, which is the
# point — and a second assertion pins that bootstrap.sh actually delegates to it, so a
# local probe cannot quietly come back beside the lib's.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT="$HERE/bootstrap.sh"
BLIB="$HERE/core/lib/bootstrap-lib.sh"
rc=0
ok()   { printf '   ok   %s\n' "$1"; }
bad()  { printf '   FAIL %s\n' "$1"; rc=1; }
note() { printf '   --   %s\n' "$1"; }

[ -f "$BOOT" ] || { printf '!! no bootstrap.sh at %s\n' "$BOOT"; exit 2; }
[ -f "$BLIB" ] || { printf '!! no vendored bootstrap-lib at %s\n' "$BLIB"; exit 2; }

# bootstrap.sh must DELEGATE, doas-first. Comment-stripped, so the paragraph explaining
# the choice cannot satisfy it; the call has to be there.
if grep -vE '^[ \t]*#' "$BOOT" | grep -qE 'blib_resolve_su[ \t]+--prefer[ \t]+doas'; then
  ok "bootstrap.sh resolves the escalator with blib_resolve_su --prefer doas"
else
  bad "bootstrap.sh does not call \`blib_resolve_su --prefer doas\` — the root decision has moved back into this file, or lost its doas-first order"
fi

# The condition guarding the lib's root arm — inside blib_resolve_su, the `if` that leads
# to its first `BLIB_SU=""` — taken from the file rather than restated here.
cond="$(awk '
  /^blib_resolve_su\(\)/ { infn = 1 }
  infn && /^}/ { exit }
  infn && /^[ \t]*if .*then$/ { last = $0 }
  infn && /^[ \t]*BLIB_SU=""$/ && last != "" {
    sub(/^[ \t]*if[ \t]+/, "", last); sub(/;[ \t]*then$/, "", last); print last; exit
  }' "$BLIB")"

if [ -z "$cond" ]; then
  printf '!! could not find the root arm in core/lib/bootstrap-lib.sh — blib_resolve_su was\n'
  printf '   restructured and this gate now checks nothing. Re-point it.\n'
  exit 2
fi
note "root condition under test: $cond"

# `id` stubbed to print nothing: the exact shape of a box with no id on PATH. The lib
# reads $EUID into a local `uid` first; give the extracted condition the same binding.
# shellcheck disable=SC2329,SC2034  # called below; `id` and `uid` are reached via eval, not directly
_answer() { ( id() { :; }; uid="$EUID"; eval "if $1; then printf 'root'; else printf 'notroot'; fi" ); }

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

# The belt to that braces: no arithmetic root test anywhere in bootstrap.sh OR the lib. A
# second copy of the shape, added later beside the fixed one, is exactly how this recurs.
#
# COMMENTS ARE STRIPPED FIRST, and that is not politeness — the first run of this gate
# failed on bootstrap.sh's own explanation of the fix, which quotes the broken form twice
# on purpose. A guard that reds the paragraph documenting it is a guard someone deletes.
_arith_re='\[\[[^]]*\$\((id[ \t]+-u|/usr/bin/id[ \t]+-u)\)[^]]*-eq'
for _f in "$BOOT" "$BLIB"; do
  _arith_hits="$(grep -vE '^[ \t]*#' "$_f" | grep -nE "$_arith_re" || true)"
  if [ -n "$_arith_hits" ]; then
    bad "an arithmetic \`id -u\` root test is back in ${_f#"$HERE"/} (comment-stripped line numbers):"
    printf '%s\n' "$_arith_hits" | sed 's/^/        /'
  else
    ok "no arithmetic \`id -u\` root test remains in ${_f#"$HERE"/}"
  fi
done

exit "$rc"
