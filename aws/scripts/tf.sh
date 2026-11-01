#!/usr/bin/env bash
# Terraform of the root aws/envs/<env> for a session, with the account checked before each command and the times of
# apply and destroy in the session's timeline:
#   init     terraform init with the shared backend configuration aws/backend.hcl
#   plan     terraform plan -var-file=<env>.tfvars into <env>.tfplan, then show (below): the plan to be read before apply
#   plan --destroy [--no-cluster]
#            terraform plan -destroy -var-file=<env>.tfvars into <env>.destroy.tfplan, and its text into
#            <session>/<env>-destroy-plan.txt, the plan to be read before destroy; refused until pre-destroy.sh has
#            finished in this session (resources Kubernetes made would block it or stay billed), unless --no-cluster
#            says that nothing ever ran on a cluster. --no-cluster is checked, not trusted: the session has no
#            cluster-values.json and terraform state list of the root holds no EKS cluster (an apply that failed before
#            EKS); otherwise it refuses. A new session directory alone (a terminal reopened with a fresh
#            SVP_SESSION_DIR) has no cluster-values.json either, which is why the state is read too
#   show     terraform show -no-color of <env>.tfplan into <session>/<env>-plan.txt, the text to read before apply (the plan
#            file is binary). It names the real domain and IPs, so it goes in the session directory, never in the repository
#   apply    terraform apply of that plan file only (never a plan made on the fly), then the file is removed
#   destroy  terraform apply of <env>.destroy.tfplan only (no plan made on the fly, no question asked), then the file is
#            removed
# TF_VAR_account_id is set from SVP_AWS_ACCOUNT_ID once the account is checked: the provider refuses any other.
#
# Usage: aws/scripts/tf.sh [--print] stg init|plan [--destroy [--no-cluster]]|show|apply|destroy
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
env_arg "${1:-}"
cmd=${2:-}
usage="usage: $(basename "$0") [--print] stg init|plan [--destroy [--no-cluster]]|show|apply|destroy"
destroy_plan=
no_cluster=
case "$cmd${3:+ $3}${4:+ $4}" in
  init | plan | show | apply | destroy) ;;
  'plan --destroy') destroy_plan=1 ;;
  'plan --destroy --no-cluster') destroy_plan=1 no_cluster=1 ;;
  *) fail "$usage" ;;
esac
[ $# -le 4 ] || fail "$usage"

session_dir
plan_file=$env_name.tfplan
destroy_plan_file=$env_name.destroy.tfplan
step "tf.sh: terraform $cmd${destroy_plan:+ -destroy} of aws/envs/$env_name"
check_account
export TF_VAR_account_id=${SVP_AWS_ACCOUNT_ID:-}

# write_plan_text PLAN_FILE TEXT_NAME: the text of PLAN_FILE into $session/TEXT_NAME (owner only), and its Plan: line.
write_plan_text() {
  plan_text=$session/$2
  if printing; then
    tf_ "$root_dir" show -no-color "$1"
    return 0
  fi
  (umask 077 && tf_ "$root_dir" show -no-color "$1" >"$plan_text") ||
    fail "terraform show of aws/envs/$env_name/$1"
  summary=$(grep -E '^(Plan:|No changes\.)' "$plan_text" | head -n 1 || true)
  ok "plan text in $plan_text${summary:+: $summary}"
}

case $cmd${destroy_plan:+ --destroy} in
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
    write_plan_text "$plan_file" "$env_name-plan.txt"
    ok "plan written to aws/envs/$env_name/$plan_file: read $plan_text, then $(basename "$0") $env_name apply"
    ;;
  show)
    printing || [ -f "$root_dir/$plan_file" ] ||
      fail "no aws/envs/$env_name/$plan_file: run $(basename "$0") $env_name plan first"
    write_plan_text "$plan_file" "$env_name-plan.txt"
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
  'plan --destroy')
    if [ -n "$no_cluster" ]; then
      printing || [ ! -e "$session/cluster-values.json" ] ||
        fail "--no-cluster refused: $session/cluster-values.json exists, so bootstrap-argocd.sh ran on a cluster: aws/scripts/pre-destroy.sh $env_name first"
      addresses=$(tf_ "$root_dir" state list) ||
        fail "--no-cluster refused: terraform state list of aws/envs/$env_name failed (tf.sh $env_name init first; no state at all means nothing to destroy: go on to aws/scripts/sweep.sh)"
      # Resources only: data.aws_eks_cluster (a read) is no cluster.
      eks=$(printf '%s\n' "$addresses" | grep -E '(^|\.)aws_eks_cluster\.' | grep -vE '(^|\.)data\.aws_eks_cluster\.' || true)
      [ -z "$eks" ] ||
        fail "--no-cluster refused: the state holds EKS cluster $(oneline <<<"$eks"): run aws/scripts/pre-destroy.sh $env_name first (it needs only the cluster, not bootstrap-argocd.sh nor this session's files), then $(basename "$0") $env_name plan --destroy without --no-cluster"
      note "--no-cluster: no cluster-values.json and no EKS cluster in the state; pre-destroy.sh skipped, the sweep afterwards tells whether anything was left"
    elif ! printing; then
      awk -F '\t' '$3 == "pre-destroy-done" { found = 1 } END { exit !found }' "$session/timeline.tsv" 2>/dev/null ||
        fail "pre-destroy.sh $env_name has not finished in this session ($session): run it first (or --no-cluster when no EKS cluster was ever made: the session has no cluster-values.json and the state no cluster)"
    fi
    printing || [ -f "$root_dir/$env_name.auto.tfvars" ] ||
      fail "no aws/envs/$env_name/$env_name.auto.tfvars: copy example.auto.tfvars.example and fill in the personal values"
    tf_ "$root_dir" plan -destroy -input=false -var-file="$env_name.tfvars" -out="$destroy_plan_file" ||
      fail "terraform plan -destroy of aws/envs/$env_name"
    write_plan_text "$destroy_plan_file" "$env_name-destroy-plan.txt"
    ok "destroy plan written to aws/envs/$env_name/$destroy_plan_file: read $plan_text, then $(basename "$0") $env_name destroy"
    ;;
  destroy)
    printing || [ -f "$root_dir/$destroy_plan_file" ] ||
      fail "no aws/envs/$env_name/$destroy_plan_file: run $(basename "$0") $env_name plan --destroy and read it first"
    mark destroy-start
    tf_ "$root_dir" apply -input=false "$destroy_plan_file" ||
      fail "terraform apply of aws/envs/$env_name/$destroy_plan_file: see the stuck-destroy section of docs/runbooks/session-$env_name.md, then plan --destroy and destroy again"
    mark destroy-end
    run_ rm -f "$root_dir/$destroy_plan_file"
    ok "destroyed aws/envs/$env_name; now aws/scripts/sweep.sh"
    ;;
esac
