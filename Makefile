# dotfiles-Alpine/Makefile — the local mirror of CI, and nothing more.
#
# This adds NO logic of its own: every target runs the same tool, with the same flags
# and the same excludes, that dotfiles-core's reusable gate runs in CI
# (core/.github/workflows/lint-call.yml). Same convention as core/Makefile — the
# scripts and workflows stay the single source of truth; this is just the button.
#
# WHY IT EXISTS: until now every check in this repo was CI-only, so the first signal
# that a change was broken arrived after the push — and with CI advisory rather than
# required, sometimes not at all.
#
# A missing tool SKIPs with a note instead of failing, so a box without actionlint can
# still run the shell gate. CI is the strict mirror; this is the fast one.

SHELL := /bin/sh
.DEFAULT_GOAL := help

# Repo-owned files only. core/ is a vendored subtree gated by its own upstream CI;
# linting it here would report findings this repo is not allowed to fix.
SH_FILES  := $(shell git ls-files '*.sh' ':!:core/**')
ZSH_FILES := $(shell git ls-files '*.zsh' ':!:core/**')

# Identical to the reusable gate's env, so a local pass means a CI pass.
export SHELLCHECK_OPTS := -e SC1090 -e SC1091 -e SC2015 -e SC2088

.PHONY: help lint check shell zsh actions md secrets packages-check core-verify verify-core dry-run hooks capabilities

help:
	@echo 'dotfiles-Alpine — local gates (mirror of CI)'
	@echo ''
	@echo '  make lint           every static gate below, in order (== the CI gate)'
	@echo '  make check          lint + a hermetic --links-only run in a throwaway HOME'
	@echo '  make shell          shellcheck + bash -n on repo-owned *.sh'
	@echo '  make zsh            zsh -n on repo-owned *.zsh (incl. zsh/zshenv.zsh)'
	@echo '  make actions        actionlint on .github/workflows'
	@echo '  make md             markdownlint-cli2 on tracked markdown'
	@echo '  make secrets        gitleaks over the working tree'
	@echo '  make packages-check do all install/packages.txt names still resolve? (needs apk)'
	@echo '  make core-verify    is the vendored core/ still pristine vs core.lock?'
	@echo '  make dry-run        preview the bootstrap wiring; change nothing'
	@echo '  make hooks          install the pre-commit hooks'

# ── the canonical fleet verbs (dotgibson/dotfiles-core#691) ───────────────────
# `lint`, `check`, `packages-check` and `core-verify` are four of the seven names every
# repo that vendors Core must answer to (Core's scripts/make-vocabulary.txt; `make
# fleet-vocabulary` there renders the register that checks it). Before that list, "verify
# core" had five spellings across nine repos, "dry run" two, and only `help` was common to
# every Makefile — a contributor re-learned the verbs in each repo and no gate noticed.
#
# THE AGGREGATE MOVED, and that is the one behaviour change here. This repo's `check` ran
# the static gates; the fleet spells that `lint`, and reserves `check` for "lint plus a
# hermetic --links-only run". So the old aggregate is now `lint` — unchanged, same
# prerequisites — and `check` is lint plus the bootstrap run. `make check` therefore does
# strictly MORE than it did, never less.
lint: shell zsh actions md secrets capabilities
	@echo '✓ all local gates passed'

