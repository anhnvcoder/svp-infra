#!/usr/bin/env bash
# The session in order, as docs/runbooks/session-<env>.md runs it. --print shows every command of every step, in the
# order they run, and runs nothing. up and down run the steps that build and remove the environment, each by its own
# script (this file adds none of their logic); check runs the core checks a script can read, and lists the ones only a
# person can do. The drills and the k6 ladder stay in the runbook.

# up and down stop at the first red step, and before each apply ask the learner, at the terminal, to read the plan's
# text and type yes; they refuse to run with their input from a pipe or a file. Each step done is marked in the
# session's timeline, so a second run starts after the last step done; a red apply starts again at its plan.

# Usage: aws/scripts/session.sh --print|up|check|down stg|prd
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
cmd=${1:-}
case $cmd in
  --print | up | check | down) ;;
  *) fail "usage: $(basename "$0") --print|up|check|down $(env_names session)" ;;
esac
shift
[ $# -eq 1 ] || fail "usage: $(basename "$0") --print|up|check|down $(env_names session)"
env_arg "$1"

# The steps of up and down, one per line: the command, the environments it runs for (all, or one name), tunnel when
# it reaches the cluster's API, the plan file a step writes (path under the repository root) and the name of its text
# in the session directory (- when it writes none), then the step: a script of this directory and its arguments,
# warm_cache, or hand with a page of docs/runbooks and what to do there (prd's flags, promote gate and snapshots).
e=$env_name
session_steps="up prd - - - hand session-prd.md#đổi-cờ-prd-trước-buổi set the flags of prd to production (merged PR, three roots applied)
up prd - - - hand session-prd.md#cổng-promote-prd-trước-mọi-lệnh-tốn-tiền steps 1 to 3 of the promote gate (promote-prd run, PR merged)
up prd - - - preflight.sh promote
up all - - - preflight.sh plugin
up all - - - check-account.sh $e
up all - - - check-dns.sh $e
up all - - - tf.sh $e account init
up all - aws/accounts/$e/$e.account-open.tfplan $e-account-open-plan.txt tf.sh $e account plan --open
up all - - - tf.sh $e account apply
up all - - - tf.sh $e env init
up all - - - media-signing-key.sh $e new a
up all - aws/envs/$e/$e.tfplan $e-env-plan.txt tf.sh $e env plan
up all - - - tf.sh $e env apply
up all - - - media-signing-key.sh $e activate a
up all - - - bootstrap.sh $e secrets
up all - - - warm_cache
up all - - - tf.sh $e gitops init
up all tunnel aws/gitops/$e/$e.tfplan $e-gitops-plan.txt tf.sh $e gitops plan
up all tunnel - - tf.sh $e gitops apply
up all tunnel - - bootstrap.sh $e wait
down all tunnel - - pre-destroy.sh $e
down all tunnel aws/gitops/$e/$e.destroy.tfplan $e-gitops-destroy-plan.txt tf.sh $e gitops plan --destroy
down all tunnel - - tf.sh $e gitops destroy
down all - aws/envs/$e/$e.teardown.tfplan $e-env-teardown-plan.txt tf.sh $e env plan --teardown
down all - - - tf.sh $e env apply --teardown
down all - - - restore-drill.sh $e cleanup
down all - aws/envs/$e/$e.destroy.tfplan $e-env-destroy-plan.txt tf.sh $e env plan --destroy
down all - - - tf.sh $e env destroy
down all - aws/accounts/$e/$e.account-close.tfplan $e-account-close-plan.txt tf.sh $e account plan --close
down all - - - tf.sh $e account apply
down prd - - - hand session-prd.md#gỡ-quét-sót-trả-cờ step 2: read the recovery points, delete the final snapshot and automated backups
down all - - - sweep.sh $e
down all - - - sweep.sh mgmt
down prd - - - hand session-prd.md#gỡ-quét-sót-trả-cờ step 5: set the flags of prd back to the cheap values (merged PR, roots applied)
down prd - - - sweep.sh $e"

# The core checks a person does, one per line: the environments it is for (all, or one name), what it needs that no
# script has (a browser, a mailbox, a release through svp-gitops) or not scripted yet, then the start of its section's
# title in the check pages of step 16 (docs/runbooks/session-<env>*.md). The two envs' pages hold different core checks.
hand_checks='stg browser: Phát video và CORS của media (play a video on the web, read the CORS headers)
prd browser: Smoke, phát video và alarm (play the smoke video on the web, read the CORS headers)
stg mailbox: Alarm tới email (an alarm in ALARM, its email received)
prd mailbox: Đo 6: alarm page tới email (svp-prd-rds-storage-low in ALARM then OK, both emails received)
all commit: Deploy qua GitOps (a release of svp-backend promoted through svp-gitops, synced by Argo CD)
all not scripted: Nền tảng managed (d) (the interval of each rule group; its namespaces and alert manager are read above)
stg not scripted: Migration của release
prd not scripted: Migration của release ở prd
stg not scripted: Xác thực qua CloudFront
prd not scripted: Xác thực qua CloudFront ở prd
stg not scripted: Image của release dlq-replay ở ECR
stg not scripted: Uptime: probe và cảnh báo
prd not scripted: Uptime ở prd
stg not scripted: Bảo vệ của account (GuardDuty, flow log, log WAF, quét malware)
prd not scripted: Bảo vệ của account ở prd (GuardDuty, flow log, log WAF, quét malware)
prd not scripted: Data event S3 trong trail (read in the trail bucket of Log Archive, profile anhnv-log-ro)'

# ask QUESTION: true when the learner types yes at the terminal; nothing answers for them.
ask() {
  local answer=
  printf '%s\nType yes to go on, anything else stops: ' "$1"
  IFS= read -r answer || true
  [ "$answer" = yes ]
}

# warm_cache: the third-party images of the eks render of the environment (deploy/ci/image-list.sh of the code
# repository, against the clone of svp-gitops) pulled through the pull-through cache of its ECR by ecr-warm.sh.
warm_cache() {
  local list=$session/images-$env_name.txt
  (cd "$backend_dir" && deploy/ci/image-list.sh "$gitops_dir" "$env_name") >"$list" ||
    fail "deploy/ci/image-list.sh $gitops_dir $env_name in $backend_dir (needs Docker and the network)"
  ok "$(grep -c . <"$list") image(s) of the eks render of $env_name in $list"
  bash "$scripts_dir/ecr-warm.sh" "$env_name" "$list"
}

# last_done: the number of the last step of $cmd marked done in the session's timeline, 0 when none is.
last_done() {
  awk -F '\t' -v c="$cmd " 'index($3, c) == 1 { n = substr($3, length(c) + 1) + 0; if (n > last) last = n }
    END { print last + 0 }' "$session/timeline.tsv" 2>/dev/null || echo 0
}

# run_steps: the steps of $cmd for this environment, from the one after the last done; stops at a red step and at an
# answer other than yes. A plan step is not marked done: the step that applies its plan is, so a run after a red
# apply or a refused plan plans again. Nor is a step while the timeline is empty: check-account.sh starts it with
# session-start, as by hand (measure.sh counts its 3 hours from there); the steps before it only read, or ask.
run_steps() {
  local lines total last n=0 needs plan text script rest args=() summary
  [ -t 0 ] ||
    fail "$cmd asks before each apply and destroy, and only a person at a terminal answers: run it in the session's terminal, its input not from a pipe or a file"
  session_dir
  lines=$(awk -v c="$cmd" -v e="$env_name" '$1 == c && ($2 == "all" || $2 == e)' <<<"$session_steps")
  total=$(grep -c . <<<"$lines")
  last=$(last_done)
  if [ "$last" -ge "$total" ]; then
    ok "every step of $cmd $env_name ($total) is done in $session/timeline.tsv"
    return 0
  fi
  [ "$last" -eq 0 ] || note "steps 1 to $last of $cmd $env_name are done in $session/timeline.tsv"
  # The steps come on descriptor 4: standard input stays the terminal, for ask and for the scripts.
  while read -r -u 4 _ _ needs plan text script rest; do
    n=$((n + 1))
    [ "$n" -gt "$last" ] || continue
    [ "$n" -gt $((last + 1)) ] || note "$cmd $env_name starts at step $n of $total: $script${rest:+ $rest}"
    step "session.sh $cmd $env_name, step $n of $total: $script${rest:+ $rest}"
    if [ "$needs" = tunnel ]; then
      until (need_tunnel); do
        ask "Open the tunnel as the line above says, in a terminal of its own." ||
          { note "stopped before step $n; aws/scripts/session.sh $cmd $env_name starts there again"; exit 1; }
      done
    fi
    case $script in
      hand)
        ask "By hand: ${rest#* } (docs/runbooks/${rest%% *}). Done?" ||
          { note "stopped at step $n; aws/scripts/session.sh $cmd $env_name starts there again"; exit 1; }
        ;;
      warm_cache)
        (warm_cache) ||
          fail "step $n is red: fix what its FAIL line says, then aws/scripts/session.sh $cmd $env_name (it runs step $n again)"
        ;;
      *)
        read -r -a args <<<"$rest"
        bash "$scripts_dir/$script" "${args[@]}" ||
          fail "step $n is red: fix what its FAIL line says, then aws/scripts/session.sh $cmd $env_name (it runs step $n, aws/scripts/$script $rest, again)"
        ;;
    esac
    if [ "$plan" != - ]; then
      if [ ! -f "$infra_root/$plan" ]; then
        note "step $n wrote no plan ($plan): nothing for the next step to apply"
        continue
      fi
      summary=$(grep -E '^(Plan:|No changes\.)' "$session/$text" 2>/dev/null | head -n 1 || true)
      ask "Read $session/$text (${summary:-no Plan: line}) before the next step applies $plan. Apply it?" ||
        { note "stopped before applying $plan; aws/scripts/session.sh $cmd $env_name plans again"; exit 1; }
      continue
    fi
    [ -s "$session/timeline.tsv" ] || continue
    mark "$cmd $n: $script${rest:+ $rest}"
  done 4<<<"$lines"
  ok "every step of $cmd $env_name ($total) is done"
}

