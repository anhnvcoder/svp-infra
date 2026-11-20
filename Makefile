# Static checks of the Terraform of this repository. `make help` lists the targets. No target but ci-plan reaches an
# AWS account: init runs with -backend=false, nothing calls apply or the AWS CLI, and the other plans are those of
# terraform test, against a mock AWS provider, in a container without network or credentials. ci-plan runs in the
# plan job of GitHub Actions alone, with a read-only role, and refuses to run anywhere else.

# Every tool runs from its official image pinned by digest, the same reference on a dev machine and in CI; only
# session-test runs on the host. Docker runs with DOCKER_DEFAULT_PLATFORM unset: the dev machine's shell sets it to
# linux/amd64 for another project, which would run these images under emulation.

# Parallel runs: `make check DIRS=<dir>` writes below <dir> only the .terraform.lock.hcl of a module, and the plugin
# cache that every run shares only gains the versions it lacks, one writer at a time (CACHE_LOCK), so runs on two
# different directories can go side by side.
# Design notes: README.md.

# renovate: datasource=docker depName=hashicorp/terraform
TERRAFORM_IMAGE  := hashicorp/terraform:1.15.8@sha256:7ae513256f7ce67879e218ae8593d6fbe216ec9e123abe6c94e4e10704857963
# renovate: datasource=docker depName=ghcr.io/terraform-linters/tflint
TFLINT_IMAGE     := ghcr.io/terraform-linters/tflint:v0.65.0@sha256:2788f4d4fc663c0e953b011b01bf443fe5bfce7587ee916e588e6057b85d6359
# terraform-docs publishes one tag per architecture (<version>-amd64, <version>-arm64), not a multi-architecture
# manifest: both are pinned, at the same version, and TFDOCS_IMAGE takes the one of this machine (arm64 on the Mac,
# amd64 on the CI runner).
# renovate: datasource=docker depName=quay.io/terraform-docs/terraform-docs
TFDOCS_IMAGE_AMD64 := quay.io/terraform-docs/terraform-docs:0.24.0-amd64@sha256:16990b28302390f7c4ae398b371a46762b6b3eb8534e75eeee8185caa8029b8c
# renovate: datasource=docker depName=quay.io/terraform-docs/terraform-docs
TFDOCS_IMAGE_ARM64 := quay.io/terraform-docs/terraform-docs:0.24.0-arm64@sha256:a877e9516260486cbe54e07f12715819a55391387e82e230fedd36ec68a37282
TFDOCS_IMAGE     := $(if $(filter arm64 aarch64,$(shell uname -m)),$(TFDOCS_IMAGE_ARM64),$(TFDOCS_IMAGE_AMD64))
# Same pin as TRIVY_IMAGE of the code repository's Makefile.
# renovate: datasource=docker depName=ghcr.io/aquasecurity/trivy
TRIVY_IMAGE      := ghcr.io/aquasecurity/trivy:0.76.0@sha256:2416d1f74045b57274df1a340eee6b510cacd73c66a6ccb8da092b117eb7d222
# renovate: datasource=docker depName=koalaman/shellcheck
SHELLCHECK_IMAGE := koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d
# Same pin as ZIZMOR_IMAGE of the code repository's Makefile.
# renovate: datasource=docker depName=ghcr.io/zizmorcore/zizmor
ZIZMOR_IMAGE     := ghcr.io/zizmorcore/zizmor:1.31.1@sha256:42d409dbb851d4c5d35a058cf042b828bea1e3f2884378c526eb0974780e18d9
# Same pins as MARKDOWNLINT_IMAGE and LYCHEE_IMAGE of the code repository's Makefile.
# renovate: datasource=docker depName=davidanson/markdownlint-cli2
MARKDOWNLINT_IMAGE := davidanson/markdownlint-cli2:v0.24.0@sha256:70ead7c0352d22d04bbe612cd96b54ec591538d8f4626cafe391bb2ecf3639ca
# renovate: datasource=docker depName=lycheeverse/lychee
LYCHEE_IMAGE     := lycheeverse/lychee:0.24.2@sha256:e2d19e57cf6ab037026f20b8e449a1f30d9d7f81eef4194763aab2eab20bd28d
# The CI tag of the Infracost CLI: the CLI with bash, git and jq beside it, published for linux/amd64 alone.
# renovate: datasource=docker depName=infracost/infracost
INFRACOST_IMAGE  := infracost/infracost:ci-0.10.49@sha256:78ce091ec7324caa46b8fbc15d7053ea27f4e383c3258779a4746fd5411ed6a1
# Same version as GITLEAKS_VERSION of the code repository's Makefile, which installs it with go install.
# renovate: datasource=docker depName=ghcr.io/gitleaks/gitleaks
GITLEAKS_IMAGE   := ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f
# D2 from its official image (terrastruct/d2 on Docker Hub is a mirror), a multi-architecture index: the SVGs come out
# byte for byte the same on arm64 and amd64, with the ELK and TALA layout engines bundled, offline.
# renovate: datasource=docker depName=d2lang/d2
D2_IMAGE         := d2lang/d2:v0.9.0@sha256:0f9237e0213338415de5ef7436c92450ddd04e0e6e7df2db3f41387322df97b9

# Platforms whose provider hashes `make lock` writes into the lock file of a root: the Mac that runs plan and apply,
# and the two Linux architectures of CI and of the images.
LOCK_PLATFORMS := darwin_arm64 linux_amd64 linux_arm64

# Directories to check, relative to this one; empty means every directory that holds a *.tf file. A directory under a
# modules/ directory is a module: its lock file is not committed. Any other directory is a root: its committed lock
# file is used as it is (init -lockfile=readonly), so a provider change needs `make lock` first.
DIRS ?=

