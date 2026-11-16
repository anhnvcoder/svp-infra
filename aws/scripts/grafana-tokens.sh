#!/usr/bin/env bash
# The tokens of service account svp-grafana-operator in the Amazon Managed Grafana workspace of an environment: list
# prints the id and the expiry of each, revoke deletes every one of them (the account checked again right before each
# delete) and lists again, expecting none. Each bootstrap.sh <env> secrets replaces them anyway; this is for a token
# that leaked, or the one left after a session. No token's key is ever read: the API returns it only on creation.

# The workspace is the one of output grafana_url of aws/accounts/<env>; that output is null while no workspace exists
# (managed_grafana off, or session outside a session, in aws/paid-features.json), and then there is no token either.
# Steps: docs/runbooks/platform-setup.md, "Xoay credential".

# Usage: aws/scripts/grafana-tokens.sh [--print] stg|prd list|revoke
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
usage="usage: $(basename "$0") [--print] $(env_names session) list|revoke"
[ $# -eq 2 ] || fail "$usage"
env_arg "$1"
case $2 in list | revoke) ;; *) fail "$usage" ;; esac
action=$2
me=$(basename "$0")
sa_name=svp-grafana-operator
account_root=$infra_root/aws/accounts/$env_name

# list_tokens: the ids of the tokens of the service account in tokens, one per line, and a note line for each.
list_tokens() {
  local out
  out=$(aws_ grafana list-workspace-service-account-tokens --workspace-id "$workspace" --service-account-id "$sa" \
    --output json) || fail "list the tokens of service account $sa_name in Grafana workspace $workspace"
  if printing; then
    tokens='<id>'
    return 0
  fi
  tokens=$(jq -r '.serviceAccountTokens[]?.id' <<<"$out") || fail "the answer of list-workspace-service-account-tokens is not JSON"
  ok "$sa_name of $env_name: $(grep -c . <<<"$tokens" || true) token(s)"
  jq -r '.serviceAccountTokens[]? | "note  token \(.id) expires \(.expiresAt // "never")"' <<<"$out"
}

step "$me $action: the tokens of $sa_name in the Grafana workspace of $env_name"
grafana=$(paid_feature "$env_name" managed_grafana) || exit 1
if [ "$grafana" = off ]; then
  skip "managed_grafana of $env_name is off in aws/paid-features.json: no Grafana workspace, so no token of $sa_name"
  exit 0
fi
check_account
url=$(tf_ "$account_root" output -json grafana_url) ||
  fail "terraform output grafana_url of aws/accounts/$env_name: init it once (aws/accounts/README.md), then this again"
if printing; then
  workspace='<g-id of output grafana_url>'
else
  url=$(jq -r 'strings' <<<"$url" 2>/dev/null) || fail "output grafana_url of aws/accounts/$env_name is not a string or null"
  if [ -z "$url" ]; then
    [ "$grafana" = session ] ||
      fail "output grafana_url of aws/accounts/$env_name is null though managed_grafana of $env_name is always: apply aws/accounts/$env_name (docs/runbooks/platform-setup.md, step (5))"
    skip "no Grafana workspace in $env_name (managed_grafana session in aws/paid-features.json, no session open), so no token of $sa_name"
    exit 0
  fi
  # The workspace id is the first label of the URL (https://g-<id>.grafana-workspace.<region>.amazonaws.com).
  workspace=${url#https://}
  workspace=${workspace%%.*}
  [[ $workspace =~ ^g-[0-9a-z]+$ ]] ||
    fail "output grafana_url of aws/accounts/$env_name is not https://g-<id>.grafana-workspace...: '$url'"
fi

out=$(aws_ grafana list-workspace-service-accounts --workspace-id "$workspace" --output json) ||
  fail "list the service accounts of Grafana workspace $workspace"
if printing; then
  sa="<id of service account $sa_name>"
else
  sa=$(jq -r --arg n "$sa_name" '[.serviceAccounts[]? | select(.name == $n) | .id][0] // empty' <<<"$out")
  [ -n "$sa" ] ||
    fail "Grafana workspace $workspace has no service account $sa_name (the apply of aws/accounts/$env_name makes it)"
fi
list_tokens
[ "$action" = revoke ] || exit 0

if ! printing && [ -z "$tokens" ]; then
  ok "no token of $sa_name to revoke"
  exit 0
fi
printing && printf '  (for each token of the list above:)\n' >&3
for t in $tokens; do
  check_account
  aws_ grafana delete-workspace-service-account-token --workspace-id "$workspace" --service-account-id "$sa" \
    --token-id "$t" --output json >/dev/null || fail "delete token $t of service account $sa_name"
  ok "token $t deleted"
done
list_tokens
printing || [ -z "$tokens" ] || fail "tokens of $sa_name left after the deletes: $(oneline <<<"$tokens"); run $me $env_name revoke again"
ok "no token of $sa_name left in $env_name"