# --- check: each check prints ok lines, or a FAIL line and returns 1; none writes in AWS or the cluster ---

check_smoke() { bash "$scripts_dir/measure.sh" "$env_name" --smoke; }

check_findings() { bash "$scripts_dir/preflight.sh" findings "$env_name"; }

# The commit of svp-gitops that svp-root synced has status argocd/<env> success and is on main: the evidence of stg
# that promote-prd asks for. The commit goes in <env>-ref.txt of the session.
check_commit_status() {
  local rev state
  rev=$(kc -n argocd get applications.argoproj.io svp-root -o 'jsonpath={.status.sync.revision}') ||
    fail "kubectl get application svp-root"
  [[ $rev =~ ^[0-9a-f]{40}$ ]] || fail "svp-root synced revision '$rev', not a commit"
  printf '%s\n' "$rev" >"$session/$env_name-ref.txt"
  state=$(run_ gh api "repos/anhnvcoder/svp-gitops/commits/$rev/statuses" \
    --jq ".[] | select(.context == \"argocd/$env_name\") | .state" | head -n 1) || fail "gh api statuses of $rev"
  [ "$state" = success ] || fail "commit status argocd/$env_name of $rev is '${state:-none}', not success"
  run_ git -C "$gitops_dir" fetch -q origin || fail "git fetch origin in $gitops_dir"
  run_ git -C "$gitops_dir" merge-base --is-ancestor "$rev" refs/remotes/origin/main ||
    fail "$rev is not on origin/main of svp-gitops"
  ok "svp-root at $rev (in $session/$env_name-ref.txt): argocd/$env_name success, on main"
}

