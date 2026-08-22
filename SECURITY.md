# Security Policy

`dotfiles-Alpine` ships **configuration plus one provisioning script**. The config is
inert; `bootstrap.sh` is not — it runs with `doas`/`sudo`, installs packages, adds a
third-party `apk` repository, and writes to `/etc/`. That makes a narrow but real
security surface, and it is the part worth reporting on.

Two classes of issue warrant a security report rather than a normal issue:

- **A tracked file that leaks a secret.** This repo is public
  (keys themselves are denied by `.gitignore`). A leaked token or private key here is
  public the moment it lands.
- **A path in `bootstrap.sh` that can be coerced into running or trusting untrusted
  input** — in particular anything touching `/etc/apk/keys`, `/etc/apk/repositories`,
  `/etc/wsl.conf`, or the login shell. The 1Password signing key is pinned by SHA-256
  and the script fails closed on a mismatch; a way around that check is a valid report.

Note that the vendored `core/` tree is **not** in scope here — it is a `git subtree`
copy of [`dotfiles-core`](https://github.com/dotgibson/dotfiles-core) and is
overwritten on the next sync. Report those upstream, where a fix can actually land.

## Reporting a vulnerability

**Please do not open a public issue for a security report.** Use GitHub's private
vulnerability reporting: the **Security** tab → **Report a vulnerability**. That keeps
details private until a fix is out.

Include, where you can:

- the file and line, and whether it runs at provision time or shell-startup time,
- how it is reached (a `bootstrap.sh` flag, a sourced fragment, a WSL-only branch), and
- a minimal reproduction.

You can expect an acknowledgement within a few days.

## Scope

In scope: `bootstrap.sh`, `install/packages.txt`, `os/*`, `zsh/*`,
`wsl/wsl.conf`, and this repo's workflows.

Out of scope: anything under `core/` (report to `dotfiles-core`), and the upstream
tools this layer installs — report those to their own projects.
