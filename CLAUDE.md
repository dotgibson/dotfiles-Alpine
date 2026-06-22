# CLAUDE.md — dotfiles-Alpine

Project memory for Claude Code, auto-loaded every session. For the shared Core
rules (the load order, the "is it Core?" test, the manifest contract) see
`core/README.md` and `core/CONTRIBUTING.md`.

## What this repo is

`dotfiles-Alpine` is the **OS-native layer for Alpine Linux** in a **nine-repo dotfiles system** built on a three-layer
model (Core → OS-native → Role). Stamped from the Fedora template (see `core/PORTING-MATRIX.md`). The outlier: **musl libc, not glibc** — glibc-linked prebuilt binaries will not run, so prefer `apk` packages or musl builds. Default shell is `ash`, privilege tool is `doas` (not sudo), and many commands are busybox applets. Keep this layer lean.

## The rule that bites

`core/` is a **vendored `git subtree` copy of [dotfiles-core](https://github.com/Gerrrt/dotfiles-core)** — it
is *not* editable here. Anything you change under `core/` is overwritten on the
next sync. To change shared Core config, edit it **in dotfiles-core**, run
`make audit` there, then `make sync` to fan it out to every OS repo.

What belongs **here** is only the OS-native layer: the `apk` package list, clipboard + paths, and the bootstrap.

## Where things are

- `os/alpine.zsh` — clipboard + package-manager aliases for Alpine
- `os/alpine.conf`, `os/alpine.gitconfig` — tmux + git OS overlays
- `install/packages.txt` — Alpine package names
- `bootstrap.sh` — symlinks Core + OS files into place
- `core/` — vendored Core (read-only here; edit upstream in dotfiles-core)