DOCKER := env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp
# HOME=/tmp: the container runs as the caller, who has no home directory in the image.
TF_RUN = $(DOCKER) -e CHECKPOINT_DISABLE=1 -e TF_IN_AUTOMATION=1 -v "$(CURDIR):/src" -w "/src/$$d"
TF = $(TF_RUN) $(TERRAFORM_IMAGE)
# init, validate and providers lock keep their working data (providers, modules) in a temporary directory of the host,
# $$data, through TF_DATA_DIR: <dir>/.terraform/terraform.tfstate of a root the learner initialised with its S3 backend
# would otherwise make `init -backend=false` configure that backend and ask for AWS credentials.
TF_DATA = $(TF_RUN) -e TF_DATA_DIR=/tfdata -v "$$data:/tfdata" $(TF_CACHE) $(TERRAFORM_IMAGE)
# Starts each loop turn with an empty $$data; the trap removes the last one however the recipe ends.
NEW_DATA = rm -rf "$$data"; data=$$(mktemp -d) || exit 1

# One copy of each plugin version for every directory, gitignored and kept until removed (rm -rf .plugin-cache, plus the
# module lock files aws/modules/**/.terraform.lock.hcl that recorded its hashes); the AWS provider unpacks to hundreds
# of MB. init links $$data/providers to /plugin-cache, so every container that runs Terraform after it mounts the cache.
PLUGIN_CACHE := .plugin-cache
# With no lock file entry (a module's lock file is not committed), init would download again and unpack over the cached
# copy another run may be executing; MAY_BREAK links that copy instead. The hashes of a root's lock file are still
# checked, and make lock still writes them for every LOCK_PLATFORMS.
TF_CACHE = -e TF_PLUGIN_CACHE_DIR=/plugin-cache -e TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=1 \
	-v "$(CURDIR)/$(PLUGIN_CACHE)/terraform:/plugin-cache"
# Neither Terraform nor tflint guards its cache against a second writer: an init waits for the lock directory (mkdir
# is atomic and needs no flock, which macOS lacks). The recipe's EXIT trap runs CACHE_UNLOCKED when the init fails.
CACHE_LOCK = mkdir -p "$(PLUGIN_CACHE)/terraform" "$(PLUGIN_CACHE)/tflint" || exit 1; n=0; \
	until mkdir "$(PLUGIN_CACHE)/lock" 2>/dev/null; do \
	  n=$$((n + 1)); [ $$n -lt 600 ] || { echo "FAIL: $(PLUGIN_CACHE)/lock held for 10 minutes; remove it if no make runs" >&2; exit 1; }; \
	  sleep 1; \
	done; locked=1
CACHE_UNLOCK = rmdir "$(PLUGIN_CACHE)/lock"; locked=
CACHE_UNLOCKED = [ -z "$$locked" ] || rmdir "$(PLUGIN_CACHE)/lock"

