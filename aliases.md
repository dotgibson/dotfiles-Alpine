# Alpine Linux Aliases Cheat Sheet

OS-specific aliases from `os/alpine.zsh`. See `core/` for the universal alias
reference (modern CLI, git, safety nets) that applies on every machine.

Alpine uses `doas` instead of `sudo` — aliased transparently so muscle memory works.
Note: glibc-linked prebuilt binaries will not run on Alpine (musl libc); install via
`apk` or use musl builds.

## Privilege Escalation

| Alias | Expands To |
|-------|------------|
| `sudo` | `doas` (transparent redirect to Alpine's privilege tool) |

## Package Management (apk)

`_ASU` is set at shell load time to `doas `, `sudo `, or empty (when running as root).
The privilege prefix is baked into the alias at definition time.

| Alias | Expands To |
|-------|------------|
| `apku` | `{doas} apk update && {doas} apk upgrade` |
| `apki` | `{doas} apk add` |
| `apkr` | `{doas} apk del` |
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
