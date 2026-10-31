#!/usr/bin/env bash
# The measurements of a session, after bootstrap-argocd.sh: everything into $SVP_SESSION_DIR. The account of the
# profile is checked first, as check-account.sh checks it.
#   1. make eks-smoke: the end-to-end flow through https://api.<domain> (domain of cluster-values.json)
#   2. make eks-seed: at least 30 READY videos in GET /feed/explore, which the k6 profile cloud reads
#   3. k6 profile cloud (deploy/k6/cloud/run.sh of the code repository) at 1, 2, 4 and 8 pods, each pod the load of one
#      pod of the 20-pod design, 2 min up and 10 min held; the first level that fails ends the ladder. Each level:
#      make eks-rl-reset (every pod registers its users from its own address, and a pod of a later level may get the
#      address of an earlier one), the Job of an earlier level deleted, start, wait for the Job to end while sampling
#      the nodes (k6-<n>/nodes.tsv) and kubectl top of nodes and pods (top-nodes.tsv, top-pods.tsv), run.sh logs, the
#      pods' summaries copied into k6-<n>/summaries/, the Job deleted. A level passes when every pod wrote its summary
#      with every threshold passed, no dropped iteration and no 429.
# A node of the level's start that leaves or turns NotReady before the Job ends (a Spot interruption, most likely) makes
# the level "interrupted", not failed: the load did not run on the cluster it was measured for. The script stops there
# with exit 3; aws/scripts/measure.sh stg --from <n> runs the ladder again from that level (no smoke, no seed).
# The session has 4 hours, and measuring stops at 3: a level that could not end before 3 hours after session-start of
# the timeline is skipped, and the session goes on to pre-destroy.
# A level whose wait runs out while the last read of its Job failed (SSO session expired, network gone) is "error": a
# failure of the tooling, not of the system. Its Job is left as it is (it may still be running, its logs would be of
# pods not done), and the script stops with exit 1; once the profile reads again, measure.sh stg --from <n> deletes
# that Job and runs the level again.
# Results: k6-levels.tsv (level, result, reason) and the timeline; exit 0 once the ladder has ended (a failed level is
# a result), 1 when the smoke, the seed or a level's tooling failed (error), 3 on a level interrupted.
#
# Usage: aws/scripts/measure.sh [--print] stg [--from 1|2|4|8]
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
usage="usage: $(basename "$0") [--print] stg [--from 1|2|4|8]"
env_arg "${1:-}"
from=
case "${2:-} ${3:-}" in
  ' ') ;;
  '--from 1' | '--from 2' | '--from 4' | '--from 8') from=$3 ;;
  *) fail "$usage" ;;
