#!/usr/bin/env bash
# The reads that come before and during a session, in place of the commands typed from the runbooks: quotas (EC2 and
# AMP, the one subcommand that can write, and only as "quotas <env> request"), freetier (Free plan, CloudFront plans),
# eks-upgrade (versions of the next EKS minor), findings (security findings and the backup copy of a session) and
# promote (the git checks of the prd promote gate). Every other command only reads.

# Each check prints one line, ok, FAIL or note; a FAIL does not stop the other checks of quotas, freetier, findings and
# promote. findings runs under profiles other than the environment's (profiles.sh), promote calls no aws.

# Usage: aws/scripts/preflight.sh [--print] quotas stg|prd [request]
#        aws/scripts/preflight.sh [--print] freetier|eks-upgrade stg|prd
#        aws/scripts/preflight.sh [--print] findings stg|prd      (SVP_SESSION_DIR of the session)
#        aws/scripts/preflight.sh [--print] promote
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=aws/scripts/profiles.sh
. "$(dirname "$0")/profiles.sh"
printing && shift
usage="usage: $(basename "$0") [--print] quotas stg|prd [request] | freetier|eks-upgrade|findings stg|prd | promote"
sub=${1:-}
[ $# -ge 1 ] || fail "$usage"
shift
mode=
case $sub:$# in
  quotas:1 | quotas:2)
    env_arg "$1"
    mode=${2:-}
    case $mode in '' | request) ;; *) fail "$usage" ;; esac
    ;;
  freetier:1 | eks-upgrade:1 | findings:1) env_arg "$1" ;;
  promote:0) ;;
  *) fail "$usage" ;;
esac

failures=0
# chk FUNCTION [ARG...]: runs one check in a subshell so that its FAIL (an exit 1) does not stop the next one. The
# subshell runs in an if, where errexit is off: every command of a check that can fail ends in || fail.
chk() {
  if ( "$@" ); then :; else failures=$((failures + 1)); fi
}

# aws_in REGION ARGS...: aws in a region other than the two of lib.sh.
aws_in() {
  local r=$1
  shift
  run_ "AWS_PROFILE=$profile" aws "$@" --region "$r"
}

# use_profile PROFILE: the profile of the following commands, and its account checked against its variable; the ARN
# of the caller is not repeated. Returns 1 (counted) when the account is wrong, so the caller skips that profile.
use_profile() {
  local line
  profile_arg "$1"
  if line=$(check_account); then
    [ -z "$line" ] || printf '%s\n' "${line%%, arn:*}"
    return 0
  fi
  failures=$((failures + 1))
  return 1
}

# flat: stdin on one line, tabs and newlines as spaces.
flat() { tr '\t\n' '  ' | sed 's/ *$//'; }

# --- quotas ---

# The quotas the runbooks read, one line each: environment, service code, quota code (- for the AMP rule interval,
# whose code is looked up by name), min or max, the figure, then the name. A figure cpu+A:N is A plus limits.cpu of the
# NodePool in svp-gitops, at least N (cpu:N: A is 0). The floors are the strictest of aws/org/README.md and runbooks.
quota_table='stg ec2 L-1216C47A min 10 vCPU on-demand (Standard)
stg ec2 L-34B43A08 min cpu:10 vCPU Spot (Standard)
stg ec2 L-0263D0A3 min 1 Elastic IP
stg aps - max 15 AMP rule evaluation interval (seconds)
prd ec2 L-1216C47A min cpu+14:16 vCPU on-demand (Standard)
prd ec2 L-0263D0A3 min 3 Elastic IP
prd aps - max 15 AMP rule evaluation interval (seconds)'

