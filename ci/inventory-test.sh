#!/usr/bin/env bash
# Self-test of ci/inventory.sh with a fake docker first on PATH: no container, provider, account or network is reached.
# Runs on the Mac (bash 3.2) and on Linux; needs jq and git. The script runs from a copy in a tree of its own: one
# main.tf per root, canary files with personal values where the learner keeps them, nothing of this repository.

# Usage: ci/inventory-test.sh
#
# The expected Markdown holds literal backticks.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
for c in jq git; do
  command -v "$c" >/dev/null || {
    echo "FAIL  $c not found" >&2
    exit 1
  }
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
work=$(cd "$work" && pwd)
bin=$work/bin infra=$work/infra log=$work/calls.log tmp=$work/tmp
tf_image=hashicorp/terraform:0.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
d2_image=d2lang/d2:v0.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111
jq_image=ghcr.io/jqlang/jq:0.0.0@sha256:2222222222222222222222222222222222222222222222222222222222222222
canary=svp-canary-7f3a9c
failures=0

pass() { printf 'ok    %s\n' "$1"; }
bad() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}
# expect NAME CMD...: CMD exits 0.
expect() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else bad "$name"; fi
}

# --- the tree ----------------------------------------------------------------------------------------------------
# Each root holds a resource of its own, a committed <env>.tfvars or example, and beside them every kind of file the
# inventory must never read, each holding the canary. The repository's .gitignore leaves most of them out of git's
# list; backend-x.hcl, a module's test and a symbolic link to a canary outside the tree are the script's own refusals.
mkdir -p "$bin" "$infra/ci/inventory" "$infra/docs/diagrams/icons" "$tmp"
cp "$src/inventory.sh" "$infra/ci/"
cp "$src/../.gitignore" "$infra/"
cp "$src/../docs/diagrams/tokens.d2" "$infra/docs/diagrams/"
printf '<svg/>\n' >"$infra/docs/diagrams/icons/s3.svg"
printf '%s\n' "$canary" >"$work/outside.txt"
roots=$(sed -n '/^ROOTS=(/,/)/p' "$src/inventory.sh" | tr -d '()' | sed 's/^ROOTS=//' | tr ' ' '\n' | grep .)
for root in $roots; do
  mkdir -p "$infra/$root"
  printf 'resource "aws_s3_bucket" "state" {}\n' >"$infra/$root/main.tf"
  env=${root##*/}
  printf 'x = 1\n' >"$infra/$root/$env.tfvars"
  printf 'y = 2\n' >"$infra/$root/example.auto.tfvars.example"
  for f in "$env.auto.tfvars" terraform.tfvars x.auto.tfvars.json backend.hcl backend-x.hcl .envrc local_override.tf \
    terraform.tfstate plan.tfplan; do
    printf 'v = "%s"\n' "$canary" >"$infra/$root/$f"
  done
  mkdir -p "$infra/$root/.terraform" "$infra/$root/.session" "$infra/$root/tests"
  printf '%s\n' "$canary" >"$infra/$root/.terraform/terraform.tfstate"
  printf '%s\n' "$canary" >"$infra/$root/.session/out.txt"
  printf 'run "x" { # %s\n}\n' "$canary" >"$infra/$root/tests/own.tftest.hcl"
  ln -s "$work/outside.txt" "$infra/$root/link.tf"
done
mkdir -p "$infra/aws/modules/m"
printf 'resource "aws_kms_key" "this" {}\n' >"$infra/aws/modules/m/main.tf"
for f in bootstrap org log-archive security baseline backup accounts envs gitops github; do
  printf 'mock_provider "aws" {}\n\nrun "inventory" {\n  command = plan\n}\n' >"$infra/ci/inventory/$f.tftest.hcl"
done
git -C "$infra" init -q

# --- fakes -------------------------------------------------------------------------------------------------------
# docker logs each call: its arguments, then every AWS_* variable it sees. A terraform test call also scans the copy
# mounted at /src for the canary and for files the copy must not hold, and prints a passing test with one plan: a
# module's bucket, a key it imports, and main.tf's bucket; FAKE_FAIL=terraform-test makes it fail. d2 writes its output.
cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
src= work= wdir= prev= cmd=
for a in "$@"; do
  case $prev in
    -v) case $a in *:/src:ro) src=${a%:/src:ro} ;; *:/work) work=${a%:/work} ;; esac ;;
    -w) wdir=$a ;;
  esac
  prev=$a
