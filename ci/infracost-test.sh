#!/usr/bin/env bash
# Self-test of ci/infracost.sh with a fake docker first on PATH: no container, key, token or network is reached. Runs
# on the Mac (bash 3.2) and on Linux; needs jq. The script runs from a copy in a tree of its own, so the test writes
# nothing in this repository and can tell whether the script wrote into the trees it prices.

# Usage: ci/infracost-test.sh
#
# The fake infracost and the expected arguments hold literal $ signs.
# shellcheck disable=SC2016
set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
command -v jq >/dev/null || {
  echo "FAIL  jq not found" >&2
  exit 1
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
work=$(cd "$work" && pwd)
bin=$work/bin infra=$work/infra base=$work/base log=$work/calls.log tmp=$work/tmp
mkdir -p "$bin" "$infra/ci" "$base" "$tmp"
cp "$src/infracost.sh" "$infra/ci/"
printf 'version: 0.1\n' >"$infra/infracost.yml"
key=ico-test-key-0123456789 token=ghs_test_token_0123456789
image=infracost/infracost:ci-test@sha256:0000000000000000000000000000000000000000000000000000000000000000
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

# --- fakes -------------------------------------------------------------------------------------------------------
# docker logs each call: its arguments, then each -e variable (NAME=VALUE as given, a bare NAME only as set or unset,
# never its value). breakdown and diff write a small Infracost JSON to the host directory mounted as /work/out;
# FAKE_FAIL=breakdown makes breakdown fail. With --entrypoint sh it runs the -c script with the fake infracost below.
cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
outdir= entry= prev= image=
envs=()
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  a=${args[i]}
  case $prev in
    -e) envs+=("$a") ;;
    -v) case $a in *:/work/out | *:/work/out:ro) outdir=${a%:/work/out*} ;; esac ;;
    --entrypoint) entry=$a ;;
  esac
  [ "$a" != "$FAKE_IMAGE" ] || { image=$i; break; }
  prev=$a
done
{
  printf 'ARGS'; printf ' %s' "$@"; echo
  for e in "${envs[@]}"; do
    case $e in *=*) echo "ENV $e" ;; *) if [ -n "${!e:-}" ]; then echo "ENV $e=set"; else echo "ENV $e=unset"; fi ;; esac
  done
  [ -z "${DOCKER_DEFAULT_PLATFORM:-}" ] || echo "ENV DOCKER_DEFAULT_PLATFORM=$DOCKER_DEFAULT_PLATFORM"
} >>"$FAKE_LOG"
[ -n "$image" ] || { echo "fake docker: image $FAKE_IMAGE not in the call" >&2; exit 97; }
cmd=("${args[@]:image+1}")
if [ "$entry" = sh ]; then
  PATH="$FAKE_BIN:$PATH" exec sh "${cmd[@]}"
