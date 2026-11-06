#!/usr/bin/env bash
# Second step of every AWS session, before any plan or apply: public resolvers must answer the delegation of the
# environment's hosted zone (made by the baseline aws/accounts/<env>). Let's Encrypt checks DNS-01 and the web reaches
# its names through public resolvers, so a delegation not yet propagated (or undone) fails the session later, after the
# cluster is paid for; this stops it before. Only the output name_servers of aws/accounts/<env> is read from AWS.

# Usage: aws/scripts/check-dns.sh [--print] stg|prd
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
[ $# -eq 1 ] || fail "usage: $(basename "$0") [--print] $(env_names session)"
env_arg "$1"

# Cloudflare's and Google's resolvers: two operators, so one stale cache does not decide.
resolvers="1.1.1.1 8.8.8.8"
delegation="the delegation of a child zone is delegated_subdomains of aws/accounts/prd, of the root zone the NS records aws at the parent's DNS (README.md of aws/accounts)"

# names: the DNS names on stdin, one per line, lowercase, without the trailing dot, sorted.
names() { tr '[:upper:]' '[:lower:]' | sed 's/\.$//' | grep . | LC_ALL=C sort -u || true; }

env_zone
step "check-dns.sh: delegation of $zone"
out=$(tf_ "$infra_root/aws/accounts/$env_name" output -json name_servers) ||
  fail "terraform output name_servers of aws/accounts/$env_name (init it once: AWS_PROFILE=$profile terraform -chdir=aws/accounts/$env_name init -backend-config=../../backend-$env_name.hcl)"
want=
if ! printing; then
  want=$(jq -r '.[]' <<<"$out" 2>/dev/null | names) || true
  [ -n "$want" ] || fail "output name_servers of aws/accounts/$env_name is empty or not a list"
  ok "hosted zone $zone has name servers $(oneline <<<"$want")"
fi

for r in $resolvers; do
  got=$(run_ dig NS "$zone" +short +time=5 +tries=2 "@$r") || got=
  printing && continue
  got=$(names <<<"$got")
  [ -n "$got" ] || fail "resolver $r returns no NS for $zone: the delegation is missing or not propagated yet; $delegation; do not start the session"
  [ "$got" = "$want" ] ||
    fail "resolver $r returns NS $(oneline <<<"$got") for $zone, not the hosted zone's $(oneline <<<"$want"): fix it; $delegation; do not start the session"
  ok "resolver $r: NS of $zone are the hosted zone's"
done