check: lint
	@# `lint` proves the repo-owned shell parses; this proves the installer still wires the
	@# symlink graph Core's loader expects — into a throwaway HOME, so it is safe to run on
	@# a live box.
	@#
	@# ALPINE ONLY, and as root (or with doas/sudo): bootstrap.sh refuses anywhere without
	@# ID=alpine, and a non-dry run wants an escalator for blib_set_login_shell. Off Alpine
	@# this fails with bootstrap's own message rather than reporting a green it did not
	@# earn; the container equivalent runs from .github/workflows/bootstrap.yml.
	@#
	@# tpm is pre-created because blib_link_core clones the tmux plugin manager into it on
	@# a first run; this asserts symlinks, not network.
	@tmp=$$(mktemp -d); \
	mkdir -p "$$tmp/.config/tmux/plugins/tpm"; \
	echo ":: bootstrap --links-only into $$tmp"; \
	HOME="$$tmp" ./bootstrap.sh --links-only >/dev/null || { echo 'bootstrap failed'; rm -rf "$$tmp"; exit 1; }; \
	rc=0; \
	for l in .config/zsh/loader.zsh .config/zsh/80-os.zsh .config/starship.toml \
	         .config/lazygit/config.yml .config/nvim .vimrc .gitconfig; do \
	  [ -L "$$tmp/$$l" ] || { echo "MISSING symlink: $$l"; rc=1; }; \
	done; \
	[ -e "$$tmp/.config/zsh/loader.zsh" ] || { echo 'loader.zsh is dangling'; rc=1; }; \
	[ -f "$$tmp/.config/sesh/sesh.toml" ] || { echo 'sesh.toml not seeded'; rc=1; }; \
	[ -L "$$tmp/.config/sesh/sesh.toml" ] && { echo 'sesh.toml must be a copy, not a link'; rc=1; }; \
	grep -q 'dotfiles-managed v4' "$$tmp/.zshrc" || { echo '~/.zshrc not managed'; rc=1; }; \
	grep -q 'source .*loader.zsh' "$$tmp/.zshrc" || { echo '~/.zshrc does not source the loader'; rc=1; }; \
	rm -rf "$$tmp"; \
	[ $$rc -eq 0 ] && echo '✓ symlink graph OK' || exit 1

# The local half of what bootstrap.yml's `packages_check: apk info` leg asks in an
# alpine:3.24 container. `apk info` is the right probe and the alternatives are traps,
# for the reasons that workflow records: `apk policy` exits 0 for a BOGUS name (a gate
# that can never fail) and `apk info -e` queries only INSTALLED packages (a gate that
# always fails). Do not "simplify" this to either.
#
# The parse is blib_read_pkgs' rule (drop from the first #, strip blanks, skip empties)
# spelled in POSIX sh: this Makefile runs under /bin/sh and bootstrap-lib.sh is bash, so
# sourcing it here would break on the busybox ash a real Alpine box has.
packages-check:
	@command -v apk >/dev/null 2>&1 || { echo 'apk not found — run this on Alpine (CI covers it: .github/workflows/bootstrap.yml)'; exit 1; }
	@pkgs=$$(sed 's/#.*//' install/packages.txt | tr -d '[:blank:]' | grep -v '^$$'); \
	[ -n "$$pkgs" ] || { echo 'no packages parsed from install/packages.txt'; exit 1; }; \
	echo ":: resolving $$(echo "$$pkgs" | wc -l) package names (no download, no install)"; \
	rc=0; \
	for p in $$pkgs; do \
	  apk info "$$p" >/dev/null 2>&1 || { echo "  UNRESOLVED: $$p"; rc=1; }; \
	done; \
	[ $$rc -eq 0 ] && echo '✓ all package names resolve' || \
	  echo '^^ renamed or dropped upstream — fix install/packages.txt, or add a presence-guarded fallback in bootstrap.sh'; \
	exit $$rc

shell:
	@command -v shellcheck >/dev/null 2>&1 || { echo '- shellcheck not installed — SKIP'; exit 0; }; \
	  [ -n "$(SH_FILES)" ] || { echo '- no repo-owned *.sh'; exit 0; }; \
	  echo ':: shellcheck $(SH_FILES)'; shellcheck $(SH_FILES)
	@[ -n "$(SH_FILES)" ] || exit 0; \
	  for f in $(SH_FILES); do echo ":: bash -n $$f"; bash -n "$$f" || exit 1; done

zsh:
	@command -v zsh >/dev/null 2>&1 || { echo '- zsh not installed — SKIP'; exit 0; }; \
	  [ -n "$(ZSH_FILES)" ] || { echo '- no repo-owned *.zsh'; exit 0; }; \
	  for f in $(ZSH_FILES); do echo ":: zsh -n $$f"; zsh -n "$$f" || exit 1; done

actions:
	@command -v actionlint >/dev/null 2>&1 || { echo '- actionlint not installed — SKIP'; exit 0; }; \
	  echo ':: actionlint'; actionlint -color