# quota_need FIGURE: the number a figure of quota_table stands for. limits.cpu is read on origin/main of the gitops
# clone, from the environment's overlay or else the base file of the platform, as Argo CD merges them.
quota_need() {
  local floor=${1#*:} add=0 f cpu=
  case $1 in cpu*) ;; *)
    printf '%s\n' "$1"
    return 0
    ;;
  esac
  case $1 in cpu+*)
    add=${1%%:*}
    add=${add#cpu+}
    ;;
  esac
  for f in "envs/$env_name/svp-cluster.yaml" platforms/eks/svp-cluster.yaml; do
    cpu=$(run_ git -C "$gitops_dir" show "origin/main:$f" 2>/dev/null |
      awk '/^karpenter:/ { k = 1; next } /^[^ #]/ { k = 0 } k && /^ *limits:/ { l = 1; next } l && /^ *cpu:/ { print $2; exit }') ||
      true
    [ -z "$cpu" ] || break
  done
  if printing; then
    f=
    [ "$add" = 0 ] || f="$add + "
    printf '<%slimits.cpu, at least %s>\n' "$f" "$floor"
    return 0
  fi
  if [[ $cpu =~ ^[0-9]+$ ]]; then
    if [ $((add + cpu)) -gt "$floor" ]; then floor=$((add + cpu)); fi
  else
    note "no limits.cpu in envs/$env_name/svp-cluster.yaml or $f on origin/main of $gitops_dir: the floor $floor is used" >&2
  fi
  printf '%s\n' "$floor"
}

# quota_row SERVICE CODE DIRECTION FIGURE NAME...: one quota against what the runbook needs; in request mode a missing
# one is asked for, unless a request is already open.
quota_row() {
  local svc=$1 code=$2 dir=$3 need name val pending line cmp
  need=$(quota_need "$4")
  shift 4
  name=$*
  if [ "$code" = - ]; then
    line=$(aws_ service-quotas list-aws-default-service-quotas --service-code "$svc" \
      --query "Quotas[?contains(QuotaName, 'valuation interval')].[QuotaCode,QuotaName,Value,Adjustable]" --output text) ||
      fail "service-quotas list-aws-default-service-quotas for $svc with profile $profile"
    if printing; then
      code='<QuotaCode>'
    else
      [ "$(grep -c . <<<"$line")" = 1 ] ||
        fail "$name: the default quotas of $svc hold $(grep -c . <<<"$line" || true) line(s) with 'valuation interval', not 1: $(flat <<<"$line")"
      code=${line%%[[:space:]]*}
    fi
  fi
  val=$(aws_ service-quotas get-service-quota --service-code "$svc" --quota-code "$code" --query Quota.Value --output text) ||
    fail "service-quotas get-service-quota $svc $code with profile $profile"
  pending=$(aws_ service-quotas list-requested-service-quota-change-history-by-quota --service-code "$svc" --quota-code "$code" \
    --query "RequestedQuotas[?Status=='PENDING'||Status=='CASE_OPENED'].[Id,Status,DesiredValue]" --output text) ||
    fail "service-quotas list-requested-service-quota-change-history-by-quota $svc $code with profile $profile"
  if [ "$mode" = request ]; then
    printing && aws_ service-quotas request-service-quota-increase --service-code "$svc" --quota-code "$code" \
      --desired-value "$need" --query 'RequestedQuota.[Id,Status]' --output text
  fi
  printing && return 0
  [ "$dir" = min ] && cmp='a >= b' || cmp='a <= b'
  if awk -v a="$val" -v b="$need" "BEGIN { exit !($cmp) }"; then
    ok "$code $name: $val ($dir $need)"
    return 0
  fi
  if [ -n "$pending" ]; then
    if [ "$mode" = request ]; then
      note "$code $name: $val ($dir $need), a request is already open ($(flat <<<"$pending")): not sent again"
      return 0
    fi
    fail "$code $name: $val, needs $dir $need; a request is open ($(flat <<<"$pending")): wait for APPROVED, then run this again"
  fi
  if [ "$mode" = request ]; then
    line=$(aws_ service-quotas request-service-quota-increase --service-code "$svc" --quota-code "$code" \
      --desired-value "$need" --query 'RequestedQuota.[Id,Status]' --output text) ||
      fail "service-quotas request-service-quota-increase $svc $code to $need with profile $profile (Support case instead? platform-setup.md step 8)"
    note "$code $name: $val, asked for $need ($(flat <<<"$line")): wait for APPROVED, then run quotas again"
    return 0
  fi
  fail "$code $name: $val, needs $dir $need: run $(basename "$0") quotas $env_name request"
}