# Prints the directories to check, one per line, or stops with the first DIRS entry that is not a Terraform directory
# of this repository.
LIST_DIRS = if [ -z '$(DIRS)' ]; then \
	  find . -name .git -prune -o -name .terraform -prune -o -name '*.tf' -print | sed 's|/[^/]*$$||; s|^\./||' | sort -u; \
	else for d in $(DIRS); do \
	  d=$${d%/}; \
	  case "$$d" in (/*|..|../*|*/..|*/../*) echo "DIRS: $$d is outside this repository; give a path relative to it" >&2; exit 1;; esac; \
	  [ -d "$$d" ] || { echo "DIRS: $$d is not a directory" >&2; exit 1; }; \
	  ls "$$d"/*.tf >/dev/null 2>&1 || { echo "DIRS: $$d holds no *.tf file" >&2; exit 1; }; \
	  echo "$$d"; \
	done; fi

# A directory under modules/ is a module; anything else is a root.
IS_MODULE = case "/$$d/" in (*/modules/*) true;; (*) false;; esac

.DEFAULT_GOAL := help

.PHONY: help check check-terraform check-lint check-test check-scripts hooks pre-commit \
	fmt-check fmt validate tflint tfdocs tfdocs-check trivy shellcheck zizmor docs-check diagrams diagrams-check session-test test-guard test lock \
	github-app-test github-check github-app github-app-key github-settings github-secrets infracost-key github-tfvars \
	github-plan github-apply ci-plan ci-plan-test infracost infracost-comment infracost-test

help: ## List the targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-15s %s\n", $$1, $$2}'

check: check-terraform check-lint check-test check-scripts docs-check diagrams-check ## Every static check (narrow the Terraform ones with DIRS=<dir> ...)

# Each check-* group is one job of .github/workflows/check.yml, and docs-check with diagrams-check is its job docs: a
# target added to a group runs in CI with no change to the workflow. The groups are split by the time they take in CI.
check-terraform: fmt-check validate tfdocs-check ## terraform fmt -check, init and validate, terraform-docs --output-check
check-lint: tflint trivy ## tflint and trivy config
check-test: test-guard test ## terraform test of the modules, and the self-test of its rules
check-scripts: shellcheck zizmor session-test github-app-test ci-plan-test infracost-test ## Scripts and workflows: lint and self-tests

# The pre-commit hook of `make hooks` runs make pre-commit; a hook already there that is not this one is left alone.
# git rev-parse --git-path resolves the hooks directory of a worktree and core.hooksPath. Every worktree of the clone
# shares the hook, so on a branch whose Makefile has no pre-commit target it lets the commit through with a note.
hooks: ## Install the pre-commit hook that runs make pre-commit (once per clone)
	@hook=$$(git rev-parse --git-path hooks/pre-commit) || exit 1; \
	want='#!/bin/sh\n# Installed by make hooks of svp-infra.\n'; \
	want="$$want"'grep -q "^pre-commit:" Makefile 2>/dev/null || { echo "pre-commit hook: no make pre-commit on this branch, nothing checked" >&2; exit 0; }\n'; \
	want="$$want"'exec make --no-print-directory pre-commit\n'; \
	if [ -e "$$hook" ] && [ "$$(cat "$$hook")" != "$$(printf "$$want")" ]; then \
	  echo "FAIL: $$hook exists and is not the hook of make hooks; move it away first" >&2; exit 1; \
	fi; \
	mkdir -p "$$(dirname "$$hook")" && printf "$$want" > "$$hook" && chmod +x "$$hook" && echo "hooks: $$hook runs make pre-commit"

# The staged version of each file, not the working tree's, is copied to a temporary directory and checked there, so a
# change left unstaged neither hides nor causes a failure (-f: .markdownlint.yaml may be one of the files). gitleaks
# reads only the lines the commit adds, as the code repository's hook does: committed test fixtures hold fake keys.
# validate, tflint, trivy and test stay in CI. FILES='<file> ...' checks those working tree files, whole, unstaged.
pre-commit: ## Fast checks of the staged files (or FILES='<file> ...'): terraform fmt, markdownlint, shellcheck, gitleaks
	@tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	if [ -n "$${FILES:-}" ]; then \
	  files=$$FILES; \
	  for f in .markdownlint.yaml $$files; do mkdir -p "$$tmp/$$(dirname "$$f")" && cp "$$f" "$$tmp/$$f" || exit 1; done; \
	  added() { (cd "$$tmp" && cat $$files); }; \
	else \
	  files=$$(git diff --cached --name-only --diff-filter=ACMR) || exit 1; \
	  [ -n "$$files" ] || exit 0; \
	  git checkout-index -f --prefix="$$tmp/" -- .markdownlint.yaml $$files || exit 1; \
	  added() { git diff --cached --no-color --no-ext-diff -U0 --diff-filter=ACMR | grep '^+' | grep -v '^+++ '; }; \
	fi; \
	tf=$$(printf '%s\n' $$files | grep -E '\.(tf|tfvars|tftest\.hcl)$$'); \
	md=$$(printf '%s\n' $$files | grep '\.md$$' | grep -v '^\.claude/'); \
	sh=$$(printf '%s\n' $$files | grep '\.sh$$'); \
	rc=0; \
	[ -z "$$tf" ] || $(DOCKER) --network none -v "$$tmp:/src:ro" -w /src $(TERRAFORM_IMAGE) fmt -check -diff $$tf \
	  || { echo "FAIL: terraform fmt (run make fmt, then stage the result)" >&2; rc=1; }; \
	[ -z "$$md" ] || $(DOCKER) --network none -v "$$tmp:/repo:ro" -w /repo $(MARKDOWNLINT_IMAGE) $$md \
	  || { echo "FAIL: markdownlint" >&2; rc=1; }; \
	[ -z "$$sh" ] || env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$$tmp:/mnt:ro" -w /mnt $(SHELLCHECK_IMAGE) $$sh \
	  || { echo "FAIL: shellcheck" >&2; rc=1; }; \
	added | $(DOCKER) -i --network none $(GITLEAKS_IMAGE) stdin --redact --verbose --no-banner --no-color --log-level warn \
	  || { echo "FAIL: gitleaks found a secret in the lines checked (staged: git diff --cached shows them)" >&2; rc=1; }; \
	exit $$rc

fmt-check: ## terraform fmt -check on the checked directories
	@dirs=$$($(LIST_DIRS)) || exit 1; [ -n "$$dirs" ] || { echo "fmt-check: no Terraform directory"; exit 0; }; \
	for d in $$dirs; do \
	  echo "fmt-check $$d"; \
	  $(TF) fmt -check -diff -recursive || { echo "FAIL: terraform fmt $$d (run make fmt DIRS=$$d)" >&2; exit 1; }; \
	done

fmt: ## terraform fmt, rewriting the files of the checked directories
	@dirs=$$($(LIST_DIRS)) || exit 1; for d in $$dirs; do $(TF) fmt -recursive || exit 1; done

validate: ## terraform init -backend=false, then terraform validate, in each checked directory
	@dirs=$$($(LIST_DIRS)) || exit 1; [ -n "$$dirs" ] || { echo "validate: no Terraform directory"; exit 0; }; \
	data=; locked=; trap 'rm -rf "$$data"; $(CACHE_UNLOCKED)' EXIT; \
	for d in $$dirs; do \
	  echo "validate $$d"; \
	  $(NEW_DATA); \
	  if $(IS_MODULE); then lock=; \
	  else \
	    [ -f "$$d/.terraform.lock.hcl" ] || { echo "FAIL: $$d is a root without .terraform.lock.hcl (run make lock DIRS=$$d)" >&2; exit 1; }; \
	    lock=-lockfile=readonly; \
	  fi; \
	  $(CACHE_LOCK); \
	  $(TF_DATA) init -backend=false -input=false -no-color $$lock >/dev/null || { echo "FAIL: terraform init $$d" >&2; exit 1; }; \
	  $(CACHE_UNLOCK); \
	  $(TF_DATA) validate -no-color || { echo "FAIL: terraform validate $$d" >&2; exit 1; }; \
	done

# The AWS ruleset is downloaded from GitHub into the plugin cache; CI passes its token in GITHUB_TOKEN against
# the anonymous rate limit, and only this container gets it. Local modules are inspected where they are called.
tflint: ## tflint --init, then tflint, in each checked directory (.tflint.hcl)
	@dirs=$$($(LIST_DIRS)) || exit 1; [ -n "$$dirs" ] || { echo "tflint: no Terraform directory"; exit 0; }; \
	locked=; trap '$(CACHE_UNLOCKED)' EXIT; \
	for d in $$dirs; do \
	  echo "tflint $$d"; \
	  set -- $(DOCKER) -e GITHUB_TOKEN -e "TFLINT_PLUGIN_DIR=/src/$(PLUGIN_CACHE)/tflint" -v "$(CURDIR):/src" -w "/src/$$d" \
	    $(TFLINT_IMAGE) --config=/src/.tflint.hcl; \
	  $(CACHE_LOCK); \
	  "$$@" --init >/dev/null || { echo "FAIL: tflint --init $$d" >&2; exit 1; }; \
	  $(CACHE_UNLOCK); \
	  "$$@" --format=compact || { echo "FAIL: tflint $$d" >&2; exit 1; }; \
	done

# terraform-docs reads the .tf files of a module and never runs Terraform, a provider or the network. Roots have no
# generated docs: their directories are skipped.
tfdocs: ## terraform-docs, rewriting the generated block of the README of each checked module
	@dirs=$$($(LIST_DIRS)) || exit 1; \
	for d in $$dirs; do \
	  $(IS_MODULE) || continue; \
	  echo "tfdocs $$d"; \
	  $(DOCKER) --network none -v "$(CURDIR):/src" -w /src $(TFDOCS_IMAGE) --config /src/.terraform-docs.yml "$$d" || { echo "FAIL: terraform-docs $$d" >&2; exit 1; }; \
	done

tfdocs-check: ## terraform-docs --output-check: fails when the generated block of a module README is out of date (run make tfdocs)
	@dirs=$$($(LIST_DIRS)) || exit 1; \
	for d in $$dirs; do \
	  $(IS_MODULE) || continue; \
	  echo "tfdocs-check $$d"; \
	  $(DOCKER) --network none -v "$(CURDIR):/src:ro" -w /src $(TFDOCS_IMAGE) --config /src/.terraform-docs.yml --output-check "$$d" || { echo "FAIL: README of $$d is out of date (run make tfdocs DIRS=$$d)" >&2; exit 1; }; \
	done

# Findings of severity HIGH or CRITICAL fail; deliberate exceptions are in .trivyignore.yaml, each with its reason.
# --skip-dirs leaves out the examples/ that registry modules ship (manifests and sample roots Terraform never applies).
# --skip-check-update keeps the checks built into the pinned image: the bundle trivy would fetch sits behind a moving
# tag, so new rules could turn the required check red on unchanged code, or drop a rule without anyone noticing.

# Registry modules are downloaded by trivy itself and scanned with the configuration that calls them. A root is scanned
# with the values its env runs with (<dir>/<last part of dir>.tfvars to --tf-vars), so an exception that holds for one
# env only never hides a finding of another env. A module, or a root without such a file, gets the defaults.
trivy: ## trivy config on each checked directory (HIGH and CRITICAL fail; a root gets its <env>.tfvars)
	@dirs=$$($(LIST_DIRS)) || exit 1; [ -n "$$dirs" ] || { echo "trivy: no Terraform directory"; exit 0; }; \
	for d in $$dirs; do \
	  vars="$$d/$${d##*/}.tfvars"; \
	  if [ -f "$$vars" ]; then echo "trivy $$d ($$vars)"; set -- --tf-vars "$$vars"; else echo "trivy $$d"; set --; fi; \
	  $(DOCKER) -v "$(CURDIR):/src:ro" -w /src $(TRIVY_IMAGE) config --quiet --skip-check-update --skip-dirs '**/.terraform/modules/**/examples' --cache-dir /tmp/trivy \
	    --ignorefile .trivyignore.yaml --severity HIGH,CRITICAL --exit-code 1 "$$@" "$$d" || { echo "FAIL: trivy $$d" >&2; exit 1; }; \
	done

