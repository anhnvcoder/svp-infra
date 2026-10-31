# Static checks of the Terraform of this repository. `make help` lists the targets.
#
# No target here reaches an AWS account: init always runs with -backend=false, and nothing calls plan, apply or the AWS
# CLI. Every tool runs from its official image pinned by digest, the same reference on a dev machine and in CI, so
# nothing is installed and no setup action is trusted; session-test alone runs on the host, as it needs only bash, git
# and jq, which the Mac and the CI runner both have. Docker runs with DOCKER_DEFAULT_PLATFORM unset: the shell of the
# dev machine sets it to linux/amd64 for another project, which would run these images under emulation.
#
# Parallel runs: `make check DIRS=<dir>` writes only below <dir> (.terraform/ with providers, modules and the tflint
# plugins, and the .terraform.lock.hcl of a module); trivy's cache stays inside its container, and session-test writes
# only in a temporary directory of its own, which it removes. No plugin cache is shared between directories, so two runs
# on two different directories never write the same file.

# renovate: datasource=docker depName=hashicorp/terraform
TERRAFORM_IMAGE  := hashicorp/terraform:1.15.8@sha256:7ae513256f7ce67879e218ae8593d6fbe216ec9e123abe6c94e4e10704857963
# renovate: datasource=docker depName=ghcr.io/terraform-linters/tflint
TFLINT_IMAGE     := ghcr.io/terraform-linters/tflint:v0.65.0@sha256:2788f4d4fc663c0e953b011b01bf443fe5bfce7587ee916e588e6057b85d6359
# Same pin as TRIVY_IMAGE of the code repository's Makefile.
# renovate: datasource=docker depName=ghcr.io/aquasecurity/trivy
TRIVY_IMAGE      := ghcr.io/aquasecurity/trivy:0.76.0@sha256:2416d1f74045b57274df1a340eee6b510cacd73c66a6ccb8da092b117eb7d222
# renovate: datasource=docker depName=koalaman/shellcheck
SHELLCHECK_IMAGE := koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d

# Platforms whose provider hashes `make lock` writes into the lock file of a root: the Mac that runs plan and apply,
# and the two Linux architectures of CI and of the images.
LOCK_PLATFORMS := darwin_arm64 linux_amd64 linux_arm64

# Directories to check, relative to this one; empty means every directory that holds a *.tf file. A directory under a
# modules/ directory is a module: its lock file is not committed. Any other directory is a root: its committed lock
# file is used as it is (init -lockfile=readonly), so a provider change needs `make lock` first.
DIRS ?=

DOCKER := env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp
# HOME=/tmp: the container runs as the caller, who has no home directory in the image.
TF = $(DOCKER) -e CHECKPOINT_DISABLE=1 -e TF_IN_AUTOMATION=1 -v "$(CURDIR):/src" -w "/src/$$d" $(TERRAFORM_IMAGE)

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

.PHONY: help check fmt-check fmt validate tflint trivy shellcheck session-test lock

help: ## List the targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-11s %s\n", $$1, $$2}'

check: fmt-check validate tflint trivy shellcheck session-test ## Every static check (narrow the Terraform ones with DIRS=<dir> ...)

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
	for d in $$dirs; do \
	  echo "validate $$d"; \
	  if $(IS_MODULE); then lock=; \
	  else \
	    [ -f "$$d/.terraform.lock.hcl" ] || { echo "FAIL: $$d is a root without .terraform.lock.hcl (run make lock DIRS=$$d)" >&2; exit 1; }; \
	    lock=-lockfile=readonly; \
	  fi; \
	  $(TF) init -backend=false -input=false -no-color $$lock >/dev/null || { echo "FAIL: terraform init $$d" >&2; exit 1; }; \
	  $(TF) validate -no-color || { echo "FAIL: terraform validate $$d" >&2; exit 1; }; \
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

# Findings of severity HIGH or CRITICAL fail; deliberate exceptions are in .trivyignore.yaml, each with its reason.
# --skip-dirs leaves out the examples/ that registry modules ship (Kubernetes manifests and sample roots Terraform never
# applies), wherever the module is called from, so no exception has to repeat per root.
# --skip-check-update keeps the checks built into the pinned image: the bundle trivy would fetch otherwise sits behind a
# moving tag, so new rules could turn the required check red on unchanged code, or drop a rule without anyone noticing.
# Modules downloaded by init (.terraform/modules) are scanned with the configuration that calls them.
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

# The session scripts reach the AWS account and the cluster when the learner runs them; their self-test puts fake aws,
# kubectl, helm, terraform, make and dig first on PATH, so it reaches nothing. Only its FAIL lines are printed.
session-test: ## Self-test of the session scripts of aws/scripts with fake commands (no account, cluster or network)
	@echo "session-test aws/scripts"; \
	bash aws/scripts/session-test.sh >/dev/null || { echo "FAIL: session-test (bash aws/scripts/session-test.sh prints every check)" >&2; exit 1; }

lock: ## Write the lock file of each root in DIRS (default: every root) with hashes for LOCK_PLATFORMS
	@dirs=$$($(LIST_DIRS)) || exit 1; \
	for d in $$dirs; do \
	  if $(IS_MODULE); then echo "lock: $$d is a module, its lock file is not committed; skipped"; continue; fi; \
	  echo "lock $$d"; \
	  $(TF) init -backend=false -input=false -no-color >/dev/null || { echo "FAIL: terraform init $$d" >&2; exit 1; }; \
	  $(TF) providers lock -no-color $(addprefix -platform=,$(LOCK_PLATFORMS)) || { echo "FAIL: providers lock $$d" >&2; exit 1; }; \
	done
