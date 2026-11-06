#!/usr/bin/env bash
# Terraform of the two roots of a session, with the account checked before each command and the times of apply and
# destroy in the session's timeline. ROOT is env (aws/envs/<env>) or gitops (aws/gitops/<env>: Argo CD and the root of
# GitOps on that cluster, applied after env). apply and destroy take a saved plan
# file only, never a plan made on the fly.

# Design notes: README.md.

# plan --teardown (env only) targets the resources of the state whose protection the teardown file lifts (the DB
# instance, the buckets) and nothing else, so it never creates what an apply that failed halfway left out.

# plan --destroy: gitops is refused until pre-destroy.sh has finished in this session (what Kubernetes made would block
# the destroy or stay billed); env until root gitops is destroyed and, with a teardown file, that is applied.
# --leftovers (the session's time is up and pre-destroy.sh still red) and --no-cluster (no cluster ever ran) are checked
# against the timeline or the state, not trusted.

# TF_VAR_account_id is set from the environment's account variable once the account is checked: the provider refuses any
# other. The plan texts name the real domain and IPs, so they go in the session directory, never in the repository. For
# an environment whose API endpoint is private, every command of root gitops but init needs the tunnel open.

# Usage: aws/scripts/tf.sh [--print] stg|prd env|gitops init|plan [--teardown|--destroy [--leftovers|--no-cluster]]|show|apply [--teardown]|destroy
set -euo pipefail

# shellcheck source=aws/scripts/lib.sh
. "$(dirname "$0")/lib.sh"
printing && shift
usage="usage: $(basename "$0") [--print] $(env_names session) env|gitops init|plan [--teardown|--destroy [--leftovers|--no-cluster]]|show|apply [--teardown]|destroy"
[ $# -ge 3 ] && [ $# -le 5 ] || fail "$usage"
env_arg "$1"
root=$2
case $root in
  env) root_dir=$env_root key=aws/$env_name/terraform.tfstate ;;
  gitops) root_dir=$gitops_root key=aws/gitops/$env_name/terraform.tfstate ;;
  *) fail "$usage" ;;
esac
cmd=$3
flags="${4:-}${5:+ $5}"
op=
case "$root $cmd${flags:+ $flags}" in
  *' init' | *' plan' | *' show' | *' apply' | *' destroy') op=$cmd ;;
  'env plan --teardown') op=plan-teardown ;;
  'env apply --teardown') op=apply-teardown ;;
  *' plan --destroy') op=plan-destroy ;;
  'gitops plan --destroy --leftovers') op=plan-destroy-leftovers ;;
  'env plan --destroy --no-cluster') op=plan-destroy-no-cluster ;;
  'env plan --destroy --leftovers')
    fail "--leftovers is for root gitops, whose destroy pre-destroy.sh guards: tf.sh $env_name gitops plan --destroy --leftovers" ;;
  'gitops plan --destroy --no-cluster')
    fail "--no-cluster is for root env: with no cluster root gitops was never applied (tf.sh $env_name env plan --destroy --no-cluster)" ;;
  *) fail "$usage" ;;
esac

session_dir
plan_file=$env_name.tfplan
destroy_plan_file=$env_name.destroy.tfplan
teardown_plan_file=$env_name.teardown.tfplan
rel=aws/${root_dir#"$infra_root"/aws/}
step "tf.sh: terraform $cmd${flags:+ $flags} of $rel"
check_account
export TF_VAR_account_id=${!account_var:-}
var_files=("-var-file=$env_name.tfvars")
if [ "$root" = env ] && [ -n "$teardown" ] && case $op in plan-teardown | plan-destroy*) true ;; *) false ;; esac; then
  var_files+=("-var-file=$teardown")
fi

# has_mark EVENT: the session's timeline holds EVENT.
has_mark() { awk -F '\t' -v e="$1" '$3 == e { found = 1 } END { exit !found }' "$session/timeline.tsv" 2>/dev/null; }

# The resource types whose protection the teardown file lifts: deletion protection of the DB instance, force_destroy
# of the buckets (root env has no other instance or bucket).
teardown_types='aws_db_instance aws_s3_bucket'