done
{ printf 'ARGS'; printf ' %s' "$@"; echo; env | sed -n 's/^\(AWS_[A-Za-z0-9_]*\)=.*/ENV \1/p'; } >>"$FAKE_LOG"
case " $* " in
  *" $FAKE_TF_IMAGE init "*) exit 0 ;;
  *" $FAKE_TF_IMAGE test "*)
    if grep -r -l "$FAKE_CANARY" "$src" >/dev/null 2>&1; then echo "LEAK canary in $(grep -r -l "$FAKE_CANARY" "$src")" >>"$FAKE_LOG"; fi
    find "$src" \( -name '*.auto.tfvars' -o -name 'backend*.hcl' -o -name .envrc -o -name '*_override.tf' \
      -o -name '*.tfstate' -o -name '*.tfplan' -o -type l \) -print | sed 's/^/LEAK file /' >>"$FAKE_LOG"
    [ -f "$src/${wdir#/src/}/tests/inventory.tftest.hcl" ] || echo "NOTEST $wdir" >>"$FAKE_LOG"
    [ "${FAKE_FAIL:-}" != terraform-test ] || { echo '{"@level":"error","@message":"Error: fake failure","type":"diagnostic"}'; exit 1; }
    cat <<'JSON'
{"type":"test_plan","@testrun":"inventory","test_plan":{"resource_changes":[
 {"address":"module.m.aws_s3_bucket.this","module_address":"module.m","mode":"managed","type":"aws_s3_bucket","name":"this","change":{"actions":["create"]}},
 {"address":"module.m.aws_kms_key.this","module_address":"module.m","mode":"managed","type":"aws_kms_key","name":"this","change":{"actions":["no-op"],"importing":{"id":"x"}}},
 {"address":"aws_s3_bucket.state","mode":"managed","type":"aws_s3_bucket","name":"state","change":{"actions":["create"]}},
 {"address":"data.aws_region.this","mode":"data","type":"aws_region","name":"this","change":{"actions":["read"]}}]}}
{"type":"test_summary","test_summary":{"status":"pass"}}
JSON
    ;;
  *" $FAKE_JQ_IMAGE "*) while [ "$1" != "$FAKE_JQ_IMAGE" ]; do shift; done; shift; exec jq "$@" ;;
  *" --entrypoint d2 "*)
    for a in "$@"; do cmd=$a; done
    echo "svg of $cmd" >"$work/$cmd" ;;
  *) echo "fake docker: unexpected call $*" >&2; exit 97 ;;
esac
EOF
chmod +x "$bin/docker"

# run ARGS...: the copy of the script with the fakes and AWS_* variables of a signed-in shell; $rc, $work/stdout and
# $work/stderr hold the result, $log the docker calls of this run.
run() {
  : >"$log"
  rc=0
  env PATH="$bin:$PATH" AWS_PROFILE=leak AWS_ACCESS_KEY_ID=leak AWS_SECRET_ACCESS_KEY=leak AWS_SESSION_TOKEN=leak \
    TMPDIR="$tmp" FAKE_LOG="$log" FAKE_TF_IMAGE="$tf_image" FAKE_JQ_IMAGE="$jq_image" FAKE_CANARY="$canary" TERRAFORM_IMAGE="$tf_image" \
    D2_IMAGE="$d2_image" JQ_IMAGE="$jq_image" DOCKER_DEFAULT_PLATFORM=linux/amd64 \
    bash "$infra/ci/inventory.sh" "$@" >"$work/stdout" 2>"$work/stderr" || rc=$?
}
calls() { grep '^ARGS' "$log" | grep -c -- " $1 " || true; }
# mounts LINE: the -v arguments of a docker call, sorted, with the host part of the copy, the data and the cache
# replaced by COPY, DATA and CACHE.
mounts() {
  echo "$1" | awk '{ for (i = 1; i <= NF; i++) if ($i == "-v") print $(++i); else if ($i ~ /^(-v[^a-z-]|--volume|--mount)/) print $i }' |
    sed -e 's|^[^:]*:/src:ro$|COPY:/src:ro|' -e 's|^[^:]*:/tfdata$|DATA:/tfdata|' \
      -e "s|^$infra/.plugin-cache/terraform:|CACHE:|" | sort | tr '\n' ' '
}
roots_n=$(echo "$roots" | wc -l | tr -d ' ')

