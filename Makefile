# Static checks of the Terraform of this repository. `make help` lists the targets.
#
# No target here reaches an AWS account: init always runs with -backend=false, nothing calls apply or the AWS CLI, and the
# only plans are those of terraform test (make test), against a mock AWS provider, in a container without network or
# credentials. Every tool runs from its official image pinned by digest, the same reference on a dev machine and in CI, so
# nothing is installed and no setup action is trusted; session-test alone runs on the host, as it needs only bash, git
# and jq, which the Mac and the CI runner both have. Docker runs with DOCKER_DEFAULT_PLATFORM unset: the shell of the
# dev machine sets it to linux/amd64 for another project, which would run these images under emulation.
#
# Parallel runs: `make check DIRS=<dir>` writes only below <dir> (.terraform/tflint.d with the tflint plugins, and the
# .terraform.lock.hcl of a module); init and validate keep providers and modules in a temporary directory that nothing
# else shares and the recipe removes, so a .terraform/ the learner made with a backend is never read or written; trivy's
# and zizmor's caches stay inside their containers, and session-test writes only in a temporary directory of its own,
# which it removes. No plugin cache is shared between directories, so two runs on two different directories never write
# the same file.

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
TF_DATA = $(TF_RUN) -e TF_DATA_DIR=/tfdata -v "$$data:/tfdata" $(TERRAFORM_IMAGE)
# Starts each loop turn with an empty $$data; the trap removes the last one however the recipe ends.
NEW_DATA = rm -rf "$$data"; data=$$(mktemp -d) || exit 1

# Prints the directories to check, one per line, or stops with the first DIRS entry that is not a Terraform directory
# of this repository. Recipes read the list with `dirs=$$($(LIST_DIRS)) || exit 1`.
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

.PHONY: help check fmt-check fmt validate tflint tfdocs tfdocs-check trivy shellcheck zizmor docs-check session-test test-guard test lock \
	github-app-test github-check github-app github-app-key

help: ## List the targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-11s %s\n", $$1, $$2}'

check: fmt-check validate tflint tfdocs-check trivy shellcheck zizmor docs-check session-test test-guard test github-app-test ## Every static check (narrow the Terraform ones with DIRS=<dir> ...)

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
	data=; trap 'rm -rf "$$data"' EXIT; \
	for d in $$dirs; do \
	  echo "validate $$d"; \
	  $(NEW_DATA); \
	  if $(IS_MODULE); then lock=; \
	  else \
	    [ -f "$$d/.terraform.lock.hcl" ] || { echo "FAIL: $$d is a root without .terraform.lock.hcl (run make lock DIRS=$$d)" >&2; exit 1; }; \
	    lock=-lockfile=readonly; \
	  fi; \
	  $(TF_DATA) init -backend=false -input=false -no-color $$lock >/dev/null || { echo "FAIL: terraform init $$d" >&2; exit 1; }; \
	  $(TF_DATA) validate -no-color || { echo "FAIL: terraform validate $$d" >&2; exit 1; }; \
	done

# The AWS ruleset is downloaded from GitHub into <dir>/.terraform/tflint.d/; CI passes its token in GITHUB_TOKEN against
# the anonymous rate limit, and only this container gets it. Local modules are inspected where they are called.
tflint: ## tflint --init, then tflint, in each checked directory (.tflint.hcl)
	@dirs=$$($(LIST_DIRS)) || exit 1; [ -n "$$dirs" ] || { echo "tflint: no Terraform directory"; exit 0; }; \
	for d in $$dirs; do \
	  echo "tflint $$d"; \
	  set -- $(DOCKER) -e GITHUB_TOKEN -e "TFLINT_PLUGIN_DIR=/src/$$d/.terraform/tflint.d" -v "$(CURDIR):/src" -w "/src/$$d" \
	    $(TFLINT_IMAGE) --config=/src/.tflint.hcl; \
	  "$$@" --init >/dev/null || { echo "FAIL: tflint --init $$d" >&2; exit 1; }; \
	  "$$@" --format=compact || { echo "FAIL: tflint $$d" >&2; exit 1; }; \
	done