quotas() {
  local svc code dir fig name
  step "preflight.sh quotas $env_name${mode:+ $mode}"
  check_account
  while read -r _ svc code dir fig name; do
    chk quota_row "$svc" "$code" "$dir" "$fig" "$name"
  done < <(awk -v e="$env_name" '$1 == e' <<<"$quota_table")
}

# --- freetier ---

# freetier: the CloudFront flat-rate plans of the account and its Free Tier state, both in us-east-1, as the runbooks'
# "Điều kiện trước buổi" read them. A plan left over holds one of the three Free slots with its distribution.
freetier() {
  step "preflight.sh freetier $env_name"
  check_account
  chk plans
  chk plan_state
}
plans() {
  local out n
  out=$(aws_global_ pricing-plan-manager list-subscriptions --query 'subscriptionSummaries[].[arn,planTier,status]' \
    --output json) || fail "pricing-plan-manager list-subscriptions with profile $profile"
  printing && return 0
  n=$(jq -er 'length' <<<"$out") || fail "unreadable answer of list-subscriptions"
  [ "$n" = 0 ] ||
    fail "$n CloudFront plan(s) left in $env_name ($(jq -r '[.[] | "\(.[1]) \(.[2])"] | join(", ")' <<<"$out")): cancel them (session runbook, Lệnh xoá tay theo loại) and read again"
  ok "no CloudFront flat-rate plan in $env_name"
}
plan_state() {
  local t
  # A member account of an organization has no account plan: joining upgrades a Free plan to paid, and the API answers
  # ResourceNotFoundException. Any other error stays a FAIL. Source (read 2026-11-19):
  # https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-plans.html
  if ! t=$(aws_global_ freetier get-account-plan-state --query accountPlanType --output text 2>&1); then
    case $t in
      *ResourceNotFoundException*)
        ok "account plan of $env_name is PAID (member of an organization, no account plan)"
        return 0
        ;;
      *) fail "freetier get-account-plan-state with profile $profile: $(flat <<<"$t")" ;;
    esac
  fi
  printing && return 0
  case $t in
    PAID) ok "account plan of $env_name is PAID" ;;
    FREE) fail "account plan of $env_name is FREE (AWS Free Tier): the flat-rate plan cannot be created; do not start the session" ;;
    *) fail "account plan of $env_name is '$t', not PAID" ;;
  esac
}

# --- eks-upgrade ---