# The rule namespaces of the chart and the alert manager of the account's AMP workspace are ACTIVE (a rule interval
# below the quota leaves its namespace CREATION_FAILED).
check_amp_rules() {
  local ws ns n status
  ws=$(tf_ "$infra_root/aws/accounts/$env_name" output -raw amp_workspace_id) ||
    fail "terraform output amp_workspace_id of aws/accounts/$env_name"
  ns=$(aws_ amp list-rule-groups-namespaces --workspace-id "$ws" \
    --query 'ruleGroupsNamespaces[].[name,status.statusCode]' --output text) || fail "amp list-rule-groups-namespaces"
  for n in svp-alerts slo-generated; do
    status=$(awk -v n="$n" '$1 == n { print $2 }' <<<"$ns")
    [ "$status" = ACTIVE ] || fail "rule namespace $n of AMP is '${status:-absent}', not ACTIVE"
  done
  status=$(aws_ amp describe-alert-manager-definition --workspace-id "$ws" \
    --query 'alertManagerDefinition.status.statusCode' --output text) || fail "amp describe-alert-manager-definition"
  [ "$status" = ACTIVE ] || fail "alert manager definition of AMP is '$status', not ACTIVE"
  ok "AMP: namespaces svp-alerts and slo-generated ACTIVE, alert manager ACTIVE"
}