shellcheck: ## shellcheck on every *.sh of the repository, or on the files of SH='<file> ...'
	@files="$${SH:-}"; [ -n "$$files" ] || files=$$(find . -name .git -prune -o -name .terraform -prune -o -name '*.sh' -type f -print | sort); \
	[ -n "$$files" ] || { echo "shellcheck: no shell script"; exit 0; }; \
	echo "shellcheck $$(echo $$files | wc -w | tr -d ' ') files"; \
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$(CURDIR):/mnt:ro" -w /mnt $(SHELLCHECK_IMAGE) $$files

# Security lint of the workflows: zizmor with the regular persona. Every finding fails; the deliberate ones are left out
# in .github/zizmor.yml, each with its reason. With GH_TOKEN set (CI passes the job's read-only token) the online audits
# run too (impostor commits, actions with known vulnerabilities); without it, offline audits only.
# ZIZMOR_FORMAT=github writes workflow commands (annotations in CI).
ZIZMOR_FORMAT ?= plain
zizmor: ## Security lint of the workflows with the pinned zizmor (online audits with GH_TOKEN; ZIZMOR_FORMAT=github)
	@echo "zizmor .github"; \
	if [ -n "$${GH_TOKEN:-}" ]; then net="--env=GH_TOKEN"; else net="--env=ZIZMOR_OFFLINE=true --network=none"; fi; \
	$(DOCKER) $$net -v "$(CURDIR):/src:ro" -w /src $(ZIZMOR_IMAGE) --persona=regular --no-progress --color=never \
	  --cache-dir /tmp/zizmor --format='$(ZIZMOR_FORMAT)' . || { echo "FAIL: zizmor" >&2; exit 1; }

# Markdown check: markdownlint-cli2 with .markdownlint.yaml (style), then lychee --offline --include-fragments (relative
# links and heading anchors). Links to other sites are not followed: a check that depends on the network fails for
# reasons outside the change. A relative link that leaves the repository is an error on purpose.

# The default for DOCS is every Markdown file git tracks plus the new ones it does not track yet, except under
# .claude/: that is configuration of a coding agent, whose files follow the agent's own format, not documentation.

# set -f keeps the globs of DOCS whole: the tools expand them (with **), sh does not and would drop the files at the top.
DOCS ?=
docs-check: ## markdownlint-cli2 + lychee --offline on the Markdown (DOCS='<files or globs>' narrows; no network)
	@if [ -n '$(DOCS)' ]; then set -f; set -- $(DOCS); set +f; \
	else set --; for f in $$(git ls-files --cached --others --exclude-standard -- '*.md' ':!:.claude/'); do [ -f "$$f" ] && set -- "$$@" "$$f"; done; fi; \
	echo "docs-check $$# files"; \
	rc=0; \
	$(DOCKER) --network none -v "$(CURDIR):/repo:ro" -w /repo $(MARKDOWNLINT_IMAGE) "$$@" || rc=1; \
	$(DOCKER) --network none -v "$(CURDIR):/repo:ro" -w /repo $(LYCHEE_IMAGE) --offline --include-fragments "$$@" || rc=1; \
	[ $$rc = 0 ] || echo "FAIL: docs-check" >&2; \
	exit $$rc

