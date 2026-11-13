#!/usr/bin/env bash
# Warms the pull-through cache of the environment's ECR registry: a pull by digest of an image the cache has never seen
# fails, and every image of the cluster is pinned by digest. Each line of the list (deploy/ci/image-list.sh of the code
# repository: <upstream ref>:<tag>@<digest>) is pulled by tag through the cache, then its pinned digest must be in ECR.

# Runs after the apply of aws/envs/<env>, before root gitops; again when a third-party digest changes mid-session.

# Design notes: README.md.

# Usage: aws/scripts/ecr-warm.sh [--print] stg|prd FILE
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
usage="usage: $(basename "$0") [--print] $(env_names session) FILE (the output of deploy/ci/image-list.sh <gitops> <env>)"
[ $# -eq 2 ] || fail "$usage"
env_arg "$1"
list=$2
session_dir

# cache_repo REF: the repository of the pull-through cache that mirrors upstream repository REF, by its registry's
# prefix; nothing for a release image of the lab (its own repositories, never a cache) or another registry.
cache_repo() {
  case $1 in
    ghcr.io/anhnvcoder/*) return 1 ;;
    ghcr.io/?*) echo "ghcr/${1#ghcr.io/}" ;;
    docker.io/?*) echo "docker-hub/${1#docker.io/}" ;;
    quay.io/?*) echo "quay/${1#quay.io/}" ;;
    registry.k8s.io/?*) echo "k8s/${1#registry.k8s.io/}" ;;
    public.ecr.aws/?*) echo "ecr-public/${1#public.ecr.aws/}" ;;
    *) return 1 ;;
  esac
}

# The whole list is read before any call: a line that is not <ref>:<tag>@sha256:<digest> of a cached registry stops
# here. Each entry: repository of the cache, tag, pinned digest, upstream reference.
entries=
if printing && [ ! -r "$list" ]; then
  entries="<prefix>/<repository> <tag> sha256:<pinned digest> <each line of $list>"
else
  [ -f "$list" ] && [ -r "$list" ] || fail "no readable list $list: deploy/ci/image-list.sh <gitops> $env_name >$list in the code repository"
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ -n "$line" ] || continue
    [[ $line =~ ^([a-z0-9.-]+(/[a-z0-9._-]+)+):([A-Za-z0-9_][A-Za-z0-9._-]{0,127})@(sha256:[0-9a-f]{64})$ ]] ||
      fail "$list:$n is not <ref>:<tag>@sha256:<digest>: $line"
    ref=${BASH_REMATCH[1]} tag=${BASH_REMATCH[3]} digest=${BASH_REMATCH[4]}
    repo=$(cache_repo "$ref") ||
      fail "$list:$n: $ref is not an image of the pull-through cache (ghcr.io, docker.io, quay.io, registry.k8s.io, public.ecr.aws; not ghcr.io/anhnvcoder)"
    entries="$entries$repo $tag $digest $ref
"
  done <"$list"
  [ -n "$entries" ] || fail "$list holds no image"
fi

step "ecr-warm.sh: the account of profile $profile"
check_account
mark ecr-warm-start

errors=$(mktemp)
trap 'rm -f "$errors"' EXIT
# mask: every 12-digit number standing alone (an account id) replaced, not a run of digits inside a digest.
mask() { sed -E 's/(^|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]|$)/\1<account>\2/g'; }
# masked: the error text of the last call, masked, on one line.
masked() { mask <"$errors" | oneline; }

step "ecr-warm.sh: each image by tag through the cache of $env_name, then its pinned digest"
media_types="application/vnd.oci.image.index.v1+json application/vnd.docker.distribution.manifest.list.v2+json
application/vnd.oci.image.manifest.v1+json application/vnd.docker.distribution.manifest.v2+json"
failed=0
while read -r repo tag digest ref; do
  [ -n "$repo" ] || continue
  image="$ref:$tag"
  # shellcheck disable=SC2086 # one word per media type
  if ! out=$(aws_ ecr batch-get-image --repository-name "$repo" --image-ids "imageTag=$tag" \
    --accepted-media-types $media_types --output json 2>"$errors"); then
    printf 'FAIL  %s: pull by tag through %s failed: %s\n' "$image" "$repo" "$(masked)" >&2
    failed=$((failed + 1))
    continue
  fi
  printing && {
    aws_ ecr describe-images --repository-name "$repo" --image-ids "imageDigest=$digest" --output json >/dev/null
    continue
  }
  held=$(jq -r '.images[0].imageId.imageDigest // empty' <<<"$out")
  if [ -z "$held" ]; then
    printf 'FAIL  %s: the cache %s has no tag %s: %s\n' "$image" "$repo" "$tag" \
      "$(jq -r '[.failures[]? | "\(.failureCode // "?"): \(.failureReason // "")"] | join("; ")' <<<"$out" | mask)" >&2
    failed=$((failed + 1))
    continue
  fi
  if [ "$held" = "$digest" ]; then
    ok "$image in $repo at its pinned digest"
    continue
  fi
  # The tag moved upstream after the digest was pinned; the pinned one may still be in ECR from an earlier pull.
  if aws_ ecr describe-images --repository-name "$repo" --image-ids "imageDigest=$digest" --output json >/dev/null 2>"$errors"; then
    note "$image: ECR holds tag $tag at $held, and the pinned $digest too"
    ok "$image pinned digest in $repo"
  else
    grep -q ImageNotFoundException "$errors" || printf 'FAIL  %s: read %s: %s\n' "$image" "$repo" "$(masked)" >&2
    printf 'FAIL  %s: pinned digest %s not in ECR %s, which holds tag %s at %s\n' "$image" "$digest" "$repo" "$tag" "$held" >&2
    failed=$((failed + 1))
  fi
done <<<"$entries"

[ "$failed" -eq 0 ] ||
  fail "$failed image(s) not in ECR at their pinned digest: the cache refreshes a tag at most once a day, run this again later; when the tag moved upstream, update the pinned digest (Renovate's PR)"
mark ecr-warmed
ok "every image of $list in the cache of $env_name at its pinned digest; next: aws/scripts/tf.sh $env_name gitops init, plan, apply"