# (a) media-worker runs mediaconvert, and the job of every job record of the media bucket is COMPLETE on the queue of
# the environment, with no record failed before its job. A second job of the same video (a retried CreateJob) is
# counted, not failed. The jobs and the records are copied into the session.
check_transcode_a() {
  local values=$session/cluster-values.json media args counts bad
  args=$(kc -n svp get deploy media-worker \
    -o 'jsonpath={.spec.template.spec.containers[?(@.name=="media-worker")].args}') || fail "kubectl get deploy media-worker"
  [ "$args" = '["mediaconvert"]' ] || fail "media-worker runs '$args', not [\"mediaconvert\"]"
  media=$(jq -r '.mediaBucket // empty' "$values" 2>/dev/null) || true
  [ -n "$media" ] || fail "no mediaBucket in $values (bootstrap.sh $env_name secrets writes it)"
  aws_ mediaconvert list-jobs --queue "svp-$env_name" --output json >"$session/mediaconvert-jobs.json" ||
    fail "mediaconvert list-jobs of queue svp-$env_name"
  mkdir -p "$session/transcode-jobs" || fail "create $session/transcode-jobs"
  aws_ s3 sync "s3://$media/transcode-jobs/" "$session/transcode-jobs/" --only-show-errors ||
    fail "s3 sync of the job records"
  counts=$(find "$session/transcode-jobs" -name '*.json' -exec jq -c \
    '{video: (input_filename | split("/")[-2]), job: .job_id, reason}' {} + 2>/dev/null |
    jq -rs --slurpfile all "$session/mediaconvert-jobs.json" '($all[0].Jobs | map({key: .Id, value: .Status}) | from_entries) as $st
      | map(.job | select(.)) as $own | map(.video) as $videos
      | (.[] | if .reason then "reason \(.reason)" else "record-job \($st[.job] // "MISSING")" end),
        ($all[0].Jobs[] | select((.UserMetadata.video_id | IN($videos[])) and (.Id | IN($own[]) | not)) | "orphan-job \(.Status)")' |
    sort | uniq -c) || fail "count the job records against $session/mediaconvert-jobs.json"
  printf '%s\n' "$counts" | sed 's/^ */      /'
  grep -q ' record-job COMPLETE$' <<<"$counts" || fail "no job record with a COMPLETE job (has the smoke run?)"
  bad=$(grep -E ' (record-job|reason) ' <<<"$counts" | grep -v ' record-job COMPLETE$' || true)
  [ -z "$bad" ] ||
    fail "job records not COMPLETE: $(oneline <<<"$bad"); jq -c '.Jobs[] | select(.Status != \"COMPLETE\")' $session/mediaconvert-jobs.json"
  ok "media-worker runs mediaconvert; every job record's job COMPLETE"
}