# docs/diagrams/<name>.d2 is the source, <name>.svg is generated; tokens.d2 holds shared classes. Engine and both themes
# come from d2-config in each file. NAMES='<name …>' limits both targets (parallel edits never rewrite another SVG);
# LAYOUT overrides the engine, OUT=<dir in repo> writes elsewhere, SUFFIX renames, PNG=1 adds a PNG to look at.
DIAGRAMS_DIR := docs/diagrams
NAMES ?=
OUT ?=
SUFFIX ?=
LAYOUT ?=
PNG ?=

# Renders every diagram into $$out with $$layout, $$suffix and $$png set by the caller; a diagram without a dark theme
# is an error, since the SVG would show a white box on a dark page. The container has no network.
D2_RENDER = \
	for f in $$srcs; do \
	  n=$$(basename "$$f" .d2); echo "d2 $$n"; \
	  for ext in svg $$png; do \
	    msg=$$($(DOCKER) --network none --entrypoint d2 -v "$(CURDIR)/$(DIAGRAMS_DIR):/work:ro" -v "$$out:/out" -w /work \
	      $(D2_IMAGE) $$layout "$$n.d2" "/out/$$n$$suffix.$$ext" 2>&1) || { echo "$$msg" >&2; echo "FAIL: d2 $$f" >&2; exit 1; }; \
	  done; \
	  grep -q prefers-color-scheme "$$out/$$n$$suffix.svg" || { echo "FAIL: $$f has no dark theme (dark-theme-id in d2-config)" >&2; exit 1; }; \
	done

diagrams: ## D2 to SVG (light and dark in one file) of docs/diagrams/*.d2 (NAMES=, LAYOUT=, OUT=<dir>, SUFFIX=, PNG=1)
	@srcs=$$(if [ -n "$(NAMES)" ]; then for n in $(NAMES); do echo "$(DIAGRAMS_DIR)/$$n.d2"; done; \
	  else ls $(DIAGRAMS_DIR)/*.d2 2>/dev/null | grep -v '/tokens\.d2$$'; fi); [ -n "$$srcs" ] || { echo "diagrams: no .d2 file"; exit 0; }; \
	dir=$${OUT:-$(DIAGRAMS_DIR)}; \
	case "$$dir" in (/*|..|../*|*/..|*/../*) echo "OUT: $$dir is outside this repository; give a path relative to it" >&2; exit 1;; esac; \
	case "$$SUFFIX" in (*/*) echo "SUFFIX: no slash in a file name" >&2; exit 1;; esac; \
	mkdir -p "$$dir" && out=$$(cd "$$dir" && pwd) || exit 1; \
	layout=; [ -z "$$LAYOUT" ] || layout="--layout=$$LAYOUT"; suffix=$$SUFFIX; png=; [ -z "$$PNG" ] || png=png; \
	$(D2_RENDER)

