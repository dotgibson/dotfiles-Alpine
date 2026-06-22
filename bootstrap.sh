#!/usr/bin/env bash
# dotfiles-Alpine/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# Provision an Alpine box (bare-metal / VM / container / WSL) and wire dotfiles.
# Idempotent. OS-NATIVE layer; Core (zsh/tmux/nvim/git) is vendored under core/.
# Alpine is the outlier: musl libc, doas (not sudo), ash default shell, OpenRC.
#
# Usage:
#   ./bootstrap.sh                 # full: apk packages + extras + symlinks
#   ./bootstrap.sh --links-only    # just (re)create symlinks
#
# Run as root, OR as a user with doas/sudo configured (Alpine defaults to doas).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LINKS_ONLY=0

for a in "$@"; do case "$a" in
	--links-only) LINKS_ONLY=1 ;;
	-h | --help)
		sed -n '2,12p' "$0"
		exit 0
		;;
	*)
		echo "unknown arg: $a" >&2
		exit 1
		;;
	esac done

say() { printf '\e[36m::\e[0m %s\n' "$*"; }
ok() { printf '\e[32m+\e[0m %s\n' "$*"; }

# ── privilege tool: Alpine defaults to doas, not sudo. Use nothing if root. ──
if [[ "$(id -u)" -eq 0 ]]; then
	SU=""
elif command -v doas >/dev/null 2>&1; then
	SU="doas"
elif command -v sudo >/dev/null 2>&1; then
	SU="sudo"
else
	echo "Need root: run as root, or 'apk add doas' and configure /etc/doas.d." >&2
	exit 1
fi

# ── Detect WSL ────────────────────────────────────────────────────────────────
IS_WSL=0
if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
	IS_WSL=1
fi

# ── sanity: confirm we're on Alpine ───────────────────────────────────────────
if ! grep -qiE '^ID=alpine' /etc/os-release 2>/dev/null; then
	echo "This bootstrap targets Alpine Linux (expects ID=alpine in /etc/os-release)." >&2
	exit 1
fi

# ── core/ subtree present? ────────────────────────────────────────────────────
if [[ ! -d "$DOTFILES/core/zsh" ]]; then
	echo "core/ subtree missing. One-time, run:" >&2
	echo "  git subtree add --prefix=core <dotfiles-core remote> main --squash" >&2
	exit 1
fi

link() { # link SRC -> DST, backing up any existing real file
	local src="$1" dst="$2"
	mkdir -p "$(dirname "$dst")"
	if [[ -L "$dst" ]]; then
		rm -f "$dst"
	elif [[ -e "$dst" ]]; then mv "$dst" "$dst.pre-dotfiles.$(date +%s)"; fi
	ln -s "$src" "$dst"
}

read_pkgs() { # $1 = file; prints clean package names, one per line
	local line
	while IFS= read -r line; do
		line="${line%%#*}"
		line="${line//[[:space:]]/}"
		[[ -n "$line" ]] && printf '%s\n' "$line"
	done <"$1"
}

# ── resilient install: apk fails the whole transaction on one unknown package.
# Bulk first, then per-package so a missing name is skipped, not fatal.
apk_install() {
	local -a pkgs=("$@")
	if $SU apk add "${pkgs[@]}"; then return 0; fi
	say "bulk install hit a snag — retrying package-by-package"
	local p
	for p in "${pkgs[@]}"; do
		$SU apk add "$p" || echo "   skipped (unavailable on this box?): $p"
	done
}