# eks_next: the minor after kubernetes_version of the environment's tfvars, as cur and next (EKS never skips one).
eks_next() {
  local f=$env_root/$env_name.tfvars
  [ -f "$f" ] || fail "no $f: the file with kubernetes_version"
  cur=$(sed -n 's/^kubernetes_version[[:space:]]*=[[:space:]]*"\(1\.[0-9][0-9]*\)".*/\1/p' "$f" | head -n 1)
  [[ $cur =~ ^1\.[0-9]+$ ]] || fail "no kubernetes_version like \"1.NN\" in $f"
  next=1.$((${cur#1.} + 1))
}

# eks_upgrade: the lookups of step 1 of eks-upgrade.md for the minor after the one in tfvars. Step 2 (upgrade insights,
# deprecated APIs) needs the running cluster and Karpenter's table is a web page: both stay with the runbook.
eks_upgrade() {
  local cur next rows st a v rv day m ami
  eks_next
  step "preflight.sh eks-upgrade $env_name: $cur -> $next"
  check_account
  rows=$(aws_ eks describe-cluster-versions --query 'clusterVersions[].[clusterVersion,status,endOfStandardSupportDate]' \
    --output text) || fail "eks describe-cluster-versions with profile $profile"
  if ! printing; then
    st=$(awk -v m="$next" '$1 == m { print $2 " until " $3 }' <<<"$rows")
    [ -n "$st" ] || fail "EKS lists no minor $next ($(oneline <<<"$rows" | tr -s ' '))"
    case $st in
      STANDARD_SUPPORT*) ok "$(printf '%-30s %s' "EKS $next" "$st")" ;;
      *) fail "EKS $next is $st, not STANDARD_SUPPORT" ;;
    esac
  fi
  for a in vpc-cni kube-proxy coredns eks-pod-identity-agent aws-ebs-csi-driver metrics-server aws-guardduty-agent; do
    v=$(aws_ eks describe-addon-versions --addon-name "$a" --kubernetes-version "$next" \
      --query 'addons[0].addonVersions[0].addonVersion' --output text) || fail "eks describe-addon-versions $a for $next"
    printing && continue
    if [ -z "$v" ] || [ "$v" = None ]; then
      failures=$((failures + 1))
      printf 'FAIL  %s\n' "add-on $a has no version for EKS $next" >&2
    else
      ok "$(printf '%-30s %s' "add-on $a" "$v")"
    fi
  done
  rv=$(aws_ ssm get-parameter --query Parameter.Value --output text \
    --name "/aws/service/eks/optimized-ami/$next/amazon-linux-2023/arm64/standard/recommended/release_version") ||
    fail "ssm get-parameter release_version of $next"
  day='<day>'
  if ! printing; then
    [[ $rv =~ ^${next//./\\.}\.[0-9]+-[0-9]{8}$ ]] || fail "release_version '$rv' is not $next.<patch>-<yyyymmdd>"
    day=${rv##*-}
    ok "$(printf '%-30s %s' "AMI release_version" "$rv (alias al2023@v$day)")"
  fi
  # Karpenter resolves the alias by the minor the control plane runs, so the date needs an image for both minors.
  for m in "$cur" "$next"; do
    ami=$(aws_ ssm get-parameter --query Parameter.Value --output text \
      --name "/aws/service/eks/optimized-ami/$m/amazon-linux-2023/arm64/standard/amazon-eks-node-al2023-arm64-standard-$m-v$day/image_id") ||
      fail "ssm get-parameter image_id of $m at v$day: choose a release that exists for both minors (github.com/awslabs/amazon-eks-ami/releases)"
    printing && continue
    [[ $ami =~ ^ami-[0-9a-f]+$ ]] || fail "image id of $m at v$day is '$ami', not ami-..."
    ok "$(printf '%-30s %s' "AMI $m at v$day" "$ami")"
  done
  printing && return 0
  note "upgrade insights and deprecated-API metrics: eks-upgrade.md step 2, in a running stg session"
  note "Karpenter compatibility with $next: https://karpenter.sh/docs/upgrading/compatibility/"
}

# --- findings ---

# since_of_session: the start of the session, the first line of its timeline.tsv.
since_of_session() {
  if printing; then
    since='<session start>'
    return 0
  fi
  [ -f "$session/timeline.tsv" ] || fail "no $session/timeline.tsv: the session has not started (its first step marks it)"
  since=$(head -n 1 "$session/timeline.tsv" | cut -f 1)
  [[ $since =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    fail "first line of $session/timeline.tsv starts with '$since', not a UTC time like 2026-01-01T00:00:00Z"
}

# backup_copy: the recovery points of the session in the copy vault of svp-backup (profile anhnv-backup-ro). No ARN is
# printed: the key is compared here.
backup_copy() {
  local vault=svp-$env-copy k out rows bad
  k=$(aws_ backup describe-backup-vault --backup-vault-name "$vault" --query EncryptionKeyArn --output text) ||
    fail "backup describe-backup-vault $vault with profile $profile (profile missing? backup-setup.md steps 1, 2)"
  out=$(aws_ backup list-recovery-points-by-backup-vault --backup-vault-name "$vault" --by-created-after "$since" \
    --output json) || fail "backup list-recovery-points-by-backup-vault $vault with profile $profile"
  printing && return 0
  rows=$(jq -r --arg k "$k" '.RecoveryPoints[]? | [.ResourceType, .Status, .CreationDate, (.CalculatedLifecycle.DeleteAt // "-"),
    (if .EncryptionKeyArn == $k then "vault-key" else "other-key" end)] | @tsv' <<<"$out") || fail "unreadable answer of $vault"
  [ -n "$rows" ] || fail "no recovery point in $vault created after $since (step 17 of the session runbook not done, or its copy job not finished)"
  bad=$(awk -F '\t' '$2 != "COMPLETED" || $5 != "vault-key"' <<<"$rows")
  while IFS=$'\t' read -r t s c d kk; do
    note "$vault: $t $s created $c, deleted at $d, $kk"
  done <<<"$rows"
  [ -z "$bad" ] || fail "$(grep -c . <<<"$bad") recovery point(s) of $vault not COMPLETED or not under the key of the vault"
  ok "$vault: every recovery point COMPLETED under the key of the vault (DeleteAt - CreationDate: compare with ADR-0067 §4)"
}

# securityhub_controls: the FAILED controls of the account (profile anhnv-security-ro). Resource ids go to
# controls-failed.tsv of the session directory, which git ignores; only counts by control, severity, type are printed.
securityhub_controls() {
  local f out tmp
  f=$(jq -nc --arg a "$acc" '{AwsAccountId: [{Value: $a, Comparison: "EQUALS"}],
    RecordState: [{Value: "ACTIVE", Comparison: "EQUALS"}], ComplianceStatus: [{Value: "FAILED", Comparison: "EQUALS"}],
    WorkflowStatus: [{Value: "NEW", Comparison: "EQUALS"}]}')
  out=$(aws_ securityhub get-findings --output text --filters "$f" \
    --query 'Findings[].[Compliance.SecurityControlId,Severity.Label,Resources[0].Type,Resources[0].Id]') ||
    fail "securityhub get-findings (controls) with profile $profile"
  printing && return 0
  tmp=$(umask 077 && mktemp "$session/.controls-failed.XXXXXX") || fail "create a file in $session"
  [ -z "$out" ] || printf '%s\n' "$out" | sort >"$tmp"
  mv "$tmp" "$session/controls-failed.tsv" || fail "write $session/controls-failed.tsv"
  if [ -z "$out" ]; then
    ok "Security Hub: no FAILED control for the account"
    return 0
  fi
  printf '%s\n' "$out" | cut -f 1-3 | tr '\t' ' ' | sort | uniq -c | sort -rn | while read -r n rest; do
    note "Security Hub FAILED control x$n: $rest"
  done
  note "resources of the FAILED controls: $session/controls-failed.tsv; handle them as security-alert.md says"
}

# securityhub_recent: the GuardDuty and Access Analyzer findings of the account since the session started. With
# security_hub off only Access Analyzer's arrive here: the organization's analyzer sits in svp-security.
securityhub_recent() {
  local f out now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  f=$(jq -nc --arg a "$acc" --arg s "$since" --arg e "$now" '{AwsAccountId: [{Value: $a, Comparison: "EQUALS"}],
    RecordState: [{Value: "ACTIVE", Comparison: "EQUALS"}], UpdatedAt: [{Start: $s, End: $e}],
    ProductName: [{Value: "GuardDuty", Comparison: "EQUALS"}, {Value: "IAM Access Analyzer", Comparison: "EQUALS"}]}')
  out=$(aws_ securityhub get-findings --output text --filters "$f" \
    --query 'Findings[].[ProductName,Severity.Label,Types[0],Title]') ||
    fail "securityhub get-findings (GuardDuty, Access Analyzer) with profile $profile"
  printing && return 0
  if [ -z "$out" ]; then
    ok "Security Hub: no GuardDuty or Access Analyzer finding since $since"
    return 0
  fi
  printf '%s\n' "$out" | tr '\t' ' ' | sort | uniq -c | sort -rn | while read -r n rest; do
    note "finding x$n since the start: $rest"
  done
}

# guardduty_findings REGION: with security_hub off the account's GuardDuty findings do not reach Security Hub, so they
# are read at the delegated administrator, in the region and in us-east-1 for the global ones.
guardduty_findings() {
  local r=$1 det ms crit ids rows
  local -a idarr
  det=$(aws_in "$r" guardduty list-detectors --query 'DetectorIds[0]' --output text) ||
    fail "guardduty list-detectors in $r with profile $profile"
  if printing; then
    det='<detector>'
    ms='<epoch ms of the session start>'
  else
    [ -n "$det" ] && [ "$det" != None ] || fail "no GuardDuty detector in $r for profile $profile"
    ms=$(jq -n --arg t "$since" '$t | fromdateiso8601 * 1000')
  fi
  crit=$(jq -nc --arg a "$acc" --arg s "$ms" '{Criterion: {accountId: {Equals: [$a]}, updatedAt: {GreaterThanOrEqual: ($s | tonumber? // $s)}}}')
  ids=$(aws_in "$r" guardduty list-findings --detector-id "$det" --max-items 50 --finding-criteria "$crit" \
    --query FindingIds --output text) || fail "guardduty list-findings in $r with profile $profile"
  if printing; then
    aws_in "$r" guardduty get-findings --detector-id "$det" --output text --query 'Findings[].[Severity,Type,Title]' --finding-ids '<ids>'
    return 0
  fi
  if [ -z "$ids" ] || [ "$ids" = None ]; then
    ok "GuardDuty $r: no finding for the account since $since"
    return 0
  fi
  read -r -a idarr <<<"$ids"
  rows=$(aws_in "$r" guardduty get-findings --detector-id "$det" --output text --query 'Findings[].[Severity,Type,Title]' \
    --finding-ids "${idarr[@]}") || fail "guardduty get-findings in $r with profile $profile"
  sort -rn <<<"$rows" | while IFS=$'\t' read -r s t title; do
    note "GuardDuty $r severity $s (HIGH from 7, CRITICAL from 9): $t, $title"
  done
}

findings() {
  local envprofile=$profile hub acc session since
  # The environment's variables are read before profile_arg replaces them.
  local env=$env_name
  acc=${!account_var:-}
  step "preflight.sh findings $env"
  hub=$(paid_feature "$env" security_hub) || fail "read security_hub of $env in paid-features.json"
  session_dir
  since_of_session
  if printing; then
    acc="<$account_var>"
  else
    [[ $acc =~ ^[0-9]{12}$ ]] || fail "set $account_var to the 12 digits of the $env account (export $account_var=...)"
  fi
  # The account that filters the findings is the environment's own: its profile proves the variable is right.
  use_profile "$envprofile" || return 1
  if use_profile anhnv-backup-ro; then chk backup_copy; fi
  if use_profile anhnv-security-ro; then
    if [ "$hub" = off ]; then
      note "security_hub of $env is off in paid-features.json: GuardDuty is read at its delegated administrator"
      chk securityhub_recent
      chk guardduty_findings "$region"
      chk guardduty_findings "$global_region"
    else
      chk securityhub_controls
      chk securityhub_recent
    fi
  fi
}

# --- promote ---

# clone DIR: DIR is a git clone with no change to tracked files, and origin is fetched to read origin/main.
clone() {
  local st
  st=$(run_ git -C "$1" status --porcelain --untracked-files=no 2>/dev/null) ||
    fail "$1 is not a git clone (SVP_BACKEND_DIR, SVP_GITOPS_DIR name another place)"
  [ -z "$st" ] || fail "$1 has uncommitted changes to tracked files: commit or stash them first"
  run_ git -C "$1" fetch origin >/dev/null 2>&1 || fail "git fetch origin in $1"
  ok "clone $1 is clean and fetched"
}

# pins: revision (chart, in the code repository) and gitopsRevision (svp-gitops) of envs/prd/charts.yaml on origin/main
# of svp-gitops, as rev and gitops_rev; the gate has not been passed while one is missing.
pins() {
  local charts
  charts=$(run_ git -C "$gitops_dir" show origin/main:envs/prd/charts.yaml) || fail "no envs/prd/charts.yaml on origin/main of $gitops_dir"
  if printing; then
    rev='<revision>' gitops_rev='<gitopsRevision>'
    return 0
  fi
  rev=$(sed -n 's/^revision: *//p' <<<"$charts")
  gitops_rev=$(sed -n 's/^gitopsRevision: *//p' <<<"$charts")
  [[ $rev =~ ^[0-9a-f]{40}$ ]] || fail "revision of envs/prd/charts.yaml on origin/main is '$rev', not a commit"
  [[ $gitops_rev =~ ^[0-9a-f]{40}$ ]] ||
    fail "gitopsRevision of envs/prd/charts.yaml on origin/main is '$gitops_rev', not a commit: promote-prd has not merged (session-prd.md, Cổng promote prd)"
}

gate_pins() {
  local rev gitops_rev
  pins
  printing || ok "envs/prd/charts.yaml: revision $rev, gitopsRevision $gitops_rev"
}

# gate_chart: the chart revision has the Collector by platform and the canaryPrometheus value.
gate_chart() {
  local rev gitops_rev
  pins
  run_ git -C "$backend_dir" cat-file -e "$rev:deploy/observability/otelcol/k8s-eks.yaml" ||
    fail "revision $rev has no deploy/observability/otelcol/k8s-eks.yaml: promote again from a stg_ref run with the new chart"
  run_ git -C "$backend_dir" show "$rev:deploy/helm/svp-service/values.yaml" | grep '^canaryPrometheus:' >/dev/null ||
    printing || fail "revision $rev has no canaryPrometheus value in deploy/helm/svp-service/values.yaml"
  printing || ok "chart revision $rev has the eks Collector and canaryPrometheus"
}

# gate_media: gitopsRevision (G) runs media-worker as mediaconvert and the chart revision (R) takes args.
gate_media() {
  local rev gitops_rev n
  pins
  run_ git -C "$gitops_dir" show "$gitops_rev:platforms/eks/media-worker.yaml" | grep -x 'args: \[mediaconvert\]' >/dev/null ||
    printing || fail "$gitops_rev: platforms/eks/media-worker.yaml has no line 'args: [mediaconvert]'"
  n=$(run_ git -C "$gitops_dir" show "$gitops_rev:platforms/eks/media-worker.values.tpl" |
    grep -c -E '^ +(MEDIACONVERT_QUEUE_ARN|MEDIACONVERT_ROLE_ARN|TRANSCODE_EVENTS_QUEUE_URL):|cidr: .*vpcCidr.*ports: \[443\]' || true)
  printing || [ "$n" = 4 ] || fail "$gitops_rev: media-worker.values.tpl has $n of the 4 lines (three variables, egress 443 in the VPC)"
  n=$(run_ git -C "$gitops_dir" show "$gitops_rev:argocd/apps/templates/applications.yaml" |
    grep -c -E 'mediaconvertQueueArn|mediaconvertRoleArn|transcodeEventsQueueUrl' || true)
  printing || [ "$n" = 3 ] || fail "$gitops_rev: applications.yaml has $n of the 3 cluster-contract keys"
  run_ git -C "$backend_dir" show "$rev:deploy/helm/svp-service/values.schema.json" | jq -e '.properties.args.type == "array"' >/dev/null ||
    printing || fail "$rev: values.schema.json of svp-service does not take args as an array"
  n=$(run_ git -C "$backend_dir" show "$rev:deploy/helm/svp-service/templates/deployment.yaml" | grep -c 'with .Values.args' || true)
  printing || [ "$n" = 1 ] || fail "$rev: deployment.yaml of svp-service has $n lines 'with .Values.args', not 1"
  printing || ok "media-worker runs mediaconvert at $gitops_rev and the chart at $rev takes args"
}

promote() {
  step "preflight.sh promote"
  chk clone "$backend_dir"
  chk clone "$gitops_dir"
  # Reading origin/main of a missing or dirty clone only adds confusing lines.
  [ "$failures" -eq 0 ] || exit 1
  chk gate_pins
  [ "$failures" -eq 0 ] || exit 1
  chk gate_chart
  chk gate_media
}

"${sub//-/_}"
[ "$failures" -eq 0 ] || exit 1