diagrams-check: ## Fails, naming the file, when a committed SVG differs from what its .d2 renders to or has no .d2
	@srcs=$$(if [ -n "$(NAMES)" ]; then for n in $(NAMES); do echo "$(DIAGRAMS_DIR)/$$n.d2"; done; \
	  else ls $(DIAGRAMS_DIR)/*.d2 2>/dev/null | grep -v '/tokens\.d2$$'; fi); [ -n "$$srcs" ] || { echo "diagrams-check: no .d2 file"; exit 0; }; \
	out=$$(mktemp -d) || exit 1; trap 'rm -rf "$$out"' EXIT; layout=; suffix=; png=; \
	$(D2_RENDER); rc=0; \
	for f in $$srcs; do \
	  svg="$(DIAGRAMS_DIR)/$$(basename "$$f" .d2).svg"; \
	  cmp -s "$$out/$$(basename "$$svg")" "$$svg" || { echo "FAIL: $$svg is out of date or missing (run make diagrams)" >&2; rc=1; }; \
	done; \
	[ -n "$(NAMES)" ] || for svg in $(DIAGRAMS_DIR)/*.svg; do \
	  [ ! -f "$$svg" ] || [ -f "$${svg%.svg}.d2" ] || { echo "FAIL: $$svg has no .d2 source (restore it, or drop the SVG)" >&2; rc=1; }; \
	done; exit $$rc

# The session scripts reach the AWS account and the cluster when the learner runs them; their self-test puts fake aws,
# kubectl, helm, terraform, make and dig first on PATH, so it reaches nothing. Only its FAIL lines are printed.
# GitHub settings the github provider cannot manage (README of github/, table "Không quản"): Apps registered from their
# manifest in github/apps/, and a read-only check of the rest. Python's standard library and gh, no container.
github-app-test: ## Unit tests of github/scripts/github-app.py (no network, gh or account) and its check of the manifests
	@echo "github-app-test"; python3 -I -B -m unittest discover -s github/scripts -p '*_test.py' 2>&1 | tail -3 | \
	  grep -q '^OK' || { echo "FAIL: github-app-test (python3 -B -m unittest discover -s github/scripts -p '*_test.py')" >&2; exit 1; }

github-check: ## Read-only check of the GitHub settings Terraform does not manage (gh signed in; WITH_APP_KEYS=1 also reads App installations)
	@python3 -I -B github/scripts/github-app.py check $(if $(WITH_APP_KEYS),--with-app-keys)

github-app: ## Register GitHub App APP=<name> from github/apps/<name>.json and write its key and client ID (the account owner runs it)
	@test -n '$(APP)' || { echo "make github-app: set APP=<name> (github/apps/<name>.json)" >&2; exit 1; }; \
	python3 -I -B github/scripts/github-app.py create '$(APP)'

github-app-key: ## Write PEM=<file> as key KEY=<stg|prd|local> of App APP=<name> (github/apps/destinations.json), then delete the file
	@test -n '$(APP)' -a -n '$(KEY)' -a -n '$(PEM)' || { echo "make github-app-key: set APP, KEY and PEM" >&2; exit 1; }; \
	python3 -I -B github/scripts/github-app.py set-key '$(APP)' '$(KEY)' '$(PEM)'

# The writes below are the account owner's: each reads the setting first and writes only what differs. Secret values
# go to gh on stdin; ENV reaches the script through the environment, never through the recipe's text.
github-settings: ## Fork PR approval, private vulnerability reporting, CodeQL default setup: read, write only what differs
	@python3 -I -B github/scripts/github-app.py settings

github-secrets: ## Secrets SVP_AWS_STG/PRD_ACCOUNT_ID of the ECR repos; ENV=<stg|prd>: secrets of environment terraform-plan
	@python3 -I -B github/scripts/github-app.py secrets "$${ENV:-}"

infracost-key: ## Secret INFRACOST_API_KEY of svp-infra from stdin (pbpaste | make infracost-key) or the infracost CLI login
	@python3 -I -B github/scripts/github-app.py infracost-key

github-tfvars: ## Write github/github.auto.tfvars (mode 600) from the Actions variables on GitHub, values checked first
	@python3 -I -B github/scripts/github-app.py tfvars

github-plan: ## terraform init and plan of github/ into github/github.tfplan (anhnv-sso, account checked; token from gh)
	@python3 -I -B github/scripts/github-app.py plan

github-apply: ## Apply github/github.tfplan alone, delete it, then plan again expecting No changes.
	@python3 -I -B github/scripts/github-app.py apply

session-test: ## Self-tests of aws/scripts (session-test.sh, then every other *-test.sh) with fake commands, no account or network
	@echo "session-test aws/scripts"; rc=0; \
	for f in aws/scripts/session-test.sh $$(ls aws/scripts/*-test.sh 2>/dev/null | grep -v '/session-test\.sh$$'); do \
	  bash "$$f" >/dev/null || { echo "FAIL: $$f (bash $$f prints every check)" >&2; rc=1; }; \
	done; exit $$rc

# terraform plan of a pull request, for job plan of .github/workflows/plan.yml alone: the script reaches the account of
# ENV with the job's OIDC token, so it refuses to run outside GitHub Actions. ENV reaches it through the environment,
# never through the recipe's text. Its self-test puts fake docker, curl and gh first on PATH.
ci-plan: ## terraform plan of the roots of ENV=<stg|prd> for plan.yml (GitHub Actions only: refuses anywhere else)
	@TERRAFORM_IMAGE='$(TERRAFORM_IMAGE)' bash ci/terraform-plan.sh plan "$${ENV:-}"

ci-plan-test: ## Self-test of ci/terraform-plan.sh with fake docker, curl and gh (no container, account, token or network)
	@echo "ci-plan-test"; \
	bash ci/terraform-plan-test.sh >/dev/null || { echo "FAIL: ci-plan-test (bash ci/terraform-plan-test.sh prints every check)" >&2; exit 1; }

# Cost estimate of a pull request for .github/workflows/cost.yml, from the HCL of the roots in infracost.yml: no plan,
# state or AWS credential. It needs the learner's free key in INFRACOST_API_KEY, which reaches the container by name
# alone; BASE reaches the script through the environment, never through the recipe's text.
infracost: ## Infracost of BASE=<base tree> and of this tree, then their diff (needs INFRACOST_API_KEY)
	@INFRACOST_IMAGE='$(INFRACOST_IMAGE)' bash ci/infracost.sh estimate "$${BASE:-}"

infracost-comment: ## Post the diff of make infracost to pull request PR of REPO (cost.yml; needs INFRACOST_API_KEY, GITHUB_TOKEN)
	@INFRACOST_IMAGE='$(INFRACOST_IMAGE)' bash ci/infracost.sh comment

infracost-test: ## Self-test of ci/infracost.sh with a fake docker (no container, key, token or network)
	@echo "infracost-test"; \
	bash ci/infracost-test.sh >/dev/null || { echo "FAIL: infracost-test (bash ci/infracost-test.sh prints every check)" >&2; exit 1; }

# terraform test of each module (tests/*.tftest.hcl). The recipe holds the tests to three rules itself instead of
# trusting whoever wrote them: terraform runs from TERRAFORM_IMAGE, pinned by digest, with --network none (only init,
# in a container of its own, downloads providers and registry modules); no credential goes in; TEST_GUARD accepts a
# test file only in a fixed layout.

# No credential: env(1) drops every AWS_* variable of the caller before docker starts, no -e passes one, HOME is /tmp
# of the container, and only the module directory and the provider cache are mounted (both read-only for the test),
# never ~/.aws, the repository root or an env directory. A module directory holding .envrc or backend.hcl is refused.

# TEST_GUARD refuses anything outside the layout, naming the file and the line, rather than looking for known ways to
# break the rule (a run without command applies; a mock under an alias leaves the real provider as the default).
# Block comments and heredocs are refused so that every line is read here as HCL reads it.
NO_AWS_ENV = env $$(env | sed -n 's/^\(AWS_[A-Za-z0-9_]*\)=.*/-u \1/p') -u DOCKER_DEFAULT_PLATFORM
TEST_RUN = $(NO_AWS_ENV) docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp -e CHECKPOINT_DISABLE=1 \
	-e TF_IN_AUTOMATION=1 -e TF_DATA_DIR=/tfdata -v "$$data:/tfdata"
# Checks the module directory $$d and exits the recipe, naming the file (and the line), at the first one it refuses.
# The awk program reads each line with its leading and trailing blanks removed; run holds the line of the run block
# whose command line is still due.
TEST_GUARD = \
	links=$$(find "$$d" -name .terraform -prune -o -type l -print); \
	[ -z "$$links" ] || { echo "FAIL: make test refuses the symbolic links $$links (terraform test would read a file these checks never see)" >&2; exit 1; }; \
	files=$$(find "$$d" "$$d/tests" -maxdepth 1 -name '*.tftest.hcl' 2>/dev/null | sort -u); \
	[ -n "$$files" ] || { echo "FAIL: $$d/tests holds no *.tftest.hcl (every module tests its validation rules)" >&2; exit 1; }; \
	bad=$$(find "$$d" -name .terraform -prune -o \( -name '*.tftest.json' -o -name .envrc -o -name backend.hcl \) -print); \
	[ -z "$$bad" ] || { echo "FAIL: make test refuses $$bad (only *.tftest.hcl it can check; no credential file in a tested module)" >&2; exit 1; }; \
	for f in $$files; do \
	  awk -v f="$$f" ' \
	    { line = $$0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$$/, "", line) } \
	    /alias/ { print f ":" NR ": alias (the default aws provider must be the mock)"; bad = 1 } \
	    /\*\// { print f ":" NR ": block comment"; bad = 1 } \
	    /<</ { print f ":" NR ": heredoc"; bad = 1 } \
	    run && line != "" { if (line != "command = plan") { print f ":" NR ": the run block of line " run " does not start with command = plan"; bad = 1 }; run = 0; next } \
	    line ~ /^run/ { if (line ~ /^run "[A-Za-z0-9_-]+" [{]$$/) run = NR; else { print f ":" NR ": not a run \"<name>\" { line"; bad = 1 }; next } \
	    line ~ /^mock_provider/ { if (line == "mock_provider \"aws\" {" || line == "mock_provider \"aws\" {}") mocks++; else { print f ":" NR ": not a mock_provider \"aws\" { line"; bad = 1 }; next } \
	    line ~ /^(provider|override_|module|command|\/\*)/ { print f ":" NR ": provider, override_*, module, block comment or command outside the first line of a run"; bad = 1 } \
	    END { \
	      if (run) { print f ":" run ": run block without command = plan"; bad = 1 } \
	      if (mocks != 1) { print f ": " (mocks + 0) " mock_provider \"aws\" lines, exactly one allowed"; bad = 1 } \
	      exit bad \
	    }' "$$f" >&2 || { echo "FAIL: make test refuses $$f" >&2; exit 1; }; \
	done

test: ## terraform test of each checked module: mock AWS provider, plan only, no network, no credential
	@dirs=$$($(LIST_DIRS)) || exit 1; [ -n "$$dirs" ] || { echo "test: no Terraform directory"; exit 0; }; \
	data=; locked=; trap 'rm -rf "$$data"; $(CACHE_UNLOCKED)' EXIT; \
	for d in $$dirs; do \
	  $(IS_MODULE) || continue; \
	  echo "test $$d"; \
	  $(TEST_GUARD); \
	  $(NEW_DATA); \
	  $(CACHE_LOCK); \
	  $(TEST_RUN) $(TF_CACHE) -v "$(CURDIR)/$$d:/src" -w /src $(TERRAFORM_IMAGE) init -backend=false -input=false -no-color >/dev/null || { echo "FAIL: terraform init $$d" >&2; exit 1; }; \
	  $(CACHE_UNLOCK); \
	  $(TEST_RUN) --network none -v "$(CURDIR)/$(PLUGIN_CACHE)/terraform:/plugin-cache:ro" -v "$(CURDIR)/$$d:/src:ro" -w /src $(TERRAFORM_IMAGE) test -no-color || { echo "FAIL: terraform test $$d" >&2; exit 1; }; \
	done

test-guard: ## Self-test of the rules of make test, with a fake docker (no container, network or credential)
	@echo "test-guard"; \
	tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	fail() { echo "FAIL: test-guard: $$*" >&2; exit 1; }; \
	good='mock_provider "aws" {}\nrun "a" {\n  command = plan\n}\n'; \
	full='# c\nmock_provider "aws" {\n  mock_data "aws_region" {\n    defaults = {\n      region = "x"\n    }\n  }\n}\n\nrun "a-1_b" {\n\n  command = plan\n\n  variables {\n    u = ["https://svp.example/*"]\n  }\n\n  expect_failures = [var.u]\n}\n'; \
	newmod() { rm -rf "$$tmp/m" "$$tmp/t"; mkdir -p "$$tmp/m/tests"; d="$$tmp/m"; }; \
	refuses() { \
	  out=$$( ( $(TEST_GUARD) ) 2>&1 ) && fail "$$1: accepted"; \
	  case "$$out" in (*"$$d/$$2"*) ;; (*) fail "$$1: the refusal does not name $$d/$$2: $$out";; esac; \
	}; \
	refused() { \
	  newmod; \
	  if [ -n "$$2" ]; then printf "$$2" > "$$d/tests/$$3"; fi; \
	  if [ -n "$$4" ]; then : > "$$d/$$4"; fi; \
	  refuses "$$1" "$${5:-}"; \
	}; \
	refused "no test file" "" "" ""; \
	refused "no mock_provider" 'run "a" {\n  command = plan\n}\n' a.tftest.hcl ""; \
	refused "two mock_provider" 'mock_provider "aws" {}\nmock_provider "aws" {}\nrun "a" {\n  command = plan\n}\n' a.tftest.hcl ""; \
	refused "run without command" 'mock_provider "aws" {}\nrun "a" {}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "run without command, on several lines" 'mock_provider "aws" {}\nrun "a" {\n  variables {\n    x = 1\n  }\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:3:; \
	refused "command after other lines" 'mock_provider "aws" {}\nrun "a" {\n  variables {\n    x = 1\n  }\n  command = plan\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:3:; \
	refused "command = apply" 'mock_provider "aws" {}\nrun "a" {\n  command = apply\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:3:; \
	refused "one-line run" 'mock_provider "aws" {}\nrun "a" { command = plan }\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "run label without quotes" 'mock_provider "aws" {}\nrun implicit_apply {}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "run x{" 'mock_provider "aws" {}\nrun x{\n  command = plan\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "run  \"a\"{command=apply}" 'mock_provider "aws" {}\nrun  "a"{command=apply}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "provider block" 'mock_provider "aws" {}\nprovider "aws" {}\nrun "a" {\n  command = plan\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "providers of a run" 'mock_provider "aws" {}\nrun "a" {\n  command = plan\n  providers = {\n    aws = aws\n  }\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:4:; \
	refused "module of a run" 'mock_provider "aws" {}\nrun "a" {\n  command = plan\n  module {\n    source = "../x"\n  }\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:4:; \
	refused "override_" 'mock_provider "aws" {}\noverride_data {\n  target = data.aws_region.this\n}\nrun "a" {\n  command = plan\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "aliased mock" 'mock_provider "aws" {\n  alias = "x"\n}\nrun "a" {\n  command = plan\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "one-line aliased mock" 'mock_provider "aws" { alias = "x" }\nrun "a" {\n  command = plan\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:1:; \
	refused "block comment" 'mock_provider "aws" {}\n/*\nrun "x" {}\n*/\nrun "a" {\n  command = plan\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "block comment closed on a comment line" 'run "a" {\n  command = plan\n  variables {\n    x = 1 /*\nmock_provider "aws" {}\n# */\n  }\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:6:; \
	refused "heredoc" 'run "a" {\n  command = plan\n  variables {\n    x = <<EOT\nmock_provider "aws" {\nEOT\n  }\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:4:; \
	refused "tftest.json" "$$good" a.tftest.hcl tests/a.tftest.json tests/a.tftest.json; \
	refused ".envrc" "$$good" a.tftest.hcl .envrc; \
	refused "backend.hcl" "$$good" a.tftest.hcl backend.hcl; \
	newmod; printf "$$good" > "$$d/tests/a.tftest.hcl"; mkdir "$$d/fixtures"; printf 'run "x" {}\n' > "$$d/fixtures/u.hcl"; \
	ln -s ../fixtures/u.hcl "$$d/tests/b.tftest.hcl"; refuses "symbolic link to a test file" tests/b.tftest.hcl; \
	newmod; mkdir "$$tmp/t"; printf "$$good" > "$$tmp/t/a.tftest.hcl"; rmdir "$$d/tests"; ln -s ../t "$$d/tests"; \
	refuses "symbolic link to the tests directory" tests; \
	newmod; printf "$$good" > "$$d/tests/a.tftest.hcl"; ( $(TEST_GUARD) ) || fail "a valid test file was refused"; \
	newmod; printf "$$full" > "$$d/tests/a.tftest.hcl"; ( $(TEST_GUARD) ) || fail "a valid test file with comments, mock_data and blank lines was refused"; \
	mkdir "$$tmp/bin"; \
	printf '#!/bin/sh\n{ printf ARGS; for a in "$$@"; do printf " %%s" "$$a"; done; echo; env | sed -n "s/^AWS_/ENV AWS_/p"; } >> "$$FAKE_DOCKER_LOG"\n' > "$$tmp/bin/docker"; \
	chmod +x "$$tmp/bin/docker"; \
	[ "$$(PATH="$$tmp/bin:$$PATH" command -v docker)" = "$$tmp/bin/docker" ] || fail "the fake docker is not first on PATH; nothing was run"; \
	PATH="$$tmp/bin:$$PATH" FAKE_DOCKER_LOG="$$tmp/log" AWS_PROFILE=leak AWS_ACCESS_KEY_ID=leak AWS_SECRET_ACCESS_KEY=leak \
	  AWS_SESSION_TOKEN=leak $(MAKE) --no-print-directory test DIRS=aws/modules/rds >/dev/null || fail "make test with the fake docker failed"; \
	[ "$$(grep -c '^ARGS run ' "$$tmp/log")" = 2 ] || fail "expected two docker runs (init, test): $$(cat "$$tmp/log")"; \
	! grep -q '^ENV ' "$$tmp/log" || fail "an AWS_* variable reached docker: $$(grep '^ENV ' "$$tmp/log")"; \
	! grep -E -q 'AWS_|/\.aws|\.envrc|backend\.hcl' "$$tmp/log" || fail "an AWS credential or env file reaches the container: $$(cat "$$tmp/log")"; \
	line=$$(grep ' test -no-color$$' "$$tmp/log") || fail "no terraform test run: $$(cat "$$tmp/log")"; \
	case "$$line" in (*" --network none "*) ;; (*) fail "terraform test runs with network: $$line";; esac; \
	mounts=$$(echo "$$line" | awk '{ for (i = 1; i <= NF; i++) \
	  if ($$i == "-v") print $$(++i); else if ($$i ~ /^(-v.|--volume|--mount)/) print $$i }'); \
	data=$$(echo "$$mounts" | sed -n 's|^\(/[^:]*\):/tfdata$$|\1|p'); \
	[ -n "$$data" ] && [ ! -e "$$data" ] && case "$$data" in (*/..*) false;; esac \
	  || fail "terraform test mounts at /tfdata what make test does not remove: $$line"; \
	mounts=$$(echo "$$mounts" | sed 's|^/[^:]*:/tfdata$$|DATA|' | sort | tr '\n' ' '); \
	want=$$(printf '%s\n' DATA "$(CURDIR)/$(PLUGIN_CACHE)/terraform:/plugin-cache:ro" "$(CURDIR)/aws/modules/rds:/src:ro" | sort | tr '\n' ' '); \
	[ "$$mounts" = "$$want" ] || fail "terraform test mounts more than its data directory, the module and the provider cache (read-only): $$line"; \
	case "$$line" in (*" $(TERRAFORM_IMAGE) "*) ;; (*) fail "terraform test does not run TERRAFORM_IMAGE: $$line";; esac; \
	case "$(TERRAFORM_IMAGE)" in (*@sha256:*) ;; (*) fail "TERRAFORM_IMAGE is not pinned by digest";; esac

lock: ## Write the lock file of each root in DIRS (default: every root) with hashes for LOCK_PLATFORMS
	@dirs=$$($(LIST_DIRS)) || exit 1; \
	data=; locked=; trap 'rm -rf "$$data"; $(CACHE_UNLOCKED)' EXIT; \
	for d in $$dirs; do \
	  if $(IS_MODULE); then echo "lock: $$d is a module, its lock file is not committed; skipped"; continue; fi; \
	  echo "lock $$d"; \
	  $(NEW_DATA); \
	  $(CACHE_LOCK); \
	  $(TF_DATA) init -backend=false -input=false -no-color >/dev/null || { echo "FAIL: terraform init $$d" >&2; exit 1; }; \
	  $(CACHE_UNLOCK); \
	  $(TF_DATA) providers lock -no-color $(addprefix -platform=,$(LOCK_PLATFORMS)) || { echo "FAIL: providers lock $$d" >&2; exit 1; }; \
	done
