# Alpine Linux Aliases Cheat Sheet

OS-specific aliases from `os/alpine.zsh`. See `core/` for the universal alias
reference (modern CLI, git, safety nets) that applies on every machine.

Alpine uses `doas` as its default privilege tool. When `sudo` is not installed
and `doas` is present, a `sudo='doas'` alias is created so muscle memory works.
Note: glibc-linked prebuilt binaries will not run on Alpine (musl libc); install via
`apk` or use musl builds.

## Privilege Escalation

| Alias | Expands To | Condition |
|-------|-----------|----------|
| `sudo` | `doas` | `sudo` not installed and `doas` present |

## Package Management (apk)

`_ASU` is set at shell load time to `doas `, `sudo `, or empty string (when running
as root) — the privilege prefix is baked into each alias at definition time, not
resolved per invocation.

| Alias | Expands To |
|-------|------------|
| `apku` | `${_ASU}apk update && ${_ASU}apk upgrade` |
| `apki` | `${_ASU}apk add` |
| `apkr` | `${_ASU}apk del` |
| `apks` | `apk search` |
| `apkw` | `apk info --who-owns` (which package owns a file) |
| `apkl` | `apk info -L` (list files in a package) |
| `apkv` | `apk version` |

## Clipboard / WSL2 / Navigation

| Alias | Expands To | Condition |
|-------|-----------|----------|
| `pbcopy` | `clip` | clip available |
| `pbpaste` | `clip-paste` | clip-paste available |
| `dotsync` | `cd ~/dotfiles-Alpine` | always |
| `opsignin` | `eval "$(op signin)"` | 1Password CLI |
| `localip` | `ip -brief -4 addr show scope global` | always |
| `open` | `explorer.exe` | WSL2 |
| `xdg-open` | `wslview` | WSL2 + wslview |
| `cdwin` | `cd "$WINHOME"` | WSL2 + WINHOME set |
