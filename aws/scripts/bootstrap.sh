#!/usr/bin/env bash
# Bootstrap of the session's EKS cluster around the apply of root aws/gitops/<env>, which installs Argo CD and the root
# of GitOps. Thin on purpose: the secrets and GlitchTip are the code repository's make targets, Argo CD is Terraform's.
# Runs them in order with the account checked and the waits bounded: secrets before root gitops, wait after it.
# Design notes: README.md.

# Usage: aws/scripts/bootstrap.sh [--print] stg|prd secrets|wait
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
usage="usage: $(basename "$0") [--print] $(env_names session) secrets|wait"
[ $# -eq 2 ] || fail "$usage"
env_arg "$1"
case $2 in secrets | wait) ;; *) fail "$usage" ;; esac
session_dir
values_file=$session/cluster-values.json
# Waits: Argo CD makes svp-observability within minutes of the apply; GlitchTip's migrations and every chart after.
app_limit=${SVP_BOOTSTRAP_LIMIT:-1800}

step "bootstrap.sh $2: the account of profile $profile"
check_account

if [ "$2" = secrets ]; then
  step "bootstrap.sh secrets: the clone of the code repository"
  branch=$(run_ git -C "$backend_dir" rev-parse --abbrev-ref HEAD) || fail "$backend_dir is not a clone of the code repository"
  run_ git -C "$backend_dir" fetch -q origin main || fail "git fetch origin main in $backend_dir"
  head=$(run_ git -C "$backend_dir" rev-parse HEAD) || fail "git rev-parse HEAD in $backend_dir"
  upstream=$(run_ git -C "$backend_dir" rev-parse refs/remotes/origin/main) || fail "no origin/main in $backend_dir"
  dirty=$(run_ git -C "$backend_dir" status --porcelain --untracked-files=no) || fail "git status in $backend_dir"
  if ! printing; then
    [ "$branch" = main ] && [ "$head" = "$upstream" ] ||
      fail "$backend_dir is on $branch at ${head:0:12}, not on main at origin/main ${upstream:0:12}: git -C $backend_dir switch main && git -C $backend_dir pull --ff-only"
    [ -z "$dirty" ] || fail "$backend_dir has uncommitted changes to tracked files; the session runs main as it was merged"
    ok "code repository on main at ${head:0:12}"
  fi

  step "bootstrap.sh secrets: kubeconfig context $context"
  kubeconfig || fail "kubeconfig context $context of cluster $cluster (aws eks update-kubeconfig, describe-cluster)"
  ok "context $context in the kubeconfig"

  step "bootstrap.sh secrets: cluster values"
  values=$(tf_ "$env_root" output -json cluster_values) || fail "terraform output cluster_values of aws/envs/$env_name"
  if ! printing; then
    jq -e --arg name "$cluster" '.name == $name and (.domain | type == "string" and length > 0)
      and (.edgeTargetGroupArn | type == "string" and startswith("arn:"))' <<<"$values" >/dev/null 2>&1 ||
      fail "output cluster_values of aws/envs/$env_name is not a map of cluster $cluster with a domain and an edgeTargetGroupArn"
    (umask 077 && printf '%s\n' "$values" >"$values_file") || fail "write $values_file"
    ok "cluster values in $values_file"
  fi

  step "bootstrap.sh secrets: the RDS master password"
  arn=$(tf_ "$env_root" output -raw rds_master_user_secret_arn) || fail "terraform output rds_master_user_secret_arn of aws/envs/$env_name"
  password=
  if printing; then
    arn='<output rds_master_user_secret_arn>'
    aws_ secretsmanager get-secret-value --secret-id "$arn" --query SecretString --output text
    printf '  (piped to jq -r .password; the password stays in this shell, for make below)\n' >&3
  else
    # The secret's JSON goes from aws to jq through a pipe and is never kept: a here-string would be a temporary file on
    # the Mac's bash 3.2, with the password in it. Only the password field is kept, in a shell variable.
    password=$(aws_ secretsmanager get-secret-value --secret-id "$arn" --query SecretString --output text |
      jq -r '.password // empty' 2>/dev/null) || fail "read the RDS master secret $arn (its SecretString must be JSON)"
    [ -n "$password" ] || fail "the RDS master secret $arn has no password field"
    ok "RDS master password read (not shown)"
  fi

  step "bootstrap.sh secrets: make eks-secrets"
  log=$session/eks-secrets.log
  if printing; then
    show "SVP_RDS_MASTER_PASSWORD=<password field of the secret above>" "AWS_PROFILE=$profile" make -C "$backend_dir" eks-secrets \
      "CONTEXT=$context"
  else
    # An assignment before the command puts the password in the environment of make alone, not in its arguments
    # (which ps shows) nor in this shell's exported variables. The check of the log below gets it the same way: grep
    # reads the pattern from a pipe (printf is a builtin), never from its arguments.
    rc=0
    SVP_RDS_MASTER_PASSWORD=$password AWS_PROFILE=$profile make -C "$backend_dir" eks-secrets "CONTEXT=$context" 2>&1 |
      tee "$log" || rc=$?
    if grep -qF -f <(printf '%s\n' "$password") "$log"; then
      rm -f "$log"
      password=
      fail "the output of make eks-secrets held the RDS master password: log deleted; rotate the secret (aws secretsmanager rotate-secret) before the next session"
    fi
    password=
    [ "$rc" -eq 0 ] || fail "make eks-secrets (exit $rc; output in $log)"
  fi
  mark secrets-written
  ok "entries svp/$env_name/* written (kafka-admin, kafka-users, valkey-users by the apply of aws/envs/$env_name); next: aws/scripts/tf.sh $env_name gitops init, plan, apply"
  exit 0
