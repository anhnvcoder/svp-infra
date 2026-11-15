#!/usr/bin/env bash
# The credential of one pull-through cache rule of ECR (GHCR or Docker Hub) in its entry of Secrets Manager,
# ecr-pullthroughcache/<upstream>, which the apply of aws/accounts/<env> makes empty. The user name and the token come
# from the terminal (the token read without echo), or as {"username": ..., "accessToken": ...} on stdin when stdin is
# not a terminal; the token must have the form its upstream gives it (ghp_... for GHCR, dckr_pat_... for Docker Hub).

# The token reaches put-secret-value through a pipe from printf, a builtin: never an argument (ps), a file, stdout or
# stderr; an error of aws is printed with the token cut out. Each run writes a new version of the entry, so running it
# again after an error is safe. Steps and rotation: docs/runbooks/platform-setup.md, step (6).

# Usage: aws/scripts/cache-secrets.sh [--print] stg|prd ghcr|dockerhub
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
usage="usage: $(basename "$0") [--print] $(env_names session) ghcr|dockerhub"
[ $# -eq 2 ] || fail "$usage"
env_arg "$1"
# Each upstream: its entry, what the prompts call the user and the token, and the token's form. Only characters that
# need no escaping in JSON, so printf can build it.
case $2 in
  ghcr)
    entry=ecr-pullthroughcache/ghcr who='GitHub user' what='PAT read:packages' form='^ghp_[A-Za-z0-9_]+$'
    shape='ghp_...'
    ;;
  dockerhub)
    entry=ecr-pullthroughcache/docker-hub who='Docker Hub user' what='Docker Hub token (Public Repo Read-only)'
    form='^dckr_pat_[A-Za-z0-9_-]+$' shape='dckr_pat_...'
    ;;
  *) fail "$usage" ;;
esac
me=$(basename "$0")

user='' token='' input='' json=''
trap 'unset user token input json' EXIT

step "$me $2: the credential of the pull-through cache in entry $entry of $env_name"
# aws reads no stdin here: the credential on stdin waits for the read below.
check_account </dev/null
aws_ secretsmanager describe-secret --secret-id "$entry" --query Name --output text </dev/null >/dev/null ||
  fail "no entry $entry in $env_name: apply aws/accounts/$env_name first (docs/runbooks/platform-setup.md, step (5))"
ok "entry $entry exists"

if printing; then
  printf '  (reads %s and %s from the terminal, the token without echo, or {"username": ..., "accessToken": ...} from stdin; the token must be %s)\n' \
    "$who" "$what" "$shape" >&3
  printf '  (printf pipes {"username": <user>, "accessToken": <token>} to the command below)\n' >&3
  aws_ secretsmanager put-secret-value --secret-id "$entry" --secret-string file:///dev/stdin --query VersionId --output text
  exit 0
fi

if [ -t 0 ]; then
  printf '%s: ' "$who" >&2
  read -r user || user=
  printf '%s: ' "$what" >&2
  read -rs token || token=
  printf '\n' >&2
else
  input=$(cat) || input=
  user=$(printf '%s' "$input" | jq -r '.username | strings' 2>/dev/null) || user=
  token=$(printf '%s' "$input" | jq -r '.accessToken | strings' 2>/dev/null) || token=
  input=
  [ -n "$user" ] && [ -n "$token" ] ||
    fail "stdin is not {\"username\": \"<user>\", \"accessToken\": \"<token>\"} with both keys set; nothing written"
fi
# The upstreams' user names are letters, digits, '-', '_' and '.'. The value is not shown: it may be a token typed
# at the wrong prompt.
[[ $user =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "the $who is not letters, digits, '.', '_', '-'; nothing written"
[[ $token =~ $form ]] || fail "the token is not of the form $shape (or is empty); nothing written"

json=$(printf '{"username":"%s","accessToken":"%s"}' "$user" "$token")
if out=$(printf '%s' "$json" | aws_ secretsmanager put-secret-value --secret-id "$entry" \
  --secret-string file:///dev/stdin --query VersionId --output text 2>&1); then
  json=
  version=${out##*$'\n'}
  [ -n "$version" ] || fail "put-secret-value of $entry answered no VersionId"
  ok "entry $entry of $env_name: version ${version:0:8} (value not shown); next: the validate loop of docs/runbooks/platform-setup.md, step (5)"
  exit 0
fi
out=${out//"$token"/<token>}
fail "write entry $entry of $env_name (nothing else changed; run $me again): $out"
