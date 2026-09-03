<!-- This is the OS-native layer. Keep changes genuinely Alpine; anything identical
     on every distro belongs upstream in dotfiles-core. -->

## What & why

<!-- One or two lines. What changed in the Alpine layer, and why. -->

## Is it actually Alpine?

- [ ] Would **not** be identical on every distro (that belongs in Core → `dotfiles-core`)
- [ ] Does **not** change with the operator (that belongs in a role repo)
- [ ] Works with the musl grain — `apk` / musl builds preferred over prebuilt glibc binaries

## Vendored Core

- [ ] No hand-edits under `core/` (it is a subtree, overwritten on the next sync)
- [ ] `make core-verify` still reports pristine, if a sync was involved

## Checks

- [ ] `make lint` is green locally (shellcheck · `bash -n` · `zsh -n` · markdownlint · gitleaks)
- [ ] On an Alpine box: `make check` — `lint` plus a hermetic `--links-only` run
- [ ] If `bootstrap.sh` changed, `./bootstrap.sh --dry-run` was run and mutates nothing
- [ ] If a new repo-owned `*.zsh` was added, it is covered by the lint glob

## Notes

<!-- Load-order implications, system files touched, follow-up upstream work, etc. -->
