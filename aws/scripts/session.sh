#!/usr/bin/env bash
# The whole session in order, as docs/runbooks/session-<env>.md runs it: each step's script with --print, so every
# command of the session shows up in the order it runs, and nothing runs. The session itself is run step by step from
# the runbook, which adds what no script does (the promote gate, the tunnel of prd, the drills, the final snapshot).

# Usage: aws/scripts/session.sh --print stg|prd
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing || fail "usage: $(basename "$0") --print $(env_names session) (the session runs step by step from docs/runbooks/session-<env>.md)"
shift
[ $# -eq 1 ] || fail "usage: $(basename "$0") --print $(env_names session)"
env_arg "$1"

# The steps, one per line: the script and its arguments, in the order of the runbook's table of steps.
steps="check-account.sh $env_name
check-dns.sh $env_name
tf.sh $env_name env init
tf.sh $env_name env plan
tf.sh $env_name env apply
bootstrap.sh $env_name secrets
tf.sh $env_name gitops init
tf.sh $env_name gitops plan
tf.sh $env_name gitops apply
bootstrap.sh $env_name wait
measure.sh $env_name
pre-destroy.sh $env_name
tf.sh $env_name gitops plan --destroy
tf.sh $env_name gitops destroy
tf.sh $env_name env plan --teardown
tf.sh $env_name env apply --teardown
tf.sh $env_name env plan --destroy
tf.sh $env_name env destroy
sweep.sh $env_name
sweep.sh mgmt"

n=0
while read -r script args; do
  n=$((n + 1))
  printf '\n### step %s: aws/scripts/%s\n' "$n" "$(oneline <<<"$script $args")"
  # shellcheck disable=SC2086 # the arguments of the step, one word each
  bash "$scripts_dir/$script" --print $args
done <<<"$steps"
