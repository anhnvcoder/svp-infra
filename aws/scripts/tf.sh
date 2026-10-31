#!/usr/bin/env bash
# Terraform of the root aws/envs/<env> for a session, with the account checked before each command and the times of
# apply and destroy in the session's timeline:
#   init     terraform init with the shared backend configuration aws/backend.hcl
#   plan     terraform plan -var-file=<env>.tfvars into <env>.tfplan, to be read before apply
#   apply    terraform apply of that plan file only (never a plan made on the fly), then the file is removed
#   destroy  terraform destroy -var-file=<env>.tfvars, asking for yes; refused until pre-destroy.sh has finished in
#            this session (resources Kubernetes made would block it or stay billed), unless --no-cluster says that
#            nothing ever ran on a cluster. --no-cluster is checked, not trusted: the session has no cluster-values.json
#            and terraform state list of the root holds no EKS cluster (an apply that failed before EKS); otherwise it
#            refuses. A new session directory alone (a terminal reopened with a fresh SVP_SESSION_DIR) has no
#            cluster-values.json either, which is why the state is read too
# TF_VAR_account_id is set from SVP_AWS_ACCOUNT_ID once the account is checked: the provider refuses any other.
#
# Usage: aws/scripts/tf.sh [--print] stg init|plan|apply|destroy [--no-cluster]
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
env_arg "${1:-}"
cmd=${2:-}
no_cluster=
case "$cmd ${3:-}" in
  'init ' | 'plan ' | 'apply ') ;;
  'destroy ') ;;
  'destroy --no-cluster') no_cluster=1 ;;
  *) fail "usage: $(basename "$0") [--print] stg init|plan|apply|destroy [--no-cluster]" ;;
esac
[ $# -le 3 ] || fail "usage: $(basename "$0") [--print] stg init|plan|apply|destroy [--no-cluster]"

session_dir
plan_file=$env_name.tfplan
step "tf.sh: terraform $cmd of aws/envs/$env_name"
check_account
export TF_VAR_account_id=${SVP_AWS_ACCOUNT_ID:-}

case $cmd in
  init)
    printing || [ -f "$infra_root/aws/backend.hcl" ] ||
      fail "no aws/backend.hcl: AWS_PROFILE=$profile terraform -chdir=aws/bootstrap output -raw backend_hcl > aws/backend.hcl"
    tf_ "$root_dir" init -input=false -backend-config=../../backend.hcl || fail "terraform init of aws/envs/$env_name"
    ok "terraform init of aws/envs/$env_name"
    ;;
  plan)
    printing || [ -f "$root_dir/$env_name.auto.tfvars" ] ||
      fail "no aws/envs/$env_name/$env_name.auto.tfvars: copy example.auto.tfvars.example and fill in the personal values"
    tf_ "$root_dir" plan -input=false -var-file="$env_name.tfvars" -out="$plan_file" || fail "terraform plan of aws/envs/$env_name"
    ok "plan written to aws/envs/$env_name/$plan_file: read it, then $(basename "$0") $env_name apply"
    ;;
  apply)
    printing || [ -f "$root_dir/$plan_file" ] ||
      fail "no aws/envs/$env_name/$plan_file: run $(basename "$0") $env_name plan and read it first"
    mark apply-start
    tf_ "$root_dir" apply -input=false "$plan_file" || fail "terraform apply of aws/envs/$env_name (read the error, then plan again)"
    mark apply-end
    run_ rm -f "$root_dir/$plan_file"
    ok "applied aws/envs/$env_name"
    ;;
  destroy)
    if [ -n "$no_cluster" ]; then
      printing || [ ! -e "$session/cluster-values.json" ] ||
        fail "--no-cluster refused: $session/cluster-values.json exists, so bootstrap-argocd.sh ran on a cluster: aws/scripts/pre-destroy.sh $env_name first"
      addresses=$(tf_ "$root_dir" state list) ||
        fail "--no-cluster refused: terraform state list of aws/envs/$env_name failed (tf.sh $env_name init first; no state at all means nothing to destroy: go on to aws/scripts/sweep.sh)"
      # Resources only: data.aws_eks_cluster (a read) is no cluster.
      eks=$(printf '%s\n' "$addresses" | grep -E '(^|\.)aws_eks_cluster\.' | grep -vE '(^|\.)data\.aws_eks_cluster\.' || true)
      [ -z "$eks" ] ||
        fail "--no-cluster refused: the state holds EKS cluster $(oneline <<<"$eks"): run aws/scripts/pre-destroy.sh $env_name first (it needs only the cluster, not bootstrap-argocd.sh nor this session's files), then $(basename "$0") $env_name destroy without --no-cluster"
      note "--no-cluster: no cluster-values.json and no EKS cluster in the state; pre-destroy.sh skipped, the sweep afterwards tells whether anything was left"
    elif ! printing; then
      awk -F '\t' '$3 == "pre-destroy-done" { found = 1 } END { exit !found }' "$session/timeline.tsv" 2>/dev/null ||
        fail "pre-destroy.sh $env_name has not finished in this session ($session): run it first (or --no-cluster when no EKS cluster was ever made: the session has no cluster-values.json and the state no cluster)"
    fi
    mark destroy-start
    tf_ "$root_dir" destroy -var-file="$env_name.tfvars" ||
      fail "terraform destroy of aws/envs/$env_name: see the stuck-destroy section of docs/runbooks/session-$env_name.md, then destroy again"
    mark destroy-end
    ok "destroyed aws/envs/$env_name; now aws/scripts/sweep.sh"
    ;;
esac