# (f) Both queues of the transcode events empty, the DLQ alarm not in ALARM, no event dropped by media-worker.
check_transcode_f() {
  local q url counts state logs dropped
  for q in "svp-$env_name-transcode-events" "svp-$env_name-transcode-events-dlq"; do
    url=$(aws_ sqs get-queue-url --queue-name "$q" --query QueueUrl --output text) || fail "sqs get-queue-url $q"
    counts=$(aws_ sqs get-queue-attributes --queue-url "$url" --output text \
      --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
      --query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]') ||
      fail "sqs get-queue-attributes $q"
    [ "$(oneline <<<"$counts" | tr -s ' \t' ' ')" = "0 0" ] ||
      fail "queue $q holds $(oneline <<<"$counts") (visible, in flight): read again in a minute, then transcode-events-dlq.md"
  done
  state=$(aws_ cloudwatch describe-alarms --alarm-names "svp-$env_name-transcode-events-dlq" --output text \
    --query 'MetricAlarms[].StateValue') || fail "cloudwatch describe-alarms"
  case $state in OK | INSUFFICIENT_DATA) ;; *) fail "alarm svp-$env_name-transcode-events-dlq is '$state'" ;; esac
  logs=$(kc -n svp logs deploy/media-worker --since=3h) || fail "kubectl logs deploy/media-worker"
  dropped=$(grep -c -E 'transcode event (ignored|interrupted)|transcode result undecided' <<<"$logs" || true)
  [ "${dropped:-0}" = 0 ] || fail "media-worker logged $dropped dropped or undecided transcode event(s) in 3 h"
  ok "transcode queues empty, alarm $state, no event dropped"
}