# --- write -------------------------------------------------------------------------------------------------------
run write
expect "write: exit 0" test "$rc" -eq 0
[ "$rc" -eq 0 ] || cat "$work/stderr" >&2
expect "write: one init and one test per root" test "$(calls init)" -eq "$roots_n" -a "$(calls test)" -eq "$roots_n"
expect "write: two d2 renders (light, dark) per root" test "$(calls --entrypoint)" -eq $((2 * roots_n))
expect "write: no AWS_* variable reached docker" test -z "$(grep '^ENV ' "$log")"
expect "write: no -e of a credential, ~/.aws, .envrc or backend file in a docker call" \
  test -z "$(grep '^ARGS' "$log" | grep -E -e '-e AWS_|/\.aws|\.envrc|backend[^ ]*\.hcl')"
expect "write: the copy held no canary, no personal file, no symbolic link" test -z "$(grep '^LEAK' "$log")"
! grep '^LEAK' "$log" >&2 || true
expect "write: each test ran its root's inventory.tftest.hcl" test -z "$(grep '^NOTEST' "$log")"
tests=$(grep '^ARGS' "$log" | grep -- " $tf_image test ")
expect "write: every terraform test runs with --network none" test -z "$(echo "$tests" | grep -v -- ' --network none ')"
expect "write: every d2 render runs with --network none" \
  test -z "$(grep '^ARGS' "$log" | grep -- ' --entrypoint d2 ' | grep -v -- ' --network none ')"
want="CACHE:/plugin-cache:ro COPY:/src:ro DATA:/tfdata "
odd=$(echo "$tests" | while IFS= read -r line; do [ "$(mounts "$line")" = "$want" ] || echo "$line"; done)
expect "write: terraform test mounts the copy (read-only), its data and the provider cache (read-only), nothing else" \
  test -z "$odd"
copies=$(echo "$tests" | awk '{ for (i = 1; i <= NF; i++) if ($i == "-v" && $(i + 1) ~ /:\/src:ro$/) print $(i + 1) }' |
  sed 's|:/src:ro$||' | sort -u)
expect "write: the copy is one directory outside the repository, removed at exit" \
  test "$(echo "$copies" | wc -l | tr -d ' ')" -eq 1 -a ! -e "$copies" -a "${copies#"$infra"}" = "$copies"
expect "write: test passes the root's <env>.tfvars and its example" \
  test -z "$(echo "$tests" | grep -v -- ' -var-file=[a-z-]*\.tfvars -var-file=example\.auto\.tfvars\.example$')"
page=$infra/docs/reference/inventory.md
expect "write: the page has a section per root" test "$(grep -c '^##* `' "$page")" -eq $((roots_n + 3))
expect "write: the plan line counts the import apart" \
  test "$(grep -c '^`Plan: 1 to import, 2 to add, 0 to change, 0 to destroy.`$' "$page")" -eq "$roots_n"
expect "write: a resource of the root itself counts under its file" grep -q '^| `main.tf` | 1 |$' "$page"
expect "write: an imported resource is marked in the tables" grep -q '^| `module.m` | 2 (1 import) |$' "$page"
expect "write: a data source is not counted" test -z "$(grep 'aws_region' "$page")"
expect "write: the canary never reaches the page or a diagram" \
  test -z "$(grep -r -l "$canary" "$infra/docs")"
expect "write: one .d2 and two SVGs per root" test "$(find "$infra/docs/diagrams/inventory" -type f | wc -l | tr -d ' ')" \
  -eq $((3 * roots_n))
expect "write: the diagram of aws/envs/stg uses the icon of S3" \
  grep -q 'icon: ../icons/s3.svg' "$infra/docs/diagrams/inventory/envs-stg.d2"
