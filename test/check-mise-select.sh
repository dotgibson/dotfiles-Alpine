#!/usr/bin/env bash
# test/check-mise-select.sh
# ──────────────────────────────────────────────────────────────────────────────
# Does DOTFILES_MISE_INSTALL=1 still install only the LEAN mise runtime set?
#
# THE BUG THIS EXISTS FOR (dotfiles-Alpine#221). A full `mise install` of Core's [tools]
# lands at ~2.3 GiB under $HOME on this layer — zig, java, go, terraform, and rust even on
# rustup's minimal profile — and it filled an 8 GiB VM to 100%. bootstrap.sh now installs
# a lean set (ALPINE_MISE_LEAN: node pnpm python ruby lua) under DOTFILES_MISE_INSTALL=1
# and everything only under =all; the rest stays declared in Core's config and is listed
# as deferred, never hidden with disable_tools.
#
# WHY A TEST AND NOT A COMMENT. The selection is one small helper and one variable, and
# the regression is a one-token edit — feeding `$missing` to the install line instead of
# `$tools`, or a tool added to the lean list "just for now" — that bash -n and ShellCheck
# both accept. It cannot be caught by running bootstrap on a provisioned box either: with
# nothing missing the helper is never consulted. Only a fresh small VM would notice, and
# it would notice by filling up.
#
# BEHAVIOURAL, NOT TEXTUAL. The helper (_alpine_mise_select) and the list it reads
# (ALPINE_MISE_LEAN) are EXTRACTED from bootstrap.sh and evaluated here against a fixed
# missing list, so a rewording that keeps the answer passes and a rewording that changes
# it fails. bootstrap.sh is never sourced — it ends in `blib_main "$@"` — and no mise is
# needed: the helper is pure by design. Non-vacuity is asserted too: a helper that
# returned everything would satisfy "the lean tools are present", so the heavy ones are
# checked to be ABSENT. A textual belt follows: the one `mise install` call must be fed
# `$tools`, the helper's answer, not `$missing`.
# shellcheck disable=SC2016  # file-wide: the single-quoted `$tools` / `$missing` below are literal
#                             grep patterns and messages NAMING those variables, not expansions
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT="$HERE/bootstrap.sh"
rc=0
ok()   { printf '   ok   %s\n' "$1"; }
bad()  { printf '   FAIL %s\n' "$1"; rc=1; }
note() { printf '   --   %s\n' "$1"; }

[ -f "$BOOT" ] || { printf '!! no bootstrap.sh at %s\n' "$BOOT"; exit 2; }

# Extract the list and the helper. The list is a single assignment line; the helper runs
# from its `_alpine_mise_select()` line to the first `}` in column 0.
_lean_line="$(grep -E '^ALPINE_MISE_LEAN=' "$BOOT" || true)"
_helper="$(sed -n '/^_alpine_mise_select()/,/^}/p' "$BOOT")"
if [ -z "$_lean_line" ] || [ -z "$_helper" ]; then
  printf '!! could not find ALPINE_MISE_LEAN= and/or _alpine_mise_select() in bootstrap.sh —\n'
  printf '   the lean-set logic was restructured and this gate now checks nothing. Re-point it.\n'
  exit 2
fi
eval "$_lean_line"
eval "$_helper"
note "lean set under test: $ALPINE_MISE_LEAN"

# The ten tools Core's mise/config.toml declares minus foundry (excluded via
# /etc/mise/config.toml, so `mise ls --missing` never names it), in mise's own order.
MISSING="node pnpm python ruby go rust java lua zig terraform"
LEAN_EXPECTED="node pnpm python ruby lua"
HEAVY="go rust java zig terraform"

# shellcheck disable=SC2086  # $MISSING: space-separated tool names, split on purpose
_select() { _alpine_mise_select "$1" $MISSING; }

got="$(_select 1)"
if [ "$got" = "$LEAN_EXPECTED" ]; then
  ok "mode 1 selects exactly the lean set, in mise's order: $got"
else
  bad "mode 1 selected '$got', expected '$LEAN_EXPECTED'"
fi
# Non-vacuity: every heavy tool must be ABSENT from the lean answer.
_leak=""
for _t in $HEAVY; do
  case " $got " in *" $_t "*) _leak="$_leak $_t" ;; esac
done
if [ -z "$_leak" ]; then
  ok "mode 1 defers every heavy tool ($HEAVY)"
else
  bad "mode 1 would install heavy tool(s):$_leak — that is the disk-exhaustion #221 is about"
fi

got="$(_select all)"
if [ "$got" = "$MISSING" ]; then
  ok "mode all selects every missing tool, unchanged"
else
  bad "mode all selected '$got', expected '$MISSING'"
fi

for _m in "" 0 yes true lean; do
  got="$(_select "$_m")"
  if [ -z "$got" ]; then
    ok "mode '${_m:-<unset>}' selects nothing"
  else
    bad "mode '${_m:-<unset>}' selected '$got' — only 1 and all may install"
  fi
done

# The belt: the install line in bootstrap.sh. Comment-stripped, so the paragraphs that
# explain the old shape cannot satisfy or trip it. Exactly one `"$mise_bin" install` call,
# fed `$tools` (the helper's answer) — not `$missing`, which would reinstall the full set.
_code="$(grep -vE '^[[:space:]]*#' "$BOOT")"
_installs="$(printf '%s\n' "$_code" | grep -E '"\$mise_bin" install ' || true)"
_n="$(printf '%s\n' "$_installs" | grep -c . || true)"
if [ "$_n" -eq 1 ] && printf '%s\n' "$_installs" | grep -qE '"\$mise_bin" install \$tools([^[:alnum:]_]|$)'; then
  ok 'bootstrap.sh has one `"$mise_bin" install` call and it is fed $tools'
else
  bad "expected exactly one \`\"\$mise_bin\" install \$tools\` call in bootstrap.sh, found $_n:"
  printf '%s\n' "$_installs" | sed 's/^/        /'
fi
if printf '%s\n' "$_code" | grep -qE '"\$mise_bin" install \$missing'; then
  bad 'bootstrap.sh feeds $missing to `mise install` — the full set would install again'
else
  ok 'nothing feeds $missing to `mise install`'
fi

exit "$rc"
