# 🏔️ dotfiles-Alpine

**Alpine — lean and musl-native.** The Alpine layer (apk · musl · doas) — lean,
for containers and minimal boxes.

`apk` · `musl` · `nvim` · `tmux`

[![showcase](https://img.shields.io/badge/showcase-live-7aa2f7?style=flat-square)](https://dotgibson.github.io/dotfiles-web/) ![Alpine](https://img.shields.io/badge/Alpine-lean-7dcfff?style=flat-square)

---

The **OS-native layer** for Alpine Linux. Core (zsh/tmux/nvim/git) is vendored
under `core/` from [`dotfiles-core`](../dotfiles-core); this repo adds only what
is genuinely Alpine — apk, doas, the musl-aware build/install choices.

Stamped from the `dotfiles-Fedora` template per `core/PORTING-MATRIX.md`, but
Alpine is the outlier of the set, so more changed here than on the other stamps.
This is the lean / container / rescue-disk box — keep its layer small and don't
fight the musl grain.

## ⚡ Install (fresh Alpine)

```sh
git clone <you>/dotfiles-Alpine ~/dotfiles-Alpine
cd ~/dotfiles-Alpine
# one-time: vendor Core (skip if the repo already contains core/)
git subtree add --prefix=core <you>/dotfiles-core main --squash
./bootstrap.sh
exec zsh
```

Run as **root**, or as a user with **doas** (or sudo) configured — bootstrap
detects which to use. Flag: `--links-only` (re-link without touching apk).
Make sure the `community` repo is enabled in `/etc/apk/repositories` — most of
the modern stack lives there.

## 🗂️ Layout

```
bootstrap.sh         apk provision + Core/OS symlink wiring (idempotent)
install/packages.txt apk package list (modern CLI stack)
os/alpine.zsh        OS-native shell layer -> ~/.config/zsh/os.zsh
os/alpine.gitconfig  OS git layer (credential helper) -> ~/.config/git/os.gitconfig
os/alpine.conf       tmux netspeed/battery bits -> ~/.config/tmux/os.conf
ssh/config           hardened SSH client config -> ~/.ssh/config (keys never tracked)
wsl/wsl.conf         installed to /etc/wsl.conf on WSL (NO systemd — see below)
core/                vendored from dotfiles-core (git subtree; do not hand-edit)
```

Load order in `.zshrc`: `core/tools → core/aliases → core/functions → core/fzf →
core/bindings → core/plugins → core/op → os/alpine → local`.

## 💡 Alpine specifics baked in (the things that actually bite)

- **musl libc, not glibc.** Prebuilt glibc binaries won't run, so the stack comes
  from apk wherever possible. starship and mise are installed via their official
  scripts (both detect musl and pull the correct `*-musl` build); **yazi** and
  **tree-sitter-cli** are compiled from source with `cargo` (that's why
  `build-base` is in the package list). Prefer apk/musl builds over any
  random prebuilt binary you find online.
- **doas, not sudo.** `bootstrap.sh` auto-detects doas → sudo → root. The shell
  layer also aliases `sudo`→`doas` so muscle memory works. Configure
  `/etc/doas.d/doas.conf` (e.g. `permit persist :wheel`) or run as root.
- **ash, not zsh, is the default shell.** zsh is installed explicitly, and the
  default login shell is switched with `chsh` (from the `shadow` package, since
  busybox has none). bootstrap reads the current shell from `/etc/passwd`
  directly because Alpine's busybox has no `getent`.
- **delta** is packaged as `delta` here, not `git-delta` (Fedora/Arch). Core's
  git config calls it `delta` regardless, so nothing changes downstream.
- **atuin** *is* in the Alpine repos (unlike Fedora), so it's an apk package, not
  an installer step.
- **No SELinux/AppArmor and no flatpak.** Alpine ships no default MAC framework
  and flatpak isn't idiomatic here, so those Fedora/openSUSE helper blocks are
  removed entirely — keeping the layer lean.
- **WSL uses OpenRC, not systemd.** The `wsl.conf` here deliberately omits
  `systemd=true`; enabling WSL's systemd mode on a non-systemd distro does
  nothing useful. Run `wsl.exe --shutdown` after first bootstrap to apply it.
- **busybox userland.** Many "classic" commands are busybox applets with fewer
  flags than their GNU counterparts — occasionally a script written for GNU
  tools needs a tweak. The Core functions are written to degrade gracefully.