# terraform-docs reads the .tf files of a module and never runs Terraform, a provider or the network. tfdocs rewrites the
# block between the markers of <module>/README.md; tfdocs-check mounts the repository read-only and fails when a README
# differs from what the .tf files say. Roots have no generated docs: their directories are skipped.
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
# --skip-dirs leaves out the examples/ that registry modules ship (Kubernetes manifests and sample roots Terraform never
# applies), wherever the module is called from, so no exception has to repeat per root.
# --skip-check-update keeps the checks built into the pinned image: the bundle trivy would fetch otherwise sits behind a
# moving tag, so new rules could turn the required check red on unchanged code, or drop a rule without anyone noticing.
# Registry modules are downloaded by trivy itself and scanned with the configuration that calls them.
trivy: ## trivy config on each checked directory (HIGH and CRITICAL fail)
	@dirs=$$($(LIST_DIRS)) || exit 1; [ -n "$$dirs" ] || { echo "trivy: no Terraform directory"; exit 0; }; \
	for d in $$dirs; do \
	  echo "trivy $$d"; \
	  $(DOCKER) -v "$(CURDIR):/src:ro" -w /src $(TRIVY_IMAGE) config --quiet --skip-check-update --skip-dirs '**/.terraform/modules/**/examples' --cache-dir /tmp/trivy \
	    --ignorefile .trivyignore.yaml --severity HIGH,CRITICAL --exit-code 1 "$$d" || { echo "FAIL: trivy $$d" >&2; exit 1; }; \
	done

shellcheck: ## shellcheck on every *.sh of the repository
	@files=$$(find . -name .git -prune -o -name .terraform -prune -o -name '*.sh' -type f -print | sort); \
	[ -n "$$files" ] || { echo "shellcheck: no shell script"; exit 0; }; \
	echo "shellcheck $$(echo $$files | wc -w | tr -d ' ') files"; \
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$(CURDIR):/mnt:ro" -w /mnt $(SHELLCHECK_IMAGE) $$files

# Security lint of the workflows: zizmor with the regular persona on the whole repository, the repository mounted
# read-only. Every finding fails (exit codes 11 to 14); the deliberate ones are left out in .github/zizmor.yml, each with
# its reason. With GH_TOKEN set (CI passes the job's read-only token) the online audits run too (impostor commits,
# actions with known vulnerabilities); without it, offline audits only. ZIZMOR_FORMAT=github writes workflow commands
# (annotations in CI).
ZIZMOR_FORMAT ?= plain
zizmor: ## Security lint of the workflows with the pinned zizmor (online audits with GH_TOKEN; ZIZMOR_FORMAT=github)
	@echo "zizmor .github"; \
	if [ -n "$${GH_TOKEN:-}" ]; then net="--env=GH_TOKEN"; else net="--env=ZIZMOR_OFFLINE=true --network=none"; fi; \
	$(DOCKER) $$net -v "$(CURDIR):/src:ro" -w /src $(ZIZMOR_IMAGE) --persona=regular --no-progress --color=never \
	  --cache-dir /tmp/zizmor --format='$(ZIZMOR_FORMAT)' . || { echo "FAIL: zizmor" >&2; exit 1; }

# Static check of the Markdown: markdownlint-cli2 with .markdownlint.yaml (style), then lychee --offline --include-fragments
# (relative links and heading anchors; links to other sites are not followed: the network is not stable and a check that
# depends on it fails for reasons outside the change), both without network, the repository mounted read-only at /repo:
# a relative link that leaves the repository is an error on purpose. DOCS narrows the files (paths or globs, relative to
# the repository); the default is every Markdown file git tracks plus the new ones it does not track yet, except under
# .claude/: that is configuration of a coding agent (the skill that draws the AWS diagrams), whose files follow the
# agent's own format, not documentation of the repository. Both tools always run; the exit code is not 0 when either
# reports a problem.
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

# The session scripts reach the AWS account and the cluster when the learner runs them; their self-test puts fake aws,
# kubectl, helm, terraform, make and dig first on PATH, so it reaches nothing. Only its FAIL lines are printed.
# GitHub settings the github provider cannot manage (README of github/, table "Không quản"): Apps registered from their
# manifest in github/apps/, and a read-only check of the rest. Python's standard library and gh, no container.
github-app-test: ## Offline self-test of github/scripts/github-app.py (manifests, destinations, repository list)
	@echo "github-app-test"; python3 -I github/scripts/github-app.py selftest >/dev/null || { echo "FAIL: github-app-test (python3 github/scripts/github-app.py selftest)" >&2; exit 1; }

github-check: ## Read-only check of the GitHub settings Terraform does not manage (gh signed in; WITH_APP_KEYS=1 also reads App installations)
	@python3 -I github/scripts/github-app.py check $(if $(WITH_APP_KEYS),--with-app-keys)

