#!/usr/bin/env bash
# Puts the jq of JQ_IMAGE (make ci-pin-jq passes it) first on PATH for the later steps of a GitHub Actions job: the
# runner's own jq (1.7.1) and a Mac's (1.8.x) accept different programs, so a job runs the version the Makefile pins.
# It writes $GITHUB_PATH, so it refuses to run outside GitHub Actions; the image is a single static binary, /jq.
# Design notes: docs/reference/checks.md.

set -euo pipefail

[ "${GITHUB_ACTIONS:-}" = true ] || { echo "pin-jq: GitHub Actions only (it writes GITHUB_PATH)" >&2; exit 1; }
image=${JQ_IMAGE:-}
case $image in
  *:*@sha256:*) ;;
  *) echo "pin-jq: JQ_IMAGE is not <image>:<tag>@sha256:<digest>; run make ci-pin-jq" >&2; exit 1 ;;
esac

bin=$RUNNER_TEMP/pinned-jq
mkdir -p "$bin"
id=$(env -u DOCKER_DEFAULT_PLATFORM docker create "$image")
trap 'env -u DOCKER_DEFAULT_PLATFORM docker rm "$id" >/dev/null' EXIT
env -u DOCKER_DEFAULT_PLATFORM docker cp "$id:/jq" "$bin/jq"
echo "$bin" >>"$GITHUB_PATH"
"$bin/jq" --version
