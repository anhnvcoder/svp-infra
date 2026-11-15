#!/usr/bin/env bash
# Infracost of a pull request for workflow cost.yml. estimate prices the projects of infracost.yml from their HCL in the
# base tree and in this one (no plan, state or AWS credential) and writes their diff to $RUNNER_TEMP/infracost; comment
# posts that diff to the pull request. Both trees use the config and usage files of this one. Design notes: README.md.

# The API key and the GitHub token reach the container by name alone (-e NAME): never an argument, never a log line.
# Without a key the script refuses on a dev machine and skips with a notice in GitHub Actions.

# Usage: ci/infracost.sh estimate <base tree>
#        ci/infracost.sh comment
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
out=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
out=${out%/}/infracost

in_actions() { [ "${GITHUB_ACTIONS:-}" = true ]; }
fail() {
  if in_actions; then printf '::error::%s\n' "$1" >&2; else printf 'infracost: %s\n' "$1" >&2; fi
  exit 1
}
notice() {
  printf '::notice::%s\n' "$1"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf -- '- %s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
}

need_key() {
  [ -z "${INFRACOST_API_KEY:-}" ] || return 0
  in_actions || fail "INFRACOST_API_KEY is empty: export your free Infracost API key first (README.md)"
  notice "Infracost skipped: secret INFRACOST_API_KEY is not set"
  exit 0
}

# INFRACOST_ENABLE_CLOUD=false keeps the run's JSON off Infracost Cloud: only the price lookups leave the runner.
# The image has no arm64 build, so a Mac runs it under emulation.
cli() {
  env -u DOCKER_DEFAULT_PLATFORM docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -e INFRACOST_API_KEY -e INFRACOST_ENABLE_CLOUD=false -e INFRACOST_NO_COLOR=true "$@"
}

estimate() {
  local base=$1 tree table
  if in_actions && [ "${HEAD_REPO:-}" != "${REPO:-}" ]; then
    notice "Infracost skipped: pull request from the fork ${HEAD_REPO:-}"
    exit 0
  fi
  need_key
  [ -n "$base" ] || fail "set BASE=<directory of the base tree>"
  [ -d "$base" ] || fail "BASE=$base is not a directory"
  base=$(cd "$base" && pwd)
  : "${INFRACOST_IMAGE:?}"
  mkdir -p "$out/cache"
  rm -f "$out/base.json" "$out/pr.json" "$out/diff.json"
  # The trees are read-only; the CLI downloads registry modules below the first .infracost directory it finds up from
  # its working directory, which is the cache directory mounted as /work/.infracost.
  for tree in base pr; do
    cli -v "$base:/work/base:ro" -v "$repo:/work/pr:ro" -v "$out/cache:/work/.infracost" -v "$out:/work/out" \
      -w "/work/$tree" "$INFRACOST_IMAGE" breakdown --config-file /work/pr/infracost.yml \
      --usage-file /work/pr/infracost-usage.yml --format json --out-file "/work/out/$tree.json" ||
      fail "infracost breakdown of the $tree tree"
  done
  cli -v "$out:/work/out" -w /work/out "$INFRACOST_IMAGE" diff --path /work/out/pr.json \
    --compare-to /work/out/base.json --format json --out-file /work/out/diff.json || fail "infracost diff"
  table=$(jq -r '
    def usd: (. // "0") | tonumber | . * 100 | round / 100 | tostring;
    "## Infracost: monthly cost (\(.currency))", "",
    "| Project | Base | Pull request | Diff |", "| --- | ---: | ---: | ---: |",
    (.projects[] | "| \(.name) | \(.pastBreakdown.totalMonthlyCost | usd) | \(.breakdown.totalMonthlyCost | usd) | " +
      "\(.diff.totalMonthlyCost | usd) |"),
    "| **Total** | \(.pastTotalMonthlyCost | usd) | \(.totalMonthlyCost | usd) | \(.diffTotalMonthlyCost | usd) |"
  ' "$out/diff.json") || fail "$out/diff.json is not the JSON of infracost diff"
  printf '%s\n\nDiff of every resource: %s\n' "$table" "$out/diff.json"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$table" >>"$GITHUB_STEP_SUMMARY"
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "estimated=true" >>"$GITHUB_OUTPUT"
}

comment() {
  [ -n "${REPO:-}" ] || fail "set REPO=<owner>/<repository>"
  case ${PR:-} in '' | *[!0-9]*) fail "set PR=<number of the pull request>" ;; esac
  [ -n "${GITHUB_TOKEN:-}" ] || fail "GITHUB_TOKEN is empty"
  need_key
  [ -f "$out/diff.json" ] || fail "no $out/diff.json: run make infracost first"
  : "${INFRACOST_IMAGE:?}"
  # The token is expanded by the shell of the container, so it never shows in the arguments of docker.
  # shellcheck disable=SC2016
  cli -e GITHUB_TOKEN -v "$out:/work/out:ro" -w /work/out --entrypoint sh "$INFRACOST_IMAGE" -c \
    'exec infracost comment github --path /work/out/diff.json --repo "$1" --pull-request "$2" --behavior update \
      --github-token "$GITHUB_TOKEN"' sh "$REPO" "$PR" || fail "infracost comment github"
}

case ${1:-} in
  estimate) estimate "${2:-}" ;;
  comment) comment ;;
  *) fail "usage: ci/infracost.sh estimate <base tree> | comment" ;;
esac