# Markdown is the deliverable on a public showcase repo and the one file class that
# shellcheck / zsh -n never inspect. .markdownlint.jsonc has always been here; until
# now nothing ran it (the lint workflow skipped **.md outright), so it was decoration.
md:
	@command -v markdownlint-cli2 >/dev/null 2>&1 || { echo '- markdownlint-cli2 not installed — SKIP'; exit 0; }; \
	  echo ':: markdownlint-cli2'; markdownlint-cli2 $$(git ls-files '*.md' ':!:core/**')

# This repo is public. Core runs gitleaks at author time and in
# its audit; nothing ran it here. GitHub push protection covers provider patterns only.
#
# -c core/gitleaks.toml is the ONE fleet policy — the same file Core's reusable lint-call.yml
# passes for the blocking CI leg, so author time and CI measure the same thing. This used to
# point at a repo-local .gitleaks.toml, which gitleaks ALSO auto-discovers: every scan in this
# repo silently ran under a private rule set, and read as green because that set allowlisted
# the finding rather than because Core's policy was applied (dotgibson/dotfiles-core#624).
# See VENDORING.md, "The gates you run OVER the vendored tree".
secrets:
	@command -v gitleaks >/dev/null 2>&1 || { echo '- gitleaks not installed — SKIP'; exit 0; }; \
	  echo ':: gitleaks'; gitleaks dir . -c core/gitleaks.toml --no-banner --redact

# Content-addressed tamper check: does HEAD:core still match the commit core.lock
# pins? Delegates to Core's own script — this repo does not reimplement it.
#
# It must be run from a dotfiles-core CHECKOUT, not from the vendored copy under
# core/: the check resolves <core_sha>^{tree} in Core's object store, and this repo's
# history does not contain Core's commits (git subtree --squash brings the tree, not
# the lineage). That is also exactly how CI invokes it — core-integrity-call.yml runs
# ./dotfiles-core/scripts/core-integrity.sh --self <os-repo>. Override the location
# with:  make verify-core CORE_REPO=/path/to/dotfiles-core
#
# NB: there is deliberately no `core-lock` target, despite core.lock's own header
# instructing `make core-lock`. That file is GENERATED by dotfiles-core's
# sync-core.sh; a second generator living here could drift from upstream's format and
# produce a lock that disagrees with the fleet. The header is an upstream doc bug.
CORE_REPO ?= ../dotfiles-core

core-verify:
	@[ -x "$(CORE_REPO)/scripts/core-integrity.sh" ] || { \
	    echo '- no dotfiles-core checkout at $(CORE_REPO) — SKIP'; \
	    echo '  (clone it beside this repo, or: make verify-core CORE_REPO=/path/to/dotfiles-core)'; \
	    exit 0; }; \
	  "$(CORE_REPO)/scripts/core-integrity.sh" --self "$(CURDIR)"

# This repo's historical spelling for the target above, kept so anything that already
# calls it — muscle memory, a local script, the docs' older lines — keeps working. The
# requirement is that the canonical name exists, not that this one dies.
verify-core: core-verify

dry-run:
	@./bootstrap.sh --dry-run

hooks:
	@command -v pre-commit >/dev/null 2>&1 || { echo 'pre-commit not installed: pip install pre-commit'; exit 1; }; \
	  pre-commit install

# ── the OS capability declaration (Core v5, #663/#667) ────────────────────────
# ONE definition of the schema gates all seven declaring repos: the validator is
# core/scripts/check-capabilities.sh, vendored with Core, so a schema change arrives
# with the next sync instead of needing seven hand-written greps to be updated in
# step. Core's own `make audit` runs the same script over its shipped example and
# sweeps the fleet for these files; this is the local half of that gate.
#
# The glob is guarded because an unmatched glob stays LITERAL in sh — without the
# test this would "validate" a file named `os/*.capabilities` and pass on nothing,
# which is the failure mode a gate must never have.
capabilities: ## Validate os/*.capabilities against Core's schema
	@rc=0; found=0; \
	for f in os/*.capabilities; do \
	  [ -e "$$f" ] || continue; found=1; \
	  core/scripts/check-capabilities.sh "$$f" --packages install/packages.txt || rc=1; \
	done; \
	if [ "$$found" -eq 0 ]; then echo "!! no os/*.capabilities — this repo must declare one (see core/examples/os.capabilities.example)"; rc=1; fi; \
	exit $$rc