# The mesh: no node keeps the startup taint, istiod, istio-cni and ztunnel ready on every node, the waypoint ready,
# every running pod of svp and Envoy captured, a STRICT PeerAuthentication and an AuthorizationPolicy per release.
check_mesh() {
  local nodes n tainted j bad pa
  nodes=$(kc get nodes -o json) || fail "kubectl get nodes"
  n=$(jq '.items | length' <<<"$nodes")
  tainted=$(jq '[.items[] | select(any(.spec.taints[]?; .key == "cni.istio.io/not-ready"))] | length' <<<"$nodes")
  [ "$tainted" = 0 ] || fail "$tainted of $n node(s) keep taint cni.istio.io/not-ready: the mesh is not ready there"
  j=$(kc -n istio-system get deploy,daemonset -o json) || fail "kubectl get deploy,daemonset -n istio-system"
  bad=$(jq -r --argjson n "$n" '[.items[] | select(
      (.kind == "Deployment" and .metadata.name == "istiod" and ((.status.readyReplicas // 0) < 1 or .status.readyReplicas != .spec.replicas))
      or (.kind == "DaemonSet" and (.metadata.name | IN("istio-cni-node", "ztunnel"))
        and (.status.desiredNumberScheduled != $n or (.status.numberReady // 0) != $n)))
    | .metadata.name] + ([("istiod", "istio-cni-node", "ztunnel")] - [.items[].metadata.name]) | join(" ")' <<<"$j")
  [ -z "$bad" ] || fail "not ready on all $n node(s), or absent: $bad"
  j=$(kc -n svp-mesh get deploy waypoint -o json) || fail "kubectl get deploy waypoint -n svp-mesh"
  jq -e '(.status.readyReplicas // 0) >= 1 and .status.readyReplicas == .spec.replicas' <<<"$j" >/dev/null ||
    fail "waypoint of svp-mesh not ready"
  j=$({
    kc -n svp get pods --field-selector=status.phase=Running -o json &&
      kc -n envoy-gateway-system get pods -l gateway.envoyproxy.io/owning-gateway-name=svp -o json
  }) || fail "kubectl get pods of svp and Envoy"
  bad=$(jq -rs '[.[].items[] | select(.metadata.annotations["ambient.istio.io/redirection"] != "enabled") | .metadata.name] | join(" ")' <<<"$j")
  [ -z "$bad" ] || fail "pods not in the mesh (ambient.istio.io/redirection not enabled): $bad"
  j=$(kc -n svp get peerauthentications.security.istio.io -o json) || fail "kubectl get peerauthentications -n svp"
  pa=$(jq '.items | length' <<<"$j")
  jq -e '(.items | length) > 0 and all(.items[]; .spec.mtls.mode == "STRICT")' <<<"$j" >/dev/null ||
    fail "PeerAuthentications of svp: none, or one not STRICT"
  j=$(kc -n svp get authorizationpolicies.security.istio.io -o json) || fail "kubectl get authorizationpolicies -n svp"
  [ "$(jq '.items | length' <<<"$j")" -ge "$pa" ] || fail "fewer AuthorizationPolicies than PeerAuthentications in svp"
  ok "mesh on $n node(s): no taint left, istiod, istio-cni, ztunnel, waypoint ready, pods captured, $pa release(s) STRICT"
}

# The checks in the order the runbook runs them: the smoke first (transcode (a) reads its videos), (f) and the
# findings last.
auto_checks='check_smoke smoke (measure.sh --smoke)
check_commit_status commit status argocd/<env>
check_amp_rules alert rules on AMP
check_transcode_a transcode (a): media-worker runs mediaconvert
check_mesh service mesh
check_transcode_f transcode (f): queues empty
check_findings security findings (preflight.sh findings)'

run_checks() {
  local fn name results='' failures=0
  session_dir
  check_account
  need_tunnel
  while read -r -u 4 fn name; do
    name=${name//<env>/$env_name}
    step "session.sh check $env_name: $name"
    if ($fn); then
      results+="PASS    $name"$'\n'
    else
      results+="FAIL    $name"$'\n'
      failures=$((failures + 1))
    fi
  done 4<<<"$auto_checks"
  printf '\n== session.sh check %s\n%s' "$env_name" "$results"
  awk -v e="$env_name" '$1 == "all" || $1 == e { sub(/^[^ ]+ /, ""); printf "HAND    %s, docs/runbooks/session-%s*.md\n", $0, e }' \
    <<<"$hand_checks"
  [ "$failures" -eq 0 ] || fail "$failures check(s) of $env_name failed: read their FAIL lines above"
  ok "every scripted core check of $env_name passed; the HAND lines are the learner's"
}

case $cmd in
  up | down)
    run_steps
    exit 0
    ;;
  check)
    run_checks
    exit 0
    ;;
esac

# --print: the steps, one per line: the script and its arguments, in the order of the runbook's table of steps.
steps="check-account.sh $env_name
check-dns.sh $env_name
tf.sh $env_name account init
tf.sh $env_name account plan --open
tf.sh $env_name account apply
tf.sh $env_name env init
media-signing-key.sh $env_name new a
tf.sh $env_name env plan
tf.sh $env_name env apply
media-signing-key.sh $env_name activate a
bootstrap.sh $env_name secrets
tf.sh $env_name gitops init
tf.sh $env_name gitops plan
tf.sh $env_name gitops apply
bootstrap.sh $env_name wait
measure.sh $env_name
restore-drill.sh $env_name backup
restore-drill.sh $env_name rds
restore-drill.sh $env_name s3
pre-destroy.sh $env_name
tf.sh $env_name gitops plan --destroy
tf.sh $env_name gitops destroy
tf.sh $env_name env plan --teardown
tf.sh $env_name env apply --teardown
restore-drill.sh $env_name cleanup
tf.sh $env_name env plan --destroy
tf.sh $env_name env destroy
tf.sh $env_name account plan --close
tf.sh $env_name account apply
sweep.sh $env_name
sweep.sh mgmt"

n=0
while read -r script args; do
  n=$((n + 1))
  printf '\n### step %s: aws/scripts/%s\n' "$n" "$(oneline <<<"$script $args")"
  # shellcheck disable=SC2086 # the arguments of the step, one word each
  bash "$scripts_dir/$script" --print $args
done <<<"$steps"