provision() {
	say "apk update"
	$SU apk update

	say "apk packages (from install/packages.txt)"
	local -a pkgs=()
	mapfile -t pkgs < <(read_pkgs "$DOTFILES/install/packages.txt")
	apk_install "${pkgs[@]}"
	ok "apk packages requested: ${#pkgs[@]}"

	# Tools not packaged (or that we build from source on musl). The starship and
	# mise installers detect musl and pull the correct *-musl build — safe here.
	# atuin is in Alpine repos (in packages.txt); installer below is just a fallback.
	if ! command -v starship >/dev/null; then
		say "starship (official installer — musl build)"
		curl -fsSL https://starship.rs/install.sh | sh -s -- -y >/dev/null
	fi
	if ! command -v atuin >/dev/null; then
		say "atuin (official installer — fallback; usually apk-installed)"
		curl -fsSL https://setup.atuin.sh | sh >/dev/null 2>&1 || true
	fi
	if ! command -v mise >/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
		say "mise (official installer — musl build)"
		curl -fsSL https://mise.run | sh >/dev/null 2>&1 || true
	fi
	# yazi + tree-sitter-cli: not packaged → build from source via cargo. On musl
	# this compiles against the musl target (needs build-base, in packages.txt).
	if ! command -v yazi >/dev/null && command -v cargo >/dev/null; then
		say "yazi (cargo build — slow on musl)"
		cargo install --locked yazi-fs yazi-cli >/dev/null 2>&1 || true
	fi
	if ! command -v tree-sitter >/dev/null && command -v cargo >/dev/null; then
		say "tree-sitter-cli (cargo build)"
		cargo install --locked tree-sitter-cli >/dev/null 2>&1 ||
			echo "   tree-sitter-cli build failed; retry later: cargo install tree-sitter-cli"
	fi

	# ── WSL: install /etc/wsl.conf. NOTE: no systemd=true — Alpine uses OpenRC. ─
	if ((IS_WSL)); then
		say "installing /etc/wsl.conf (default user + interop; OpenRC, not systemd)"
		local user
		user="$(id -un)"
		sed "s/__WSL_USER__/$user/" "$DOTFILES/wsl/wsl.conf" | $SU tee /etc/wsl.conf >/dev/null
		ok "wsl.conf written — run 'wsl.exe --shutdown' from Windows, then reopen"
	fi
}

