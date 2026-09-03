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

# The canonical fleet `make` vocabulary (dotfiles-core#691): every repo that vendors
# Core answers to the SAME verbs — help, lint, check, dry-run, packages-check,
# core-verify, test — so a contributor moving between OS repos never has to relearn the
# buttons. Where this repo already had a name (verify-core), the historical spelling is
# kept as a .PHONY alias rather than deleted. See VENDORING.md, "The `make` vocabulary,
# and the test floor", in Core.
.PHONY: help lint check shell zsh actions md secrets packages-check core-verify verify-core dry-run test hooks capabilities

help:
	@echo 'dotfiles-Alpine — local gates (mirror of CI)'
	@echo ''
	@echo '  make lint           shellcheck + zsh -n + actionlint + markdown + secrets (== CI lint gate)'
	@echo '  make check          lint + the capability-schema gate; the full local sweep'
	@echo '  make test           run the test/ suite (currently: packages-check)'
	@echo '  make packages-check  do all install/packages.txt names resolve on this Alpine branch?'
	@echo '  make dry-run        preview the bootstrap wiring; change nothing'
	@echo '  make core-verify    is the vendored core/ still pristine vs core.lock?'
	@echo ''
	@echo '  individual lint legs: shell, zsh, actions, md, secrets, capabilities'
	@echo '  make hooks          install the pre-commit hooks'

# The reusable CI gate's legs, in one word. lint.yml calls dotfiles-core's
# lint-call.yml, which runs exactly shell + zsh + actionlint + markdown + gitleaks over
# the repo-owned tree; a green `make lint` here means a green lint check on the PR.
lint: shell zsh actions md secrets
	@echo '✓ lint clean'

check: lint capabilities
	@echo '✓ all local gates passed'

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
	    echo '  (clone it beside this repo, or: make core-verify CORE_REPO=/path/to/dotfiles-core)'; \
	    exit 0; }; \
	  "$(CORE_REPO)/scripts/core-integrity.sh" --self "$(CURDIR)"

# Historical spelling, kept so `make verify-core` still works. The canonical fleet verb
# is core-verify (dotfiles-core#691); this is a one-line alias, not a second copy.
verify-core: core-verify

# Does every apk name in install/packages.txt still resolve on this branch? Installs
# nothing — see the header of the script for why `apk add --simulate` is the right probe.
# This is the smallest useful member of the test/ suite below.
packages-check:
	@./test/check-packages.sh install/packages.txt

# The fleet test floor (dotfiles-core#691): a real suite under test/, run here. Every
# executable script in test/ runs; today that is just check-packages.sh, but new checks
# drop in without touching this target. `test` is a canonical verb with no stub form —
# a `test:` that ran nothing would read as no-op in Core's register.
test:
	@rc=0; found=0; \
	for t in test/*.sh; do \
	  [ -e "$$t" ] || continue; found=1; \
	  echo ":: $$t"; "$$t" || rc=1; \
	done; \
	if [ "$$found" -eq 0 ]; then echo '!! test/ has no *.sh — the fleet test floor requires at least one'; rc=1; fi; \
	[ $$rc -eq 0 ] && echo '✓ test suite passed'; exit $$rc

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

