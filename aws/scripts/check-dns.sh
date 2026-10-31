#!/usr/bin/env bash
# Second step of every AWS session, before any plan or apply: the delegation of the lab zone aws.<domain> to Route 53
# must be what public resolvers answer. Let's Encrypt checks DNS-01 and the web reaches its names through public
# resolvers, so a delegation not yet propagated (or undone at the parent's DNS) fails the session later, after the
# cluster is paid for; this stops it before.
#
# Reads the name servers of the hosted zone from the output name_servers of root aws/bootstrap (its state, with the
# session's profile) and calls no other AWS API; asks the NS of the zone from two public resolvers. Both answers must
# be exactly those name servers. The zone name comes from SVP_ZONE_NAME or zone_name of aws/bootstrap/bootstrap.auto.tfvars.
#
# Usage: aws/scripts/check-dns.sh [--print]
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
case "$*" in '' | --print) ;; *) fail "usage: $(basename "$0") [--print]" ;; esac

# Cloudflare's and Google's resolvers: two operators, so one stale cache does not decide.
resolvers="1.1.1.1 8.8.8.8"

# names: the DNS names on stdin, one per line, lowercase, without the trailing dot, sorted.
names() { tr '[:upper:]' '[:lower:]' | sed 's/\.$//' | grep . | LC_ALL=C sort -u || true; }

lab_zone
step "check-dns.sh: delegation of $zone"
out=$(tf_ "$infra_root/aws/bootstrap" output -json name_servers) ||
  fail "terraform output name_servers of aws/bootstrap (init it once: AWS_PROFILE=$profile terraform -chdir=aws/bootstrap init -backend-config=../backend.hcl)"
want=
if ! printing; then
  want=$(jq -r '.[]' <<<"$out" 2>/dev/null | names) || true
  [ -n "$want" ] || fail "output name_servers of aws/bootstrap is empty or not a list"
  ok "hosted zone $zone has name servers $(oneline <<<"$want")"
fi

for r in $resolvers; do
  got=$(run_ dig NS "$zone" +short +time=5 +tries=2 "@$r") || got=
  printing && continue
  got=$(names <<<"$got")
  [ -n "$got" ] || fail "resolver $r returns no NS for $zone: the delegation is missing or not propagated yet (aws/bootstrap/README.md, step 5); do not start the session"
  [ "$got" = "$want" ] ||
    fail "resolver $r returns NS $(oneline <<<"$got") for $zone, not the hosted zone's $(oneline <<<"$want"): fix the NS records at the parent's DNS (aws/bootstrap/README.md, step 5); do not start the session"
  ok "resolver $r: NS of $zone are the hosted zone's"
done