github-app: ## Register GitHub App APP=<name> from github/apps/<name>.json and write its key and client ID (the account owner runs it)
	@test -n '$(APP)' || { echo "make github-app: set APP=<name> (github/apps/<name>.json)" >&2; exit 1; }; \
	python3 -I github/scripts/github-app.py create '$(APP)'

github-app-key: ## Write PEM=<file> as key KEY=<stg|prd|local> of App APP=<name> (github/apps/destinations.json), then delete the file
	@test -n '$(APP)' -a -n '$(KEY)' -a -n '$(PEM)' || { echo "make github-app-key: set APP, KEY and PEM" >&2; exit 1; }; \
	python3 -I github/scripts/github-app.py set-key '$(APP)' '$(KEY)' '$(PEM)'

session-test: ## Self-test of the session scripts of aws/scripts with fake commands (no account, cluster or network)
	@echo "session-test aws/scripts"; \
	bash aws/scripts/session-test.sh >/dev/null || { echo "FAIL: session-test (bash aws/scripts/session-test.sh prints every check)" >&2; exit 1; }

# terraform test of each module (tests/*.tftest.hcl), which the recipe holds to three rules itself instead of trusting
# whoever wrote the tests:
# 1. terraform runs from TERRAFORM_IMAGE, pinned by digest; the test container has no network (--network none), so no
#    provider call can leave the machine. Only init, in a container of its own, downloads providers and registry modules.
# 2. No credential goes in: env(1) drops every AWS_* variable of the caller before docker starts, no -e passes one,
#    HOME is /tmp of the container, and only the module directory is mounted (read-only for the test), never ~/.aws,
#    the repository root or an env directory; a module directory holding .envrc or backend.hcl is refused.
# 3. TEST_GUARD accepts a test file only when it follows a fixed layout, and refuses anything else, naming the file and
#    the line, rather than looking for known ways to break the rule (a run without command applies; a mock under an
#    alias leaves the real provider as the default):
#    - exactly one `mock_provider "aws" {` line (or `mock_provider "aws" {}`), alone on its line;
#    - every run block opens with a `run "<name>" {` line (letters, digits, _ and -), and the first non-blank line after
#      it is `command = plan`;
#    - no other line, leading blanks aside, starts with run, mock_provider, provider (providers too), override_,
#      module, command or /*; no line anywhere holds alias, */ (the end of a block comment, comment lines included, as
#      /* itself can sit in a string such as an origin) or << (a heredoc): the lines of either could pass for the ones
#      above;
#    - no symbolic link in the module directory (terraform test reads what it points to), and no *.tftest.json.
#    Strings cannot span lines in HCL, so with block comments and heredocs refused every line is read here as HCL reads it.
# test-guard checks the three rules with a fake docker first on PATH, so it starts no container.
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
	data=; trap 'rm -rf "$$data"' EXIT; \
	for d in $$dirs; do \
	  $(IS_MODULE) || continue; \
	  echo "test $$d"; \
	  $(TEST_GUARD); \
	  $(NEW_DATA); \
	  $(TEST_RUN) -v "$(CURDIR)/$$d:/src" -w /src $(TERRAFORM_IMAGE) init -backend=false -input=false -no-color >/dev/null || { echo "FAIL: terraform init $$d" >&2; exit 1; }; \
	  $(TEST_RUN) --network none -v "$(CURDIR)/$$d:/src:ro" -w /src $(TERRAFORM_IMAGE) test -no-color || { echo "FAIL: terraform test $$d" >&2; exit 1; }; \
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
	case "$$line" in (*" $(TERRAFORM_IMAGE) "*) ;; (*) fail "terraform test does not run TERRAFORM_IMAGE: $$line";; esac; \
	case "$(TERRAFORM_IMAGE)" in (*@sha256:*) ;; (*) fail "TERRAFORM_IMAGE is not pinned by digest";; esac

lock: ## Write the lock file of each root in DIRS (default: every root) with hashes for LOCK_PLATFORMS
	@dirs=$$($(LIST_DIRS)) || exit 1; \
	data=; trap 'rm -rf "$$data"' EXIT; \
	for d in $$dirs; do \
	  if $(IS_MODULE); then echo "lock: $$d is a module, its lock file is not committed; skipped"; continue; fi; \
	  echo "lock $$d"; \
	  $(NEW_DATA); \
	  $(TF_DATA) init -backend=false -input=false -no-color >/dev/null || { echo "FAIL: terraform init $$d" >&2; exit 1; }; \
	  $(TF_DATA) providers lock -no-color $(addprefix -platform=,$(LOCK_PLATFORMS)) || { echo "FAIL: providers lock $$d" >&2; exit 1; }; \
	done