# protected_addresses: the addresses of the resources of teardown_types in the state of the root, one per line, data
# sources left out; with --print, a placeholder.
protected_addresses() {
  local addresses types
  if printing; then
    tf_ "$root_dir" state list
    echo "<each ${teardown_types// / and } of the state>"
    return 0
  fi
  addresses=$(tf_ "$root_dir" state list) ||
    fail "terraform state list of $rel ($(basename "$0") $env_name env init first)"
  types=${teardown_types// /|}
  printf '%s\n' "$addresses" | grep -E "(^|\.)($types)\." | grep -vE "(^|\.)data\.($types)\." || true
}

# write_plan_text PLAN_FILE TEXT_NAME: the text of PLAN_FILE into $session/TEXT_NAME (owner only), and its Plan: line.
write_plan_text() {
  plan_text=$session/$2
  if printing; then
    tf_ "$root_dir" show -no-color "$1"
    return 0
  fi
  (umask 077 && tf_ "$root_dir" show -no-color "$1" >"$plan_text") ||
    fail "terraform show of $rel/$1"
  summary=$(grep -E '^(Plan:|No changes\.)' "$plan_text" | head -n 1 || true)
  ok "plan text in $plan_text${summary:+: $summary}"
}

# need_auto_tfvars: root env reads the personal values (zone, domain, ACME email) from <env>.auto.tfvars.
need_auto_tfvars() {
  [ "$root" = env ] || return 0
  printing || [ -f "$root_dir/$env_name.auto.tfvars" ] ||
    fail "no $rel/$env_name.auto.tfvars: copy example.auto.tfvars.example and fill in the personal values"
}

# gitops_inputs: what a plan of root gitops reads besides its tfvars. Chart svp-cluster of the code repository at the
# revision of envs/<env>/charts.yaml on origin/main of svp-gitops (the chart Application svp-cluster installs), whose
# templates/namespaces.yaml gives the namespaces made before Argo CD; the Telegram chat of Alertmanager from the code
# repository's .env (empty: commit status only). Both clones are fetched first.
gitops_inputs() {
  local rev chart_dir=$session/svp-cluster-chart chat env_file=$backend_dir/.env
  run_ git -C "$gitops_dir" fetch -q origin || fail "git fetch origin in $gitops_dir"
  run_ git -C "$backend_dir" fetch -q origin || fail "git fetch origin in $backend_dir"
  rev=$(run_ git -C "$gitops_dir" show "refs/remotes/origin/main:envs/$env_name/charts.yaml") ||
    fail "no envs/$env_name/charts.yaml on origin/main of $gitops_dir"
  if printing; then
    rev="<revision of envs/$env_name/charts.yaml>"
  else
    rev=$(sed -n 's/^revision:[[:space:]]*"\{0,1\}\([0-9a-f]\{40\}\)"\{0,1\}[[:space:]]*$/\1/p' <<<"$rev" | head -n 1)
    [ -n "$rev" ] || fail "envs/$env_name/charts.yaml on origin/main of $gitops_dir has no revision of 40 hex digits"
    rm -rf "$chart_dir" "$session/svp-cluster.tar"
    (umask 077 && mkdir -p "$chart_dir") || fail "create $chart_dir"
  fi
  run_ git -C "$backend_dir" archive --format=tar -o "$session/svp-cluster.tar" "$rev" deploy/helm/svp-cluster ||
    fail "git archive of deploy/helm/svp-cluster at $rev in $backend_dir (fetched? the commit is on origin/main of the code repository)"
  run_ tar -x -f "$session/svp-cluster.tar" -C "$chart_dir" || fail "extract chart svp-cluster into $chart_dir"
  export TF_VAR_svp_cluster_chart=$chart_dir/deploy/helm/svp-cluster
  if printing; then
    printf '  (TF_VAR_svp_cluster_chart=%s, TF_VAR_telegram_chat_id=<SVP_ALERT_TELEGRAM_CHAT_ID of %s>)\n' \
      "$TF_VAR_svp_cluster_chart" "$env_file" >&3
    return 0
  fi
  [ -f "$env_file" ] || fail "no $env_file: make env in the code repository first (make eks-secrets reads it too)"
  chat=$(sed -n 's/^SVP_ALERT_TELEGRAM_CHAT_ID=//p' "$env_file" | tail -n 1)
  # The value as the strict reader of .env in the code repository takes it (make eks-secrets reads the same line):
  # plain, or in one pair of double or single quotes, which are dropped.
  case $chat in
    \"*\" | \'*\') chat=${chat:1:${#chat}-2} ;;
  esac
  [[ $chat =~ ^-?[0-9]*$ ]] || fail "SVP_ALERT_TELEGRAM_CHAT_ID of $env_file is not a Telegram chat id (digits, - first for a group)"
  export TF_VAR_telegram_chat_id=$chat
  ok "chart svp-cluster at $rev in $TF_VAR_svp_cluster_chart; Telegram chat ${chat:-none (commit status only)}"
}

if [ "$root" = gitops ] && [ "$op" != init ]; then
  need_tunnel
fi

case $op in
  init)
    printing || [ -f "$infra_root/aws/backend-$env_name.hcl" ] ||
      fail "no aws/backend-$env_name.hcl: AWS_PROFILE=$profile terraform -chdir=aws/accounts/$env_name output -raw backend_hcl > aws/backend-$env_name.hcl"
    tf_ "$root_dir" init -input=false -reconfigure "-backend-config=../../backend-$env_name.hcl" "-backend-config=key=$key" ||
      fail "terraform init of $rel"
    ok "terraform init of $rel, state $key"
    ;;
  plan)
    need_auto_tfvars
    [ "$root" = env ] || gitops_inputs
    tf_ "$root_dir" plan -input=false "${var_files[@]}" -out="$plan_file" || fail "terraform plan of $rel"
    write_plan_text "$plan_file" "$env_name-$root-plan.txt"
    ok "plan written to $rel/$plan_file: read $plan_text, then $(basename "$0") $env_name $root apply"
    ;;
  show)
    printing || [ -f "$root_dir/$plan_file" ] ||
      fail "no $rel/$plan_file: run $(basename "$0") $env_name $root plan first"
    write_plan_text "$plan_file" "$env_name-$root-plan.txt"
    ;;
  apply)
    printing || [ -f "$root_dir/$plan_file" ] ||
      fail "no $rel/$plan_file: run $(basename "$0") $env_name $root plan and read it first"
    mark "$root-apply-start"
    tf_ "$root_dir" apply -input=false "$plan_file" || fail "terraform apply of $rel (read the error, then plan again)"
    mark "$root-apply-end"
    run_ rm -f "$root_dir/$plan_file"
    ok "applied $rel"
    ;;
  plan-teardown)
    if [ -z "$teardown" ]; then
      skip "$rel has no teardown file: no protection to lift before its destroy"
      exit 0
    fi
    need_auto_tfvars
    protected=$(protected_addresses) || exit 1
    targets=()
    while IFS= read -r address; do
      [ -z "$address" ] || targets+=("-target=$address")
    done <<<"$protected"
    if [ ${#targets[@]} -eq 0 ]; then
      skip "the state of $rel holds no ${teardown_types// / or }: no protection to lift; next: $(basename "$0") $env_name env plan --destroy"
      mark env-teardown-applied
      exit 0
    fi
    note "the teardown plan targets $(oneline <<<"$protected") alone: terraform warns that resource targeting is in effect"
    tf_ "$root_dir" plan -input=false "${var_files[@]}" "${targets[@]}" -out="$teardown_plan_file" ||
      fail "terraform plan of $rel with $teardown"
    write_plan_text "$teardown_plan_file" "$env_name-env-teardown-plan.txt"
    ok "teardown plan written to $rel/$teardown_plan_file: read $plan_text (it should only turn protections off), then $(basename "$0") $env_name env apply --teardown"
    ;;
  apply-teardown)
    if [ -z "$teardown" ]; then
      skip "$rel has no teardown file: no protection to lift before its destroy"
      exit 0
    fi
    if ! printing && [ ! -f "$root_dir/$teardown_plan_file" ] && has_mark env-teardown-applied; then
      skip "no teardown plan left and env-teardown-applied is in this session: nothing more to lift; next: $(basename "$0") $env_name env plan --destroy"
      exit 0
    fi
    printing || [ -f "$root_dir/$teardown_plan_file" ] ||
      fail "no $rel/$teardown_plan_file: run $(basename "$0") $env_name env plan --teardown and read it first"
    tf_ "$root_dir" apply -input=false "$teardown_plan_file" ||
      fail "terraform apply of $rel/$teardown_plan_file (read the error, then plan --teardown again)"
    mark env-teardown-applied
    run_ rm -f "$root_dir/$teardown_plan_file"
    ok "protections of $rel lifted ($teardown); next: $(basename "$0") $env_name env plan --destroy"
    ;;
  plan-destroy*)
    case $op in
      plan-destroy-leftovers)
        if ! printing; then
          has_mark pre-destroy-start ||
            fail "--leftovers refused: pre-destroy.sh $env_name never started in this session ($session): run it first, and --leftovers only if its step 2 or 3 is still red when the session's time is up"
          ! has_mark pre-destroy-done ||
            fail "--leftovers refused: pre-destroy.sh $env_name has finished in this session (pre-destroy-done): $(basename "$0") $env_name gitops plan --destroy without --leftovers"
        fi
        note "--leftovers: pre-destroy.sh did not finish, so what Kubernetes made may be left: the Load Balancer and its target groups, the DNS records of ExternalDNS, the EBS volumes of PVCs. destroy may get stuck on them (stuck-destroy section of docs/runbooks/session-stg.md); aws/scripts/sweep.sh $env_name afterwards lists what to delete by hand"
        mark pre-destroy-skipped
        ;;
      plan-destroy-no-cluster)
        printing || [ ! -e "$session/cluster-values.json" ] ||
          fail "--no-cluster refused: $session/cluster-values.json exists, so bootstrap.sh ran on a cluster: aws/scripts/pre-destroy.sh $env_name and the destroy of root gitops first"
        addresses=$(tf_ "$root_dir" state list) ||
          fail "--no-cluster refused: terraform state list of $rel failed ($(basename "$0") $env_name env init first; no state at all means nothing to destroy: go on to aws/scripts/sweep.sh $env_name)"
        # Resources only: data.aws_eks_cluster (a read) is no cluster.
        eks=$(printf '%s\n' "$addresses" | grep -E '(^|\.)aws_eks_cluster\.' | grep -vE '(^|\.)data\.aws_eks_cluster\.' || true)
        [ -z "$eks" ] ||
          fail "--no-cluster refused: the state holds EKS cluster $(oneline <<<"$eks"): run aws/scripts/pre-destroy.sh $env_name first (it needs only the cluster), then $(basename "$0") $env_name gitops plan --destroy and destroy, then $(basename "$0") $env_name env plan --destroy without --no-cluster"
        note "--no-cluster: no cluster-values.json and no EKS cluster in the state, so root gitops was never applied; pre-destroy.sh skipped, the sweep afterwards tells whether anything was left"
        ;;
      *)
        if ! printing; then
          if [ "$root" = gitops ]; then
            has_mark pre-destroy-done ||
              fail "pre-destroy.sh $env_name has not finished in this session ($session): run it first (or --leftovers when the session's time is up and its step 2 or 3 is still red)"
          else
            has_mark gitops-destroy-end ||
              fail "root gitops of $env_name is not destroyed in this session ($session): $(basename "$0") $env_name gitops plan --destroy and destroy first (or --no-cluster when no EKS cluster was ever made)"
          fi
        fi
        ;;
    esac
    if [ "$root" = env ] && [ -n "$teardown" ] && ! printing && ! has_mark env-teardown-applied; then
      fail "the protections of $rel are still on (deletion protection of RDS, versioned buckets): $(basename "$0") $env_name env plan --teardown (it targets the DB instance and the buckets of the state alone, and records that nothing is to lift when the state has none), read it, $(basename "$0") $env_name env apply --teardown, then this again"
    fi
    need_auto_tfvars
    [ "$root" = env ] || gitops_inputs
    tf_ "$root_dir" plan -destroy -input=false "${var_files[@]}" -out="$destroy_plan_file" ||
      fail "terraform plan -destroy of $rel ($(basename "$0") $env_name $root init first, if it never ran in this checkout)"
    write_plan_text "$destroy_plan_file" "$env_name-$root-destroy-plan.txt"
    ok "destroy plan written to $rel/$destroy_plan_file: read $plan_text, then $(basename "$0") $env_name $root destroy"
    ;;
  destroy)
    printing || [ -f "$root_dir/$destroy_plan_file" ] ||
      fail "no $rel/$destroy_plan_file: run $(basename "$0") $env_name $root plan --destroy and read it first"
    mark "$root-destroy-start"
    tf_ "$root_dir" apply -input=false "$destroy_plan_file" ||
      fail "terraform apply of $rel/$destroy_plan_file: see the stuck-destroy section of docs/runbooks/session-stg.md, then plan --destroy and destroy again"
    mark "$root-destroy-end"
    run_ rm -f "$root_dir/$destroy_plan_file"
    if [ "$root" = gitops ]; then
      ok "destroyed $rel; next: $(basename "$0") $env_name env plan --teardown"
    else
      ok "destroyed $rel; now aws/scripts/sweep.sh $env_name"
    fi
    ;;
esac