esac
[ $# -le 3 ] || fail "$usage"
session_dir

levels="1 2 4 8"
ramp=2m
hold=10m
# Up to setup's end, 2 min up, 10 held, 1 down, the summaries: a level whose Job has not ended in 30 min is stuck.
# The self-test sets a few seconds.
level_limit=${SVP_MEASURE_LEVEL_LIMIT:-1800}
session_limit=10800
run_sh=$backend_dir/deploy/k6/cloud/run.sh

if printing; then
  domain='<domain of cluster-values.json>'
else
  domain=$(jq -r '.domain // empty' "$session/cluster-values.json" 2>/dev/null) || domain=
  [ -n "$domain" ] || fail "no domain in $session/cluster-values.json: run aws/scripts/bootstrap-argocd.sh $env_name first"
fi

k6_() { run_ "AWS_PROFILE=$profile" bash "$run_sh" --context "$context" --domain "$domain" "$@"; }

# ready_nodes: names of the nodes whose condition Ready is True, one per line, sorted.
ready_nodes() {
  local out
  out=$(kc get nodes -o json) || return 1
  printing && return 0
  jq -r '.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .metadata.name' <<<"$out" |
    LC_ALL=C sort
}

# stamp TIME: the lines of stdin, each after TIME and a tab.
stamp() { awk -v t="$1" '{ print t "\t" $0 }'; }

# sample DIR: one sample of the level: Ready nodes (nodes.tsv), kubectl top of nodes and of every pod (top-*.tsv),
# and any node of the level's start that is gone or NotReady (lost).
sample() {
  local dir=$1 t now_ready lost
  t=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  now_ready=$(ready_nodes) || {
    printing || note "kubectl get nodes failed at $t"
    return 0
  }
  local top_nodes top_pods
  top_nodes=$(kc top nodes --no-headers 2>/dev/null) || top_nodes=
  top_pods=$(kc top pods -A --no-headers 2>/dev/null) || top_pods=
  printing && return 0
  printf '%s\t%s\t%s\n' "$t" "$(grep -c . <<<"$now_ready" || true)" "$(oneline <<<"$now_ready")" >>"$dir/nodes.tsv"
  [ -z "$top_nodes" ] || stamp "$t" <<<"$top_nodes" >>"$dir/top-nodes.tsv"
  [ -z "$top_pods" ] || stamp "$t" <<<"$top_pods" >>"$dir/top-pods.tsv"
  lost=$(LC_ALL=C comm -23 "$dir/nodes.start" <(printf '%s\n' "$now_ready") | grep . || true)
  if [ -n "$lost" ] && [ ! -s "$dir/lost" ]; then
    printf '%s\t%s\n' "$t" "$(oneline <<<"$lost")" >"$dir/lost"
    note "node(s) $(oneline <<<"$lost") of the level's start gone or NotReady at $t (Spot interruption?)"
  fi
}

# job_ended DIR: samples, then true once Job svp-load/svp-k6 has condition Complete or Failed (or is gone). Sets
# job_read to whether this read of the Job succeeded.
job_ended() {
  local dir=$1 job
  sample "$dir"
  job_read=
  # A failed read (Wi-Fi gone, SSO session expired) is a poll lost, not the end of the Job: reading the logs of pods
  # still running would count the level failed and delete its Job. Only a Job that is gone (deleted by hand) has ended
  # unseen; its logs are then read and found missing.
  if ! job=$(kc -n svp-load get job svp-k6 --ignore-not-found -o json 2>/dev/null); then
    note "kubectl get job svp-load/svp-k6 failed at $(date -u +%H:%M:%SZ); waiting on"
    return 1
  fi
  job_read=1
  printing && return 0
  [ -n "$job" ] || return 0
  jq -e 'any(.status.conditions[]?; (.type == "Complete" or .type == "Failed") and .status == "True")' <<<"$job" >/dev/null
}

# level N: one level of the ladder; sets result and reason.
level() {
  local n=$1 dir=$session/k6-$1 out summaries rc=0 bad=
  result='' reason='' job_read=
  if ! printing; then
    # A run again with --from keeps the earlier try of this level beside the new one, under its time.
    if [ -e "$dir" ]; then
      mv "$dir" "$dir.$(date -u +%Y%m%dT%H%M%SZ)" || fail "move the earlier $dir aside"
    fi
    { mkdir -p "$dir" && : >"$dir/nodes.tsv"; } || fail "create $dir"
  fi
  mark "k6-$n-start"
  make_ eks-rl-reset "CONTEXT=$context" || fail "make eks-rl-reset before level $n"
  k6_ delete >/dev/null || fail "delete the Job of an earlier level (run.sh delete)"
  if printing; then
    ready_nodes
  else
    ready_nodes >"$dir/nodes.start" || fail "kubectl get nodes before level $n"
    note "level $n starts on $(grep -c . "$dir/nodes.start" || true) Ready node(s): $(oneline <"$dir/nodes.start")"
  fi
  k6_ --pods "$n" --ramp "$ramp" --hold "$hold" start || fail "run.sh start with $n pod(s)"
  if ! wait_until "Job svp-load/svp-k6 of level $n has ended" "$level_limit" job_ended "$dir"; then
    if [ -z "$job_read" ]; then
      # Not a result of the system: whether the Job ended is unknown. No logs read, the Job not deleted.
      result=error reason="Job svp-load/svp-k6 could not be read at the last poll within $level_limit s (expired SSO session? network?)"
      mark "k6-$n-error"
      return 0
    fi
    result=fail reason="the Job did not end within $level_limit s"
  fi
  out=$(k6_ logs 2>&1) || rc=$?
  if ! printing; then
    printf '%s\n' "$out" >"$dir/logs.txt"
    printf '%s\n' "$out"
    summaries=$(sed -n 's/^summaries in //p' <<<"$out" | tail -n 1)
    if [ -n "$summaries" ] && [ -d "$backend_dir/$summaries" ]; then
      cp -R "$backend_dir/$summaries" "$dir/summaries" || fail "copy $backend_dir/$summaries"
    fi
    if [ -z "$result" ]; then
      if [ "$rc" -ne 0 ]; then
        result=fail reason="run.sh logs exit $rc (a pod without summary, or a summary that looked like a secret)"
      elif [ "$(find "$dir/summaries" -name 'pod-*.json' 2>/dev/null | grep -c . || true)" != "$n" ]; then
        result=fail reason="not $n pod summaries"
      else
        bad=$(for f in "$dir"/summaries/pod-*.json; do
          jq -r --arg f "$(basename "$f" .json)" '
            if .thresholds_ok != true then "\($f) thresholds"
            elif .dropped_iterations != 0 then "\($f) dropped_iterations \(.dropped_iterations)"
            elif ([.routes[]?.rate_limited] | add // 0) != 0 then "\($f) 429"
            else empty end' "$f" || echo "$(basename "$f") unreadable"
        done)
        if [ -n "$bad" ]; then
          result=fail reason="$(oneline <<<"$bad")"
        else
          result=pass reason="every pod: thresholds passed, no dropped iteration, no 429"
        fi
      fi
    fi
    # A node lost during the level outranks its numbers, passed or failed: they are not of the cluster measured.
    if [ -s "$dir/lost" ]; then
      result=interrupted reason="node(s) lost: $(cut -f2 "$dir/lost") at $(cut -f1 "$dir/lost")"
    fi
    kc get events -A --field-selector involvedObject.kind=Node -o json >"$dir/node-events.json" 2>/dev/null || true
  fi
  k6_ delete >/dev/null || note "run.sh delete after level $n failed; the next level deletes it again"
  mark "k6-$n-end"
}

step "measure.sh: the account of profile $profile"
check_account

if [ -z "$from" ]; then
  step "measure.sh: smoke"
  make_ eks-smoke "CONTEXT=$context" "DOMAIN=$domain" || fail "make eks-smoke"
  mark smoke-ok
  ok "smoke passed through https://api.$domain"

  step "measure.sh: seed"
  make_ eks-seed "CONTEXT=$context" "DOMAIN=$domain" || fail "make eks-seed"
  mark seed-ok
  ok "at least 30 READY videos in GET /feed/explore"
fi

start_epoch=
if ! printing; then
  start_epoch=$(awk -F '\t' '$3 == "session-start" { print $2; exit }' "$session/timeline.tsv" 2>/dev/null) || start_epoch=
  [ -n "$start_epoch" ] || note "no session-start in the timeline (check-account.sh not run in this session): no 3-hour cut"
fi

started=
highest=0
for n in $levels; do
  if [ -n "$from" ] && [ -z "$started" ] && [ "$n" != "$from" ]; then
    continue
  fi
  started=1
  step "measure.sh: k6 level $n pod(s)"
  if [ -n "$start_epoch" ] && [ $(($(date +%s) - start_epoch + level_limit)) -gt "$session_limit" ]; then
    skip "level $n and above: they would end past 3 hours of the session; go on to pre-destroy"
    printf '%s\t%s\t%s\n' "$n" skipped "past 3 hours of the session" >>"$session/k6-levels.tsv"
    mark measure-cut
    break
  fi
  level "$n"
  printing && continue
  printf '%s\t%s\t%s\n' "$n" "$result" "$reason" >>"$session/k6-levels.tsv"
  case $result in
    pass) ok "level $n: $reason"; highest=$n ;;
    interrupted)
      note "level $n interrupted: $reason; not a failure of the system. Run again: aws/scripts/measure.sh $env_name --from $n"
      exit 3
      ;;
    error)
      fail "level $n: $reason; its Job is left as it is. Once AWS_PROFILE=$profile aws sts get-caller-identity --region $region answers (AWS_PROFILE=$profile aws sso login), run again: aws/scripts/measure.sh $env_name --from $n"
      ;;
    *)
      printf 'FAIL  level %s: %s\n' "$n" "$reason"
      break
      ;;
  esac
done
printing && exit 0
mark measure-end
ok "highest level passed: $highest pod(s) (levels in $session/k6-levels.tsv)"