wire_links() {
	say "symlinking Core"
	for f in "$DOTFILES"/core/zsh/*.zsh; do
		link "$f" "$CONFIG/zsh/$(basename "$f")"
	done
	[[ -f "$DOTFILES/core/tmux/tmux.conf" ]] && link "$DOTFILES/core/tmux/tmux.conf" "$CONFIG/tmux/tmux.conf"
	if [[ -d "$DOTFILES/core/tmux/scripts" ]]; then
		link "$DOTFILES/core/tmux/scripts" "$CONFIG/tmux/scripts"
		chmod +x "$DOTFILES"/core/tmux/scripts/*.sh 2>/dev/null || true
	fi
	[[ -f "$DOTFILES/os/alpine.conf" ]] && link "$DOTFILES/os/alpine.conf" "$CONFIG/tmux/os.conf"
	if [[ ! -d "$CONFIG/tmux/plugins/tpm" ]]; then
		say "cloning tpm (tmux plugin manager)"
		git clone --depth=1 https://github.com/tmux-plugins/tpm "$CONFIG/tmux/plugins/tpm" >/dev/null 2>&1 &&
			ok "tpm cloned — run prefix+I in tmux to install plugins" ||
			say "tpm clone failed — clone it manually, then prefix+I"
	fi
	[[ -f "$DOTFILES/core/starship/starship.toml" ]] && link "$DOTFILES/core/starship/starship.toml" "$CONFIG/starship.toml"
	[[ -d "$DOTFILES/core/nvim" ]] && link "$DOTFILES/core/nvim" "$CONFIG/nvim"
	[[ -f "$DOTFILES/core/mise/config.toml" ]] && link "$DOTFILES/core/mise/config.toml" "$CONFIG/mise/config.toml"
	[[ -f "$DOTFILES/core/git/gitconfig" ]] && link "$DOTFILES/core/git/gitconfig" "$HOME/.gitconfig"
	[[ -f "$DOTFILES/os/alpine.gitconfig" ]] && link "$DOTFILES/os/alpine.gitconfig" "$CONFIG/git/os.gitconfig"
	if [[ ! -f "$CONFIG/git/local.gitconfig" && -f "$DOTFILES/core/git/local.gitconfig.example" ]]; then
		mkdir -p "$CONFIG/git"
		cp "$DOTFILES/core/git/local.gitconfig.example" "$CONFIG/git/local.gitconfig"
		say "seeded ~/.config/git/local.gitconfig — FILL IN your name & email"
	fi
	if [[ -d "$DOTFILES/core/bin" ]]; then
		mkdir -p "$HOME/.local/bin"
		for s in clip clip-paste; do
			if [[ -f "$DOTFILES/core/bin/$s" ]]; then
				link "$DOTFILES/core/bin/$s" "$HOME/.local/bin/$s"
				chmod +x "$DOTFILES/core/bin/$s" 2>/dev/null || true
			fi
		done
	fi
	if [[ -f "$DOTFILES/ssh/config" ]]; then
		say "symlinking ssh/config"
		mkdir -p "$HOME/.ssh/sockets"
		chmod 700 "$HOME/.ssh" "$HOME/.ssh/sockets"
		chmod 600 "$DOTFILES/ssh/config" 2>/dev/null || true
		link "$DOTFILES/ssh/config" "$HOME/.ssh/config"
		ok "~/.ssh/config linked (generate a key with: ssh-keygen -t ed25519)"
	fi

	say "symlinking Alpine OS-native layer"
	link "$DOTFILES/os/alpine.zsh" "$CONFIG/zsh/os.zsh"

	if [[ ! -f "$HOME/.zshrc" ]] || ! grep -q "dotfiles-managed v2" "$HOME/.zshrc" 2>/dev/null; then
		say "writing .zshrc loader"
		[[ -f "$HOME/.zshrc" ]] && cp "$HOME/.zshrc" "$HOME/.zshrc.pre-dotfiles.$(date +%s)"
		cat >"$HOME/.zshrc" <<'ZRC'
# dotfiles-managed v2 — do not hand-edit; put local tweaks in ~/.config/zsh/local.zsh
# Alpine's default shell is ash and there's no ~/.zshenv, so this entry file sets
# the env the Core modules expect, then sources them in the ONE correct order.

# ── XDG + env ─────────────────────────────────────────────────────────────────
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${XDG_CACHE_HOME:=$HOME/.cache}"
export EDITOR=nvim VISUAL=nvim
export NOTES_DIR="${NOTES_DIR:-$HOME/Notes}"

# ── Core modules + Alpine os layer + local overrides, in canonical order ──
# history.zsh owns HISTFILE/HISTSIZE + history setopts; options.zsh owns the nav/glob
# setopts + compinit + completion zstyles — so this entry file no longer hand-rolls
# them. It declares the load order and sources the vendored Core loader
# (core/zsh/loader.zsh -> $ZSH_CFG/loader.zsh), which byte-compiles + sources each
# module. Loading the FULL set (ui/git/maint/update were silently missing) is the fix.
: "${ZDOTDIR:=$XDG_CONFIG_HOME/zsh}"
export ZDOTDIR              # Core modules (history/options) key state off ZDOTDIR;
ZSH_CFG="$ZDOTDIR"          # align the loader to the SAME dir so state never splits
_CORE_MODULES=(tools ui options history aliases git functions fzf bindings plugins op maint update os local)
if [[ -r "$ZSH_CFG/loader.zsh" ]]; then
  source "$ZSH_CFG/loader.zsh"
else
  print -u2 -- "zshrc: Core loader not found at $ZSH_CFG/loader.zsh — re-run the dotfiles bootstrap to (re)link Core."
fi
unset _CORE_MODULES
ZRC
	fi

	# make zsh the default LOGIN shell. Alpine has no getent (busybox), so read
	# the current shell straight from /etc/passwd. chsh comes from the `shadow`
	# package (in packages.txt); if it's missing we print the manual step.
	if command -v zsh >/dev/null; then
		local zsh_path user current
		zsh_path="$(command -v zsh)"
		user="$(id -un)"
		current="$(grep "^$user:" /etc/passwd | cut -d: -f7)"
		if [[ "$current" != "$zsh_path" ]]; then
			say "setting zsh as default login shell"
			grep -qxF "$zsh_path" /etc/shells || echo "$zsh_path" | $SU tee -a /etc/shells >/dev/null
			if command -v chsh >/dev/null; then
				$SU chsh -s "$zsh_path" "$user" && ok "default shell -> zsh (applies to NEW logins)"
			else
				say "chsh not found (apk add shadow) — set manually: $SU usermod -s $zsh_path $user"
			fi
		fi
	fi
	ok "symlinks wired"
}

((LINKS_ONLY)) || provision
wire_links
ok "Alpine bootstrap complete — open a new shell or: exec zsh"