fi

need_tunnel

# app_status NAME: "<sync> <health>" of Application NAME, nothing while Argo CD has not made it yet.
app_status() {
  local out
  out=$(kc -n argocd get applications.argoproj.io "$1" --ignore-not-found -o json) || return 1
  printing && return 0
  [ -n "$out" ] || return 0
  jq -r '"\(.status.sync.status // "Unknown") \(.status.health.status // "Unknown")"' <<<"$out"
}
healthy() { [ "$(app_status "$1" | awk '{ print $2 }')" = Healthy ]; }
synced_healthy() { [ "$(app_status "$1")" = "Synced Healthy" ]; }

step "bootstrap.sh wait: Application svp-observability Healthy"
wait_until "Application svp-observability is Healthy" "$app_limit" healthy svp-observability ||
  fail "Application svp-observability not Healthy after $app_limit s ($(app_status svp-observability || true)): kubectl --context $context -n argocd get applications.argoproj.io; then this again"
mark observability-healthy
ok "svp-observability Healthy"

step "bootstrap.sh wait: make eks-glitchtip-init"
make_ eks-glitchtip-init "CONTEXT=$context" || fail "make eks-glitchtip-init (it is idempotent: run this again)"
mark glitchtip-init
ok "GlitchTip's DSN and tokens in entry svp/$env_name/glitchtip-runtime"

step "bootstrap.sh wait: Application svp-root Synced and Healthy"
wait_until "Application svp-root is Synced and Healthy" "$app_limit" synced_healthy svp-root ||
  fail "Application svp-root not Synced and Healthy after $app_limit s ($(app_status svp-root || true)): kubectl --context $context -n argocd get applications.argoproj.io; then this again"
mark svp-root-healthy
ok "every Application Synced and Healthy on $context"

# The TargetGroupBinding of Envoy can exist while the ALB's health check has not yet passed on any pod, and measure.sh
# goes through CloudFront and that ALB right after: it starts once the edge's target group has a healthy target.
if printing; then
  target_group='<edgeTargetGroupArn of cluster-values.json>'
else
  target_group=$(jq -r '.edgeTargetGroupArn // empty' "$values_file" 2>/dev/null) || target_group=
  [ -n "$target_group" ] ||
    fail "no edgeTargetGroupArn in $values_file: aws/scripts/bootstrap.sh $env_name secrets writes it from output cluster_values of aws/envs/$env_name"
fi
target_health() {
  local out
  out=$(aws_ elbv2 describe-target-health --target-group-arn "$target_group" --output json) || return 1
  printing && return 0
  jq -r '.TargetHealthDescriptions[]? | "\(.Target.Id) \(.TargetHealth.State)"' <<<"$out"
}
edge_healthy() {
  local targets
  targets=$(target_health) || return 1
  printing || grep -q ' healthy$' <<<"$targets"
}

step "bootstrap.sh wait: a healthy target in the edge's target group"
wait_until "a pod of Envoy is a healthy target of the edge's ALB" "$app_limit" edge_healthy ||
  fail "no healthy target in $target_group after $app_limit s (targets: $(target_health | oneline || true)): kubectl --context $context -n envoy-gateway-system describe targetgroupbinding svp-envoy; then this again"
mark edge-healthy
ok "the edge's target group has a healthy target; next: aws/scripts/measure.sh $env_name"