expect "write: TERRAFORM_IMAGE, D2_IMAGE and JQ_IMAGE of the Makefile are pinned by digest" \
  test "$(grep -E -c '^(TERRAFORM|D2|JQ)_IMAGE +:= [^ ]+@sha256:[0-9a-f]{64}$' "$src/../Makefile")" -eq 3

# --- check -------------------------------------------------------------------------------------------------------
run check
expect "check right after write: exit 0" test "$rc" -eq 0
sed -i.bak 's/| `main.tf` | 1 |/| `main.tf` | 7 |/' "$page" && rm -f "$page.bak"
run check
expect "check with a number changed by hand: fails" test "$rc" -ne 0
expect "check with a number changed by hand: names the page" grep -q 'docs/reference/inventory.md is out of date' "$work/stderr"
run write
printf 'x\n' >"$infra/docs/diagrams/inventory/old.svg"
echo "svg of other" >"$infra/docs/diagrams/inventory/org-dark.svg"
run check
expect "check with an SVG changed: names it" grep -q 'inventory/org-dark.svg is out of date' "$work/stderr"
expect "check with an SVG no longer generated: names it" grep -q 'inventory/old.svg is not generated' "$work/stderr"
run write
expect "write removes what it no longer generates" test ! -e "$infra/docs/diagrams/inventory/old.svg"

# --- failures ----------------------------------------------------------------------------------------------------
FAKE_FAIL=terraform-test run write
expect "a failing terraform test: exit 1, naming the root and its file" \
  test "$rc" -ne 0 -a -n "$(grep 'FAIL: inventory: terraform test of aws/bootstrap with ci/inventory/bootstrap.tftest.hcl' "$work/stderr")"
expect "a failing terraform test: its error is printed" grep -q 'fake failure' "$work/stderr"
mv "$infra/ci/inventory/github.tftest.hcl" "$work/"
run check
expect "a root without its file in ci/inventory: fails, naming it" grep -q 'no ci/inventory/github.tftest.hcl' "$work/stderr"
mv "$work/github.tftest.hcl" "$infra/ci/inventory/"
cp "$infra/ci/inventory.sh" "$work/inventory.sh.orig"
sed 's/^    backup) echo/    backupx) echo/' "$work/inventory.sh.orig" >"$infra/ci/inventory.sh"
run write
expect "a root family without notes: exit 1, naming it" \
  test "$rc" -ne 0 -a -n "$(grep 'FAIL: inventory: no notes for backup' "$work/stderr")"
cp "$work/inventory.sh.orig" "$infra/ci/inventory.sh"
mkdir -p "$infra/aws/extra"
printf 'resource "aws_s3_bucket" "x" {}\n' >"$infra/aws/extra/main.tf"
mkdir -p "$infra/aws/extra/modules/m"
printf 'resource "aws_s3_bucket" "x" {}\n' >"$infra/aws/extra/modules/m/main.tf"
run check
expect "a root missing from ROOTS: exit 1, naming it" \
  test "$rc" -ne 0 -a -n "$(grep 'FAIL: inventory: aws/extra is a Terraform root missing from ROOTS' "$work/stderr")"
expect "a module below a root is not taken for a root" test -z "$(grep 'aws/extra/modules' "$work/stderr")"
rm -rf "$infra/aws/extra"

# A personal file someone added with git add -f stays out of the copy, whichever pattern of denied() names it.
mkdir -p "$infra/aws/org/.terraform"
printf '%s\n' "$canary" >"$infra/aws/org/.terraform/modules.json"
for f in org.auto.tfvars terraform.tfvars .envrc .terraform/modules.json .session/out.txt; do
  git -C "$infra" add -f "aws/org/$f"
  run write
  expect "tracked aws/org/$f: write exits 0" test "$rc" -eq 0
  expect "tracked aws/org/$f: the copy held no canary" test -z "$(grep '^LEAK' "$log")"
  git -C "$infra" rm -q --cached -f "aws/org/$f"
done
expect "no run leaves the lock of the plugin cache behind" test ! -e "$infra/.plugin-cache/lock"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
