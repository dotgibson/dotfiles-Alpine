#!/usr/bin/env bash
# test/check-boot-tmp-sweep.sh
# ──────────────────────────────────────────────────────────────────────────────
# Does bootstrap.sh's run-dir sweep remove only STRANDED run dirs — never a live run's?
#
# THE BUG THIS EXISTS FOR (dotfiles-Alpine#221, and the review on #224). bootstrap puts
# TMPDIR at ~/.cache/dotfiles-bootstrap/run.XXXXXX for the whole run and removes it from
# bootstrap_closing and the EXIT trap. Neither fires on SIGKILL, the OOM killer or a
# power-off, so a hard-killed run strands a dir holding mise's scratch and ruby's build
# tree — ~1.2 GB on the issue's VM. The first fix swept any run.* older than a day, and
# that was wrong in the other direction: activity deep inside the tree does not refresh
# the dir's own mtime, so a second bootstrap could delete a still-running one's TMPDIR
# after 24 h. The rule now: each run writes its PID to run.*/.pid; a dir whose owner is
# alive is never touched, a dir whose owner is dead goes at once, and only a dir with no
# .pid falls back to the age test.
#
# BEHAVIOURAL, NOT TEXTUAL. _boot_tmp_setup and _boot_tmp_cleanup are EXTRACTED from
# bootstrap.sh (never sourced — it ends in `blib_main "$@"`) and run against a scratch
# XDG_CACHE_HOME holding one dir of each kind. The live owner is THIS shell; the dead
# owner is a child that has already exited. Every assertion is on what is left on disk.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT="$HERE/bootstrap.sh"
rc=0
ok()   { printf '   ok   %s\n' "$1"; }
bad()  { printf '   FAIL %s\n' "$1"; rc=1; }
note() { printf '   --   %s\n' "$1"; }

[ -f "$BOOT" ] || { printf '!! no bootstrap.sh at %s\n' "$BOOT"; exit 2; }
[ -d /proc/$$ ] || { printf '!! no /proc on this box — the liveness test needs it; skipping\n'; exit 0; }

_setup="$(sed -n '/^_boot_tmp_setup()/,/^}/p' "$BOOT")"
_cleanup="$(sed -n '/^_boot_tmp_cleanup()/,/^}/p' "$BOOT")"
if [ -z "$_setup" ] || [ -z "$_cleanup" ]; then
  printf '!! could not find _boot_tmp_setup() / _boot_tmp_cleanup() in bootstrap.sh —\n'
  printf '   the run-dir logic was restructured and this gate now checks nothing. Re-point it.\n'
  exit 2
fi

scratch="$(mktemp -d)" || { printf '!! mktemp failed\n'; exit 2; }
trap 'rm -rf -- "$scratch"' EXIT
base="$scratch/dotfiles-bootstrap"
mkdir -p "$base/run.alive" "$base/run.dead" "$base/run.legacy-old" "$base/run.legacy-new" "$base/not-a-run"

# A PID that is certainly dead: a child that has already been reaped.
( : ) & dead_pid=$!; wait "$dead_pid"
printf '%s\n' "$$" >"$base/run.alive/.pid"
printf '%s\n' "$dead_pid" >"$base/run.dead/.pid"
touch -t 202601010000 "$base/run.legacy-old" "$base/not-a-run"
note "live owner: $$ · dead owner: $dead_pid"

# Run the sweep in a child shell with the scratch cache; the child's own run dir is then
# cleaned by its EXIT chain, which this also checks.
XDG_CACHE_HOME="$scratch" bash -c '
  set -euo pipefail
  eval "$1"; eval "$2"
  trap "echo prev-trap-ran" EXIT
  _boot_tmp_setup
  [ -n "${_BOOT_TMP:-}" ] || { echo "!! _boot_tmp_setup made no run dir"; exit 3; }
  printf "%s\n" "$_BOOT_TMP" >"$XDG_CACHE_HOME/own"
  [ "$(cat "$_BOOT_TMP/.pid")" = "$$" ] || { echo "!! .pid does not hold the owning shell PID"; exit 3; }
' _ "$_setup" "$_cleanup" >"$scratch/out" 2>&1
child_rc=$?
own="$(cat "$scratch/own" 2>/dev/null || true)"

if [ "$child_rc" -eq 0 ] && grep -q '^prev-trap-ran$' "$scratch/out"; then
  ok "the run dir is created, .pid holds the owner, and the chained EXIT trap still runs"
else
  bad "setup harness failed (rc=$child_rc):"; sed 's/^/        /' "$scratch/out"
fi

[ -d "$base/run.alive" ]      && ok "a run dir whose owner is ALIVE is kept, even when nothing refreshes its mtime" || bad "run.alive (live owner) was deleted — a concurrent bootstrap would lose its TMPDIR"
[ ! -d "$base/run.dead" ]     && ok "a run dir whose owner is DEAD is swept at once (no age wait)"                 || bad "run.dead (dead owner) survived — stranded scratch stays until it ages out"
[ ! -d "$base/run.legacy-old" ] && ok "a run dir with no .pid older than a day is swept"                            || bad "run.legacy-old (no .pid, old) survived"
[ -d "$base/run.legacy-new" ] && ok "a run dir with no .pid that is fresh is kept"                                  || bad "run.legacy-new (no .pid, fresh) was deleted"
[ -d "$base/not-a-run" ]      && ok "an unrelated dir in the cache base is never touched"                            || bad "not-a-run was deleted — the sweep reached past run.*"
if [ -n "$own" ] && [ ! -d "$own" ]; then
  ok "the run's own dir was removed by its EXIT chain"
else
  bad "the run's own dir ${own:-<unknown>} survived its EXIT — the cleanup chain is broken"
fi

exit "$rc"
