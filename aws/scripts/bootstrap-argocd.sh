#!/usr/bin/env bash
# GitOps on the session's EKS cluster, after tf.sh <env> apply. Thin on purpose: Argo CD, the release checks, the
# source Secrets, the root Application pinned to a commit and the wait for every Application are the code
# repository's (make eks-gitops-up, deploy/k8s/gitops.sh), the same path as the k3d staging; nothing is installed here.
#   0. the account of the profile, as check-account.sh checks it
#   1. the clones: the code repository on main, clean and equal to origin/main (its make targets and scripts are the
#      ones the cluster's charts come from); svp-gitops fetched, GITOPS_REV the full SHA of its origin/main, read as
#      that fetch left it (gitops.sh reads refs/remotes/origin/main as the last fetch left it)
#   2. aws eks update-kubeconfig under the alias the make targets take (CONTEXT=svp-<env>)
#   3. output cluster_values of the root into $SVP_SESSION_DIR/cluster-values.json (mode 600: it holds the ACME email)
#   4. the password field of the RDS master secret (username is always postgres) into the environment of make alone:
#      never a file (the secret's JSON goes from aws to jq through a pipe), never printed, never an argument
#   5. make eks-gitops-up CONTEXT=svp-<env> CLUSTER_VALUES=<file> GITOPS_REV=<sha>; its output also in
#      $SVP_SESSION_DIR/eks-gitops-up.log
#
# Usage: aws/scripts/bootstrap-argocd.sh [--print] stg
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
[ $# -eq 1 ] || fail "usage: $(basename "$0") [--print] stg"
env_arg "$1"
session_dir
values_file=$session/cluster-values.json

step "bootstrap-argocd.sh: the account of profile $profile"
check_account

step "bootstrap-argocd.sh: the clones"
branch=$(run_ git -C "$backend_dir" rev-parse --abbrev-ref HEAD) || fail "$backend_dir is not a clone of the code repository"
run_ git -C "$backend_dir" fetch -q origin main || fail "git fetch origin main in $backend_dir"
head=$(run_ git -C "$backend_dir" rev-parse HEAD) || fail "git rev-parse HEAD in $backend_dir"
upstream=$(run_ git -C "$backend_dir" rev-parse refs/remotes/origin/main) || fail "no origin/main in $backend_dir"
dirty=$(run_ git -C "$backend_dir" status --porcelain --untracked-files=no) || fail "git status in $backend_dir"
run_ git -C "$gitops_dir" fetch -q origin || fail "git fetch origin in $gitops_dir"
rev=$(run_ git -C "$gitops_dir" rev-parse refs/remotes/origin/main) || fail "no origin/main in $gitops_dir"
if printing; then
  rev='<full SHA of origin/main of svp-gitops>'
else
  [ "$branch" = main ] && [ "$head" = "$upstream" ] ||
    fail "$backend_dir is on $branch at ${head:0:12}, not on main at origin/main ${upstream:0:12}: git -C $backend_dir switch main && git -C $backend_dir pull --ff-only"
  [ -z "$dirty" ] || fail "$backend_dir has uncommitted changes to tracked files; the session runs main as it was merged"
  [[ $rev =~ ^[0-9a-f]{40}$ ]] || fail "origin/main of $gitops_dir is '$rev', not a full commit SHA"
  ok "code repository on main at ${head:0:12}; svp-gitops origin/main at $rev"
fi

step "bootstrap-argocd.sh: kubeconfig context $context"
aws_ eks update-kubeconfig --name "$cluster" --alias "$context" || fail "aws eks update-kubeconfig for cluster $cluster"
ok "context $context in the kubeconfig"

step "bootstrap-argocd.sh: cluster values"
values=$(tf_ "$root_dir" output -json cluster_values) || fail "terraform output cluster_values of aws/envs/$env_name"
if ! printing; then
  jq -e --arg name "$cluster" '.name == $name and (.domain | type == "string" and length > 0)' <<<"$values" >/dev/null 2>&1 ||
    fail "output cluster_values of aws/envs/$env_name is not a map of cluster $cluster with a domain"
  (umask 077 && printf '%s\n' "$values" >"$values_file") || fail "write $values_file"
  ok "cluster values in $values_file"
fi

step "bootstrap-argocd.sh: the RDS master password"
arn=$(tf_ "$root_dir" output -raw rds_master_user_secret_arn) || fail "terraform output rds_master_user_secret_arn of aws/envs/$env_name"
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

step "bootstrap-argocd.sh: make eks-gitops-up"
log=$session/eks-gitops-up.log
if printing; then
  show "SVP_RDS_MASTER_PASSWORD=<password field of the secret above>" "AWS_PROFILE=$profile" make -C "$backend_dir" eks-gitops-up \
    "CONTEXT=$context" "CLUSTER_VALUES=$values_file" "GITOPS_REV=$rev"
else
  # An assignment before the command puts the password in the environment of make alone, not in its arguments
  # (which ps shows) nor in this shell's exported variables. The check of the log below gets it the same way: grep
  # reads the pattern from a pipe (printf is a builtin), never from its arguments.
  rc=0
  SVP_RDS_MASTER_PASSWORD=$password AWS_PROFILE=$profile make -C "$backend_dir" eks-gitops-up \
    "CONTEXT=$context" "CLUSTER_VALUES=$values_file" "GITOPS_REV=$rev" 2>&1 | tee "$log" || rc=$?
  if grep -qF -f <(printf '%s\n' "$password") "$log"; then
    rm -f "$log"
    password=
    fail "the output of make eks-gitops-up held the RDS master password: log deleted; rotate the secret (aws secretsmanager rotate-secret) before the next session"
  fi
  password=
  [ "$rc" -eq 0 ] || fail "make eks-gitops-up (exit $rc; output in $log)"
fi
mark argocd-healthy
ok "every Application Synced and Healthy on $context at svp-gitops $rev; next: aws/scripts/measure.sh $env_name"
