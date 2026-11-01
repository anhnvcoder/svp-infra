#!/usr/bin/env bash
# The whole session in order, as docs/runbooks/session-<env>.md runs it: each step's script with --print, so every
# command of the session shows up in the order it runs, and nothing runs. The session itself is run step by step from
# the runbook (each step's output is read before the next).
#
# Usage: aws/scripts/session.sh --print stg
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing || fail "usage: $(basename "$0") --print stg (the session runs step by step from docs/runbooks/session-stg.md)"
shift
[ $# -eq 1 ] || fail "usage: $(basename "$0") --print stg"
env_arg "$1"

# The steps, one per line: the script and its arguments. The runbook's table of steps lists the same, in this order.
steps="check-account.sh
check-dns.sh
tf.sh $env_name init
tf.sh $env_name plan
tf.sh $env_name apply
bootstrap-argocd.sh $env_name
measure.sh $env_name
pre-destroy.sh $env_name
tf.sh $env_name plan --destroy
tf.sh $env_name destroy
sweep.sh"

n=0
while read -r script args; do
  n=$((n + 1))
  printf '\n### step %s: aws/scripts/%s\n' "$n" "$(oneline <<<"$script $args")"
  # shellcheck disable=SC2086 # the arguments of the step, one word each
  bash "$scripts_dir/$script" --print $args
done <<<"$steps"
