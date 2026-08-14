# dotfiles-Alpine/zsh/zshenv.zsh → symlinked to ~/.zshenv by bootstrap.sh.
# OS-NATIVE layer: this exists to satisfy an ALPINE-specific check. Do not port it
# blindly to the other OS repos (see core/PORTING-MATRIX.md).
#
# THE .zsh EXTENSION IS LOAD-BEARING — do not "tidy" it away to match ~/.zshenv.
# Core's reusable lint gate syntax-checks repo-owned zsh via `git ls-files '*.zsh'`
# (core/.github/workflows/lint-call.yml). Named plain `zshenv`, this file matched
# nothing and was the one file in the repo that CI never checked — while being the
# file that runs on EVERY zsh invocation, where a syntax error breaks login shells
# on every Alpine box. The symlink target is ~/.zshenv regardless of source name.
#
# WHY THIS FILE EXISTS
# --------------------
# Alpine ships /etc/zsh/zshrc with an XDG-nudge that warns on every INTERACTIVE LOGIN
# shell:
#
#   Warning: Found Zsh startup files both in ~/ and ~/.config/zsh/, the latter will
#            be ignored (tip: move .zshrc to ~/.config/zsh/).
#
# Its condition is `[[ -z "${ZDOTDIR-}" && -o login ]]` plus "does ~/.config/zsh/.z*
# exist". Both held on a bootstrapped box:
#
#   1. /etc/zsh/zshenv only points ZDOTDIR at ~/.config/zsh when NO ~/.z* files exist.
#      Core writes a managed ~/.zshrc, so that branch never fires and ZDOTDIR stays
#      unset.
#   2. Core's _blib_seed_zdotdir_rc (core/lib/bootstrap-lib.sh) deliberately seeds
#      $ZDOTDIR/.zshrc as a symlink back to ~/.zshrc, so that exporting ZDOTDIR later
#      can't drop you into zsh's new-user wizard with an empty shell.
#
# So the warning is a false positive: the "two" startup files are ONE file reached via
# a symlink. Nothing was ever ignored. Exporting ZDOTDIR fails the `-z` guard and
# silences it at the source, without touching the vendored Core (read-only in this repo
# — fix Core upstream in dotfiles-core, never here).
#
# WHY ~/.config/zsh AND NOT $HOME
# -------------------------------
# ZDOTDIR is NOT just "where zsh finds .zshrc" in this system — Core's managed ~/.zshrc
# does:
#
#   : "${ZDOTDIR:=$XDG_CONFIG_HOME/zsh}" ; ZSH_CFG="$ZDOTDIR"
#
# and then sources "$ZSH_CFG/loader.zsh". ZDOTDIR IS the Core config dir. Setting it to
# $HOME makes the loader look for ~/loader.zsh, which does not exist — the shell then
# starts with Core absent (measured: 110 aliases → 2, 1115 functions → 276, `up` and
# `ll` gone). Point it at ~/.config/zsh, matching the default ~/.zshrc computes anyway,
# and startup is unchanged.
#
# The chain that makes this work: zsh reads $ZDOTDIR/.zshrc → that is the symlink Core
# seeded → which resolves to ~/.zshrc. Same file, same fragments, one less warning.
#
# KEEP THIS FILE MINIMAL. ~/.zshenv is sourced on EVERY zsh invocation — including
# non-interactive scripts and `zsh -c` — so anything slow or interactive here is a tax
# on all of them. Env for interactive shells belongs in the Core fragments; host-local
# tweaks go in ~/.config/zsh/99-local.zsh.

# `:-` not `=`: respect a ZDOTDIR the user already exported rather than overriding it.
# XDG_CONFIG_HOME is resolved the same way ~/.zshrc resolves it, since .zshenv runs
# first and cannot rely on it being set yet.
export ZDOTDIR="${ZDOTDIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}"
