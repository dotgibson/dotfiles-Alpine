# dotfiles-Alpine/os/alpine.zsh
# ──────────────────────────────────────────────────────────────────────────────
# The Alpine OS-native shell layer. Symlinked to ~/.config/zsh/os.zsh and loaded
# AFTER Core (tools/aliases/functions). Alpine-specific only.
#
# Alpine realities reflected here: doas (not sudo), apk (not dnf), musl, and a
# busybox userland where many "classic" commands are applets with fewer flags.
# No SELinux/AppArmor block and no flatpak helpers — Alpine ships neither.
#
# Clipboard logic lives in Core's cross-OS `clip`/`clip-paste`; this layer just
# points pbcopy/pbpaste at them (and on a headless Alpine there may be no
# backend at all, which is expected).
# ──────────────────────────────────────────────────────────────────────────────
[[ $- == *i* ]] || return 0

[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
[[ -d "$HOME/.cargo/bin"  ]] && export PATH="$HOME/.cargo/bin:$PATH"

_IS_WSL=0
if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  _IS_WSL=1
fi

# ── privilege tool: doas is Alpine's default. Alias sudo->doas so muscle memory
# (and most interactive commands) work even where sudo isn't installed.
if ! command -v sudo >/dev/null 2>&1 && command -v doas >/dev/null 2>&1; then
  alias sudo='doas'
fi
# Resolve the right prefix for the apk aliases below (empty when root).
if [[ "$(id -u)" -eq 0 ]]; then _ASU=""
elif command -v doas >/dev/null 2>&1; then _ASU="doas "
else _ASU="sudo "; fi

# ── Clipboard: delegate to Core's cross-OS scripts ────────────────────────────
command -v clip       >/dev/null && alias pbcopy='clip'
command -v clip-paste >/dev/null && alias pbpaste='clip-paste'

# ── tool completions / shell hooks (parity with the other os layers) ─────────
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh)"
command -v gh     >/dev/null 2>&1 && eval "$(gh completion -s zsh 2>/dev/null)"

# ── conveniences ──────────────────────────────────────────────────────────────
alias dotsync='cd "$HOME/dotfiles-Alpine"'
command -v op >/dev/null 2>&1 && alias opsignin='eval "$(op signin)"'
alias localip='ip -brief -4 addr show scope global'

# ── WSL-only niceties ─────────────────────────────────────────────────────────
if (( _IS_WSL )); then
  alias open='explorer.exe'
  command -v wslview >/dev/null && alias xdg-open='wslview'
  [[ -n "${WINHOME:-}" ]] && alias cdwin='cd "$WINHOME"'
fi

# ── Alpine ships fd as `fd` (not fdfind) — tools.zsh already resolved this. ───

# ── apk quality-of-life (privilege prefix baked in at definition time) ────────
alias apku="${_ASU}apk update && ${_ASU}apk upgrade"
alias apki="${_ASU}apk add"
alias apkr="${_ASU}apk del"
alias apks='apk search'
alias apkw='apk info --who-owns'   # which package owns a file
alias apkl='apk info -L'           # list files a package installed
alias apkv='apk version'           # show upgradable packages
# apk has no transaction "undo"; keep installs deliberate. `apk cache` manages
# the local package cache if you enable it.

unset _ASU _IS_WSL

# ── auto-start/attach tmux for interactive terminals ─────────────────────────
if command -v tmux >/dev/null 2>&1 \
   && [[ -z "$TMUX" && -t 1 && "$TERM_PROGRAM" != "vscode" ]]; then
  tmux attach -t main 2>/dev/null || tmux new-session -s main
fi