fi
file=
for ((i = 0; i < ${#cmd[@]}; i++)); do [ "${cmd[i]}" != --out-file ] || file=${cmd[i+1]#/work/out/}; done
case ${cmd[0]} in
  breakdown)
    [ "${FAKE_FAIL:-}" != breakdown ] || { echo "Error: parsing aws/envs/stg failed" >&2; exit 1; }
    echo '{"currency": "USD", "projects": []}' >"$outdir/$file" ;;
  diff)
    cat >"$outdir/$file" <<'JSON'
{"currency": "USD", "pastTotalMonthlyCost": "100.004", "totalMonthlyCost": "112.346", "diffTotalMonthlyCost": "12.342",
 "projects": [
  {"name": "envs-stg", "pastBreakdown": {"totalMonthlyCost": "100.004"}, "breakdown": {"totalMonthlyCost": "112.346"},
   "diff": {"totalMonthlyCost": "12.342"}},
  {"name": "accounts-stg", "pastBreakdown": null, "breakdown": {"totalMonthlyCost": "0"}, "diff": null}]}
JSON
    ;;
esac
EOF
# infracost inside the container of comment: logs its arguments, with the token replaced by whether it is the one of
# the environment.
cat >"$work/infracost" <<'EOF'
#!/usr/bin/env bash
args=()
while [ $# -gt 0 ]; do
  if [ "$1" = --github-token ]; then
    if [ "$2" = "$GITHUB_TOKEN" ]; then args+=("$1" TOKEN-OK); else args+=("$1" TOKEN-WRONG); fi
    shift 2
  else
    args+=("$1")
    shift
  fi
done
echo "CLI ${args[*]}" >>"$FAKE_LOG"
EOF
chmod +x "$bin/docker" "$work/infracost"

# run [VAR=VALUE...] -- ARGS...: runs the copy of the script with the fakes; $rc, $calls (docker calls) and $ghout (step
# output) hold the result, $work/stdout, stderr, summary and output the rest. Every run starts from empty files.
run() {
  local vars=()
  while [ "$1" != -- ]; do vars+=("$1"); shift; done
  shift
  : >"$log"
  rm -rf "$tmp" "$work/summary" "$work/output"
  mkdir -p "$tmp"
  : >"$work/summary"
  : >"$work/output"
  rc=0
  env -i PATH="$bin:$PATH" HOME="$work" TMPDIR="$tmp" FAKE_LOG="$log" FAKE_IMAGE="$image" FAKE_BIN="$work" \
    INFRACOST_IMAGE="$image" DOCKER_DEFAULT_PLATFORM=linux/amd64 ${vars[@]+"${vars[@]}"} \
    bash "$infra/ci/infracost.sh" "$@" >"$work/stdout" 2>"$work/stderr" || rc=$?
  ghout=$(cat "$work/output")
  calls=$(grep -c '^ARGS' "$log" || true)
}
actions=(GITHUB_ACTIONS=true RUNNER_TEMP="$work/rt" GITHUB_STEP_SUMMARY="$work/summary" GITHUB_OUTPUT="$work/output"
  REPO=anhnvcoder/svp-infra HEAD_REPO=anhnvcoder/svp-infra)
mkdir -p "$work/rt"
# no_secret: neither the key nor the token shows in an output, the summary, the step output or an argument of docker.
no_secret() {
  ! grep -q -e "$key" -e "$token" "$work/stdout" "$work/stderr" "$work/summary" "$work/output" "$log"
}
nth() { grep '^ARGS' "$log" | sed -n "${1}p"; }
has() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

# --- refusals and skips ------------------------------------------------------------------------------------------
run -- estimate "$base"
expect "no key on a dev machine: refused" test "$rc" -ne 0
expect "no key on a dev machine: the refusal names INFRACOST_API_KEY" grep -q 'INFRACOST_API_KEY is empty' "$work/stderr"
expect "no key on a dev machine: no docker call" test "$calls" -eq 0

: >"$log"
rc=0
env -u GITHUB_ACTIONS INFRACOST_API_KEY= PATH="$bin:$PATH" FAKE_LOG="$log" FAKE_IMAGE="$image" \
  make --no-print-directory -C "$src/.." infracost BASE=. >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "make infracost without a key: refused" test "$rc" -ne 0
expect "make infracost without a key: the refusal names INFRACOST_API_KEY" grep -q 'INFRACOST_API_KEY' "$work/stderr"
expect "make infracost without a key: no docker call" test ! -s "$log"

run "${actions[@]}" -- estimate "$base"
expect "no key in Actions: exit 0" test "$rc" -eq 0
expect "no key in Actions: a notice" grep -q '^::notice::Infracost skipped: secret INFRACOST_API_KEY' "$work/stdout"
expect "no key in Actions: the notice in the job summary" grep -q 'Infracost skipped' "$work/summary"
expect "no key in Actions: no docker call" test "$calls" -eq 0
expect "no key in Actions: no estimated output" test -z "$ghout"

run "${actions[@]}" HEAD_REPO=someone/svp-infra INFRACOST_API_KEY="$key" -- estimate "$base"
expect "fork: exit 0" test "$rc" -eq 0
expect "fork: a notice naming it" grep -q '^::notice::Infracost skipped: pull request from the fork someone/svp-infra' \
  "$work/stdout"
expect "fork: no docker call" test "$calls" -eq 0
expect "fork: no estimated output" test -z "$ghout"

run "${actions[@]}" INFRACOST_API_KEY="$key" -- estimate ""
expect "no BASE: refused" test "$rc" -ne 0
expect "no BASE: the refusal names BASE" grep -q '^::error::set BASE=' "$work/stderr"
expect "no BASE: no docker call" test "$calls" -eq 0
run "${actions[@]}" INFRACOST_API_KEY="$key" -- estimate "$work/missing"
expect "BASE not a directory: refused, no docker call" test "$rc" -ne 0 -a "$calls" -eq 0

run -- nothing
expect "unknown command: refused with the usage" test "$rc" -ne 0 -a "$calls" -eq 0

# --- estimate ----------------------------------------------------------------------------------------------------
before=$(cd "$work" && find infra base | sort)
run "${actions[@]}" INFRACOST_API_KEY="$key" -- estimate "$base"
expect "estimate: exit 0" test "$rc" -eq 0
expect "estimate: three docker calls" test "$calls" -eq 3
first=$(nth 1) second=$(nth 2) third=$(nth 3)
expect "estimate: the base tree first" has "$first" "-w /work/base"
expect "estimate: then this tree" has "$second" "-w /work/pr"
expect "estimate: then the diff" has "$third" "diff --path /work/out/pr.json --compare-to /work/out/base.json --format json"
for n in 1 2; do
  line=$(nth $n)
  expect "breakdown $n: the config and usage files of this tree" \
    has "$line" "breakdown --config-file /work/pr/infracost.yml --usage-file /work/pr/infracost-usage.yml --format json"
  expect "breakdown $n: both trees read-only" has "$line" "-v $base:/work/base:ro -v $infra:/work/pr:ro"
  expect "breakdown $n: the module cache outside the trees" has "$line" "-v $work/rt/infracost/cache:/work/.infracost"
done
expect "breakdown: the JSON of the base tree" has "$first" "--out-file /work/out/base.json"
expect "breakdown: the JSON of this tree" has "$second" "--out-file /work/out/pr.json"
for n in 1 2 3; do
  line=$(nth $n)
  expect "call $n: the pinned image" has "$line" "$image"
  expect "call $n: linux/amd64, the image's only platform" has "$line" "--platform linux/amd64"
  expect "call $n: the key by name alone" has "$line" "-e INFRACOST_API_KEY"
  expect "call $n: no upload to Infracost Cloud" has "$line" "-e INFRACOST_ENABLE_CLOUD=false"
done
expect "estimate: the key reaches the container" test "$(grep -c '^ENV INFRACOST_API_KEY=set$' "$log")" -eq 3
expect "estimate: DOCKER_DEFAULT_PLATFORM is dropped" test "$(grep -c '^ENV DOCKER_DEFAULT_PLATFORM' "$log")" -eq 0
expect "estimate: the key never shows" no_secret
expect "estimate: estimated=true for job infracost-comment" test "$ghout" = estimated=true
expect "estimate: the diff below RUNNER_TEMP" test -f "$work/rt/infracost/diff.json"
expect "estimate: a table row per project, rounded to cents" grep -q '^| envs-stg | 100 | 112.35 | 12.34 |$' "$work/summary"
expect "estimate: a project without a past breakdown or diff counts 0" grep -q '^| accounts-stg | 0 | 0 | 0 |$' "$work/summary"
expect "estimate: the total" grep -q '^| \*\*Total\*\* | 100 | 112.35 | 12.34 |$' "$work/summary"
expect "estimate: the currency in the heading" grep -q '^## Infracost: monthly cost (USD)$' "$work/summary"
expect "estimate: the table on stdout too" grep -q '^| envs-stg |' "$work/stdout"
expect "estimate: nothing written in either tree" test "$(cd "$work" && find infra base | sort)" = "$before"

run INFRACOST_API_KEY="$key" -- estimate "$base"
expect "estimate on a dev machine: exit 0" test "$rc" -eq 0 -a "$calls" -eq 3
expect "estimate on a dev machine: below TMPDIR" test -f "$tmp/infracost/diff.json"
expect "estimate on a dev machine: the path of the diff" grep -q "^Diff of every resource: $tmp/infracost/diff.json$" \
  "$work/stdout"

run "${actions[@]}" INFRACOST_API_KEY="$key" FAKE_FAIL=breakdown -- estimate "$base"
expect "breakdown fails: red" test "$rc" -ne 0
expect "breakdown fails: an error naming the tree" grep -q '^::error::infracost breakdown of the base tree$' "$work/stderr"
expect "breakdown fails: no diff call" test "$calls" -eq 1
expect "breakdown fails: no estimated output" test -z "$ghout"

# --- comment -----------------------------------------------------------------------------------------------------
diff_json() { mkdir -p "$work/rt/infracost" && echo '{}' >"$work/rt/infracost/diff.json"; }
diff_json
run "${actions[@]}" INFRACOST_API_KEY="$key" GITHUB_TOKEN="$token" PR=7 -- comment
expect "comment: exit 0" test "$rc" -eq 0
expect "comment: one docker call" test "$calls" -eq 1
line=$(nth 1)
expect "comment: the token by name alone" has "$line" "-e GITHUB_TOKEN"
expect "comment: the key by name alone" has "$line" "-e INFRACOST_API_KEY"
expect "comment: the diff read-only" has "$line" "-v $work/rt/infracost:/work/out:ro"
expect "comment: the pinned image, through its shell" has "$line" "--entrypoint sh $image -c"
expect "comment: the CLI posts with behavior update and the environment's token" grep -q \
  '^CLI comment github --path /work/out/diff.json --repo anhnvcoder/svp-infra --pull-request 7 --behavior update --github-token TOKEN-OK$' \
  "$log"
expect "comment: neither the key nor the token shows" no_secret

rm -f "$work/rt/infracost/diff.json"
run "${actions[@]}" INFRACOST_API_KEY="$key" GITHUB_TOKEN="$token" PR=7 -- comment
expect "comment without a diff: refused, no docker call" test "$rc" -ne 0 -a "$calls" -eq 0
diff_json
run "${actions[@]}" INFRACOST_API_KEY="$key" GITHUB_TOKEN="$token" PR='7; true' -- comment
expect "comment with PR not a number: refused, no docker call" test "$rc" -ne 0 -a "$calls" -eq 0
run "${actions[@]}" INFRACOST_API_KEY="$key" PR=7 -- comment
expect "comment without a token: refused, no docker call" test "$rc" -ne 0 -a "$calls" -eq 0
run "${actions[@]}" GITHUB_TOKEN="$token" PR=7 -- comment
expect "comment without a key in Actions: exit 0, a notice, no docker call" test "$rc" -eq 0 -a "$calls" -eq 0
expect "comment without a key in Actions: the notice" grep -q '^::notice::Infracost skipped' "$work/stdout"

# --- pins --------------------------------------------------------------------------------------------------------
makefile=$src/../Makefile
expect "INFRACOST_IMAGE is the CI tag pinned by digest" \
  grep -E -q '^INFRACOST_IMAGE +:= infracost/infracost:ci-[0-9.]+@sha256:[0-9a-f]{64}$' "$makefile"
expect "INFRACOST_IMAGE has its renovate line right above" test "$(grep -B1 '^INFRACOST_IMAGE ' "$makefile" | head -1)" = \
  '# renovate: datasource=docker depName=infracost/infracost'

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
